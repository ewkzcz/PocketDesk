/**
 * 传输页：进行中（进度、速度、并行路数、剩余时间，可暂停、继续、取消）、已完成。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/transfer_manager.dart';
import '../../data/models.dart';
import '../../transfer/task.dart';
import '../file_kinds.dart';
import '../format.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../viewers/fetch.dart';
import '../viewers/open_file.dart';
import 'settings_pages.dart' show TransferSettingsPage;

/**
 * TransferPage：传输
 */
class TransferPage extends StatefulWidget {
  const TransferPage({super.key});

  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  int _seg = 0;
  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = context.watch<AppState>().scope;
    if (scope == null) {
      return const Scaffold(appBar: PdBar(title: '传输'), body: EmptyHint(icon: LucideIcons.arrowUpDown300, text: '配对电脑后可以和电脑互传文件'));
    }
    final m = scope.transfers;
    return Scaffold(
      appBar: PdBar(title: '传输', actions: [
        PdIconButton(icon: LucideIcons.folderCog300, tooltip: '收发目录', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TransferSettingsPage()))),
      ]),
      body: Column(children: [
        Container(
          decoration: BoxDecoration(color: c.bar, border: Border(bottom: BorderSide(color: c.divider, width: PdSize.divider))),
          child: Row(children: [
            for (final (i, label) in [(0, '进行中'), (1, '已完成')])
              Expanded(
                child: Semantics(
                  selected: _seg == i,
                  button: true,
                  child: InkWell(
                    onTap: () => setState(() => _seg = i),
                    child: Container(
                      height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _seg == i ? c.accent : Colors.transparent, width: 2))),
                      child: Text(label, style: TextStyle(fontSize: 14, color: _seg == i ? c.accent : c.text2, fontWeight: _seg == i ? FontWeight.w600 : FontWeight.normal)),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: m,
            builder: (context, _) => switch (_seg) {
              0 => _ActiveList(m: m),
              _ => _DoneList(m: m),
            },
          ),
        ),
      ]),
    );
  }
}

/** _statusText：任务状态文字 */
String _statusText(TransferTask t, int queuePos) {
  final dir = t.direction == Direction.up ? '上传' : '下载';
  return switch (t.status) {
    TaskStatus.running => '$dir中',
    TaskStatus.queued => queuePos > 0 ? '排队第 $queuePos 位' : '等待中',
    TaskStatus.waiting => t.error.isEmpty ? '等待中' : t.error,
    TaskStatus.paused => '已暂停',
    TaskStatus.failed => '失败：${t.error}',
    _ => '',
  };
}

/**
 * _ActiveList：进行中
 */
class _ActiveList extends StatelessWidget {
  const _ActiveList({required this.m});

  final TransferManager m;

