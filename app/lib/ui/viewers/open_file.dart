/**
 * 打开工作区文件：按类型选择查看方式；音视频与其他格式下载到缓存后交给手机上的其他 App，回来时如果文件被改过，询问是否传回电脑。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../file_kinds.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'fetch.dart';
import 'image_viewer.dart';
import 'pdf_viewer.dart';
import 'save.dart';
import 'text_viewer.dart';

/** 在 App 内以文本打开的大小上限 */
const textViewLimit = 2 * 1024 * 1024;

/**
 * openWorkspaceFile：按类型打开
 *
 * 处理流程：
 * 1、Markdown 与 PDF 用 App 内阅读器
 * 2、图片用看图（可左右切换同目录图片）
 * 3、不超过 2MB 的文本用文本查看器
 * 4、其他交给手机上的其他 App
 */
Future<void> openWorkspaceFile(BuildContext context, {required Workspace ws, required FileEntry entry, required List<FileEntry> siblings, bool readOnly = false}) async {
  final nav = Navigator.of(context);
  switch (viewKindOf(entry.name)) {
    // 1、阅读器
    case ViewKind.markdown || ViewKind.pdf:
      final docs = siblings.where((e) => const {ViewKind.markdown, ViewKind.pdf}.contains(viewKindOf(e.name))).toList();
      await nav.push(MaterialPageRoute<void>(builder: (_) => PdfReaderPage(ws: ws, entry: entry, siblings: docs, markdown: viewKindOf(entry.name) == ViewKind.markdown, readOnly: readOnly)));
    // 2、图片
    case ViewKind.image:
      final images = siblings.where((e) => viewKindOf(e.name) == ViewKind.image).toList();
      final i = images.indexWhere((e) => e.path == entry.path);
      await nav.push(MaterialPageRoute<void>(builder: (_) => ImageViewerPage(ws: ws, images: i < 0 ? [entry] : images, index: i < 0 ? 0 : i)));
    // 3、文本
    case ViewKind.text when entry.size <= textViewLimit:
      await nav.push(MaterialPageRoute<void>(builder: (_) => TextViewerPage(ws: ws, path: entry.path, readOnly: readOnly)));
    // 4、其他
    default:
      await openExternally(context, ws: ws, entry: entry, readOnly: readOnly);
  }
}

/**
 * openExternally：下载到缓存后用其他 App 打开
 */
Future<void> openExternally(BuildContext context, {required Workspace ws, required FileEntry entry, bool readOnly = false}) async {
  final app = context.read<AppState>();
  final scope = app.scope;
  if (scope == null) return;
  final dest = cacheFileFor(app, ws.id, entry.path, sub: 'open');
  final progress = ValueNotifier<double>(0);
  final c = context.pd;
  var canceled = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LinearProgressIndicator(value: v > 0 ? v : null, color: c.accent, backgroundColor: c.page),
          const SizedBox(height: 8),
          Text(v > 0 ? '正在下载 ${(v * 100).round()}%' : '正在下载…', style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            canceled = true;
            Navigator.pop(ctx);
          },
          child: const Text('取消'),
        ),
      ],
    ),
  ));
  final Fetched f;
  try {
    f = await fetchToFile(scope, scope.conn.api.fileUrl(ws.id, entry.path), dest, onProgress: (got, total) {
      if (total > 0) progress.value = got / total;
    });
  } on ApiException catch (e) {
    if (!canceled && context.mounted) {
      Navigator.of(context).pop();
      toast(context, e.message);
    }
    return;
  }
  if (canceled || !context.mounted) return;
  Navigator.of(context).pop();
  final before = await f.file.lastModified();
  final r = await OpenFilex.open(f.file.path);
  if (!context.mounted) return;
  if (r.type != ResultType.done) {
    toast(context, r.type == ResultType.noAppToOpen ? '手机上没有能打开这个文件的应用' : '无法打开文件');
    return;
  }
  final canEdit = !readOnly && !ws.readOnly && (scope.conn.status?.features.fileEdit ?? true);
  if (canEdit) _EditWatcher(context, ws: ws, path: entry.path, file: f.file, etag: f.etag, before: before).start();
}

/**
 * _EditWatcher：回到 App 时检查缓存文件是否被其他 App 修改，询问是否传回电脑
 */
class _EditWatcher {
  _EditWatcher(this.context, {required this.ws, required this.path, required this.file, required this.etag, required this.before});

  final BuildContext context;
  final Workspace ws;
  final String path;
  final File file;
  final String etag;
  final DateTime before;
  AppLifecycleListener? _listener;
  Timer? _expire;

  /** start：开始监听，30 分钟后自动停止 */
  void start() {
    _listener = AppLifecycleListener(onResume: _check);
    _expire = Timer(const Duration(minutes: 30), _stop);
  }

  void _stop() {
    _listener?.dispose();
    _listener = null;
    _expire?.cancel();
  }

  /** _check：文件变化后询问并保存 */
  Future<void> _check() async {
    if (!context.mounted) {
      _stop();
      return;
    }
    if (!await file.exists() || !(await file.lastModified()).isAfter(before)) return;
    _stop();
    if (!context.mounted) return;
    final ok = await confirm(context, title: '文件已修改', message: '「${path.split('/').last}」在其他应用中被修改了，要传回电脑吗？', ok: '传回电脑');
    if (!ok || !context.mounted) return;
    try {
      final bytes = await file.readAsBytes();
      if (!context.mounted) return;
      final r = await saveWithConflict(context, ws: ws, path: path, bytes: bytes, etag: etag);
      if (r.saved && context.mounted) toast(context, r.path == path ? '已传回电脑' : '已另存为 ${r.path.split('/').last}');
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }
}
