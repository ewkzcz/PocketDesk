/**
 * PDF 阅读：Markdown 由电脑转换为 PDF 后阅读（本地已有相同版本时跳过下载），上下连续滚动、双指缩放、夜间模式、记住阅读位置；
 * 在日期文件夹内可切换上一篇、下一篇；菜单支持刷新、查看源文件、分享 PDF、发给会话。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdfx/pdfx.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../format.dart';
import '../pages/chat_page.dart';
import '../pages/session_actions.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'fetch.dart';
import 'text_viewer.dart';

/** 反色矩阵（夜间模式） */
const _invert = ColorFilter.matrix([-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]);

/**
 * PdfReaderPage：PDF 阅读
 */
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({super.key, required this.ws, required this.entry, this.siblings = const [], required this.markdown, this.readOnly = false});

  final Workspace ws;
  final FileEntry entry;

  /** 同一日期文件夹中的同类文件（按时间升序），用于上一篇、下一篇 */
  final List<FileEntry> siblings;
  final bool markdown;
  final bool readOnly;

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  PdfControllerPinch? _ctrl;
  File? _file;
  String _etag = '';
  String _step = '';
  String _error = '';
  double _progress = 0;
  int _page = 1;
  int _pages = 0;
  bool _night = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _night = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    _open();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  /**
   * _open：准备 PDF 并打开
   *
   * 处理流程：
   * 1、Markdown 先请求电脑转换（命中缓存时很快返回）；PDF 直接下载
   * 2、本地已有同一版本（ETag 相同）时跳过下载
   * 3、打开文档并跳到上次阅读的页码
   */
  Future<void> _open({bool force = false}) async {
    final app = context.read<AppState>();
    final scope = app.scope!;
    final api = scope.conn.api;
    setState(() {
      _error = '';
      _progress = 0;
      _step = widget.markdown ? (force ? '正在重新转换…' : '正在转换为 PDF…') : '正在下载…';
    });
    try {
      // 1、转换
      Uri url;
      var etag = '';
      if (widget.markdown) {
        final r = await api.render(widget.ws.id, widget.entry.path, force: force);
        url = api.base.resolve(r.url);
        etag = r.etag;
      } else {
        url = api.fileUrl(widget.ws.id, widget.entry.path);
      }
      // 2、本地缓存
      final key = etag.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final dest = cacheFileFor(app, widget.ws.id, widget.markdown ? '${widget.entry.path}.$key.pdf' : widget.entry.path, sub: 'pdf');
      File file;
      if (widget.markdown && key.isNotEmpty && await dest.exists()) {
        file = dest;
      } else {
        if (mounted) setState(() => _step = '正在下载…');
        final f = await fetchToFile(scope, url, dest, onProgress: (got, total) {
          if (mounted && total > 0) setState(() => _progress = got / total);
        });
        file = f.file;
        if (etag.isEmpty) etag = f.etag;
      }
      // 3、打开
      final page = await scope.sessions.db.position(scope.host.id, widget.ws.id, widget.entry.path);
      if (!mounted) return;
      _ctrl?.dispose();
      setState(() {
        _file = file;
        _etag = etag;
        _page = page;
        _ctrl = PdfControllerPinch(document: PdfDocument.openFile(file.path), initialPage: page);
        _step = '';
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.code == 'render_unavailable' || e.status == 503 ? '电脑上没有可用于转换的浏览器，请安装 Chrome 或 Edge' : e.message;
          _step = '';
        });
      }
    }
  }

  /** _onPage：翻页时延迟保存阅读位置 */
  void _onPage(int p) {
    setState(() => _page = p);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      final scope = context.read<AppState>().scope;
      if (scope != null) scope.sessions.db.savePosition(scope.host.id, widget.ws.id, widget.entry.path, _etag, p);
    });
  }

  /** _neighbor：同一日期文件夹中的上一篇或下一篇 */
  FileEntry? _neighbor(int delta) {
    final parent = widget.entry.path.contains('/') ? widget.entry.path.substring(0, widget.entry.path.lastIndexOf('/')) : '';
    if (!isDateFolder(parent.split('/').last)) return null;
    final list = widget.siblings;
    final i = list.indexWhere((e) => e.path == widget.entry.path);
    if (i < 0) return null;
    final j = i + delta;
    return j >= 0 && j < list.length ? list[j] : null;
  }

  /** _go：切换到另一篇 */
  void _go(FileEntry e) {
    Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => PdfReaderPage(ws: widget.ws, entry: e, siblings: widget.siblings, markdown: e.name.toLowerCase().endsWith('.md') || e.name.toLowerCase().endsWith('.markdown'), readOnly: widget.readOnly),
      transitionDuration: PdMotion.normal,
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  /** _menu：右上角菜单 */
  Future<void> _menu() async {
    final items = <(SheetAction, Future<void> Function())>[
      (SheetAction(widget.markdown ? '刷新（重新转换）' : '刷新', icon: LucideIcons.refreshCw300), () => _open(force: widget.markdown)),
      if (widget.markdown)
        (SheetAction(widget.readOnly ? '以纯文本查看源文件' : '查看或编辑源文件', icon: LucideIcons.fileCode300), () async {
          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TextViewerPage(ws: widget.ws, path: widget.entry.path, readOnly: widget.readOnly)));
          if (mounted) await _open();
        }),
      (SheetAction(_night ? '关闭夜间模式' : '夜间模式', icon: LucideIcons.moon300), () async => setState(() => _night = !_night)),
      (const SheetAction('分享 PDF', icon: LucideIcons.share2300), () async {
        final f = _file;
        if (f != null) await shareFile(f.path, title: widget.entry.name);
      }),
      (const SheetAction('发给会话', icon: LucideIcons.send300), _sendToSession),
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1]);
    if (i != null && mounted) await items[i].$2();
  }

  /** _sendToSession：把文件路径带到同一工作区的 Agent 会话 */
  Future<void> _sendToSession() async {
    final scope = context.read<AppState>().scope!;
    final sessions = scope.sessions.sessions.where((s) => s.isAgent && s.workspaceId == widget.ws.id).toList();
    if (sessions.isEmpty) {
      toast(context, '这个工作区还没有 Agent 会话');
      return;
    }
    final k = await actionSheet(context, [for (final s in sessions) SheetAction(sessionTitle(s))], title: '发给哪个会话');
    if (k != null && mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: sessions[k].id, draft: '请查看工作区文件 `${widget.entry.path}` ')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final prev = _neighbor(-1);
    final next = _neighbor(1);
    final ctrl = _ctrl;
    Widget body;
    if (_error.isNotEmpty) {
      body = EmptyHint(icon: LucideIcons.fileX300, text: _error, action: '重试', onAction: () => _open());
    } else if (ctrl == null || _step.isNotEmpty) {
      body = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent, value: _progress > 0 && _progress < 1 ? _progress : null)),
          const SizedBox(height: 12),
          Text(_step, style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
        ]),
      );
    } else {
      final view = PdfViewPinch(
        controller: ctrl,
        padding: 8,
        onPageChanged: _onPage,
        onDocumentLoaded: (d) => setState(() => _pages = d.pagesCount),
        onDocumentError: (_) => setState(() => _error = 'PDF 打开失败'),
        backgroundDecoration: BoxDecoration(color: _night ? Colors.white : c.page),
      );
      body = _night ? ColorFiltered(colorFilter: _invert, child: view) : view;
    }
    return Scaffold(
      appBar: PdBar(
        title: widget.entry.name,
        subtitle: _pages > 0 ? '$_page / $_pages' : '',
        actions: [PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', onTap: _file == null ? null : _menu)],
      ),
      body: Column(children: [
        Expanded(child: body),
        if (prev != null || next != null)
          GestureDetector(
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (v > 300 && prev != null) _go(prev);
              if (v < -300 && next != null) _go(next);
            },
            child: Container(
              decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
              child: SafeArea(
                top: false,
                child: Row(children: [
                  Expanded(child: _NavButton(label: prev == null ? '' : '上一篇：${prev.name}', icon: LucideIcons.chevronLeft300, onTap: prev == null ? null : () => _go(prev))),
                  Container(width: PdSize.divider, height: 28, color: c.divider),
                  Expanded(child: _NavButton(label: next == null ? '' : '下一篇：${next.name}', icon: LucideIcons.chevronRight300, trailing: true, onTap: next == null ? null : () => _go(next))),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/** _NavButton：上一篇、下一篇 */
class _NavButton extends StatelessWidget {
  const _NavButton({required this.label, required this.icon, required this.onTap, this.trailing = false});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final color = onTap == null ? c.text4 : c.text2;
    final text = Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: color)));
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(mainAxisAlignment: trailing ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
            if (!trailing && label.isNotEmpty) Icon(icon, size: 16, color: color),
            text,
            if (trailing && label.isNotEmpty) Icon(icon, size: 16, color: color),
          ]),
        ),
      ),
    );
  }
}