  /** _menu：点击任务的操作 */
  Future<void> _menu(BuildContext context, TransferTask t) async {
    final running = t.status == TaskStatus.running || t.status == TaskStatus.queued || t.status == TaskStatus.waiting;
    final i = await actionSheet(context, [
      running ? const SheetAction('暂停', icon: LucideIcons.pause300) : SheetAction(t.status == TaskStatus.failed ? '重试' : '继续', icon: LucideIcons.play300),
      const SheetAction('删除任务', icon: LucideIcons.trash2300, danger: true),
    ], title: TransferManager.displayName(t));
    if (i == 0) {
      running ? m.pause(t) : m.resume(t);
    } else if (i == 1) {
      await m.cancel(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final list = m.active;
    final queued = list.where((t) => t.status == TaskStatus.queued).toList().reversed.toList();
    final blocked = m.blockedReason;
    return ListView(padding: const EdgeInsets.only(top: 12, bottom: 12), children: [
      if (blocked.isNotEmpty || m.notice.isNotEmpty)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(PdSize.smallRadius)),
          child: Row(children: [
            Icon(LucideIcons.info300, size: 16, color: c.warnText),
            const SizedBox(width: 8),
            Expanded(child: Text(blocked.isNotEmpty ? '传输已暂停：$blocked' : m.notice, style: TextStyle(fontSize: PdFont.summary, color: c.warnText))),
            if (blocked.isEmpty) GestureDetector(onTap: m.clearNotice, child: Icon(LucideIcons.x300, size: 16, color: c.warnText)),
          ]),
        ),
      if (list.isEmpty) const SizedBox(height: 360, child: EmptyHint(icon: LucideIcons.arrowUpDown300, text: '没有进行中的传输')),
      for (final t in list)
        // 左滑直接删除任务，进行中的会先停止，传了一半的临时文件一并清掉
        Dismissible(
          key: ValueKey(t.id),
          direction: DismissDirection.endToStart,
          onDismissed: (_) => m.cancel(t),
          background: Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.only(right: 20),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(color: c.danger, borderRadius: BorderRadius.circular(PdSize.cardRadius)),
            child: const Icon(LucideIcons.trash2300, color: Colors.white, size: 22),
          ),
          child: _TaskCard(t: t, queuePos: queued.indexOf(t) + 1, onTap: () => _menu(context, t), onToggle: () => t.status == TaskStatus.running || t.status == TaskStatus.queued || t.status == TaskStatus.waiting ? m.pause(t) : m.resume(t)),
        ),
      if (list.isNotEmpty)
        Center(
          child: TextButton(
            onPressed: () async {
              if (await confirm(context, title: '删除全部任务', message: '正在传的会停止，没传完的部分会被清掉。', ok: '删除')) {
                for (final t in [...list]) {
                  await m.cancel(t);
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: c.text3),
            child: const Text('删除全部任务', style: TextStyle(fontSize: PdFont.summary)),
          ),
        ),
    ]);
  }
}

/** _TaskCard：进行中的一项 */
class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.t, required this.queuePos, required this.onTap, required this.onToggle});

  final TransferTask t;
  final int queuePos;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final running = t.status == TaskStatus.running;
    final pausable = running || t.status == TaskStatus.queued || t.status == TaskStatus.waiting;
    final right = <String>[
      if (running && t.speed > 0) formatSpeed(t.speed),
      if (running && t.lanes > 1) '${t.lanes} 路',
      if (running && t.remaining >= 0) formatRemain(t.remaining),
    ].join(' · ');
    final failed = t.status == TaskStatus.failed;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Material(
        color: c.card,
        borderRadius: BorderRadius.circular(PdSize.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(t.direction == Direction.up ? LucideIcons.arrowUp300 : LucideIcons.arrowDown300, size: 16, color: t.direction == Direction.up ? c.accent : c.info),
                const SizedBox(width: 6),
                Expanded(child: Text(TransferManager.displayName(t), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: c.text, fontWeight: FontWeight.w500))),
                SizedBox(
                  width: 32,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: pausable ? '暂停' : '继续',
                    onPressed: onToggle,
                    icon: Icon(pausable ? LucideIcons.circlePause300 : (failed ? LucideIcons.rotateCw300 : LucideIcons.circlePlay300), size: 22, color: c.text2),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 6,
                  backgroundColor: c.page,
                  color: failed ? c.danger : (t.direction == Direction.up ? c.accent : c.info),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text('${formatSize(t.size)} · ${_statusText(t, queuePos)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: failed ? c.danger : c.text3)),
                ),
                if (right.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(right, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/** openLocal：用 App 内查看器打开手机上的文件，App 内不支持的格式交给其他应用 */
Future<void> openLocal(BuildContext context, String path) async {
  final file = File(path);
  if (!await file.exists()) {
    if (context.mounted) toast(context, '文件已不在手机上');
    return;
  }
  final name = file.path.split(Platform.pathSeparator).last;
  final size = await file.length();
  if (!context.mounted) return;
  await openWorkspaceFile(context, ws: phoneWorkspace(file.parent.path), entry: FileEntry(name: name, path: name, isDir: false, size: size, modTime: 0), siblings: const [], readOnly: true);
}

/**
 * _DoneList：已完成
 */
class _DoneList extends StatelessWidget {
  const _DoneList({required this.m});

  final TransferManager m;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final list = m.done..sort((a, b) => b.finishedAt.compareTo(a.finishedAt));
    if (list.isEmpty) return const EmptyHint(icon: LucideIcons.circleCheck300, text: '还没有完成的传输');
    return ListView(padding: const EdgeInsets.only(top: 12), children: [
      for (final t in list) _DoneCard(t: t),
      Center(
        child: TextButton(
          onPressed: () async {
            if (await confirm(context, title: '清空已完成记录', message: '只清除记录，不会删除文件。', ok: '清空')) await m.clearDone();
          },
          style: TextButton.styleFrom(foregroundColor: c.text3),
          child: const Text('清空记录', style: TextStyle(fontSize: PdFont.summary)),
        ),
      ),
      const SizedBox(height: 12),
    ]);
  }
}

/** _DoneCard：已完成的一项 */
class _DoneCard extends StatelessWidget {
  const _DoneCard({required this.t});

  final TransferTask t;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final up = t.direction == Direction.up;
    final name = up && t.result.isNotEmpty ? t.result.split('/').last : TransferManager.displayName(t);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Material(
        color: c.card,
        borderRadius: BorderRadius.circular(PdSize.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: up ? null : () => openLocal(context, t.result),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              FileIcon(name: name, isDir: false, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: c.text)),
                  const SizedBox(height: 2),
                  Text('${formatSize(t.size)} · ${formatListTime(t.finishedAt)} · ${up ? '已发送到电脑' : '已保存到手机'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                ]),
              ),
              Icon(up ? LucideIcons.circleCheck300 : LucideIcons.externalLink300, size: 20, color: up ? c.accent : c.text3),
            ]),
          ),
        ),
      ),
    );
  }
}
