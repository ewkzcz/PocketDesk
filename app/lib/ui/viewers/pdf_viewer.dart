/**
 * PDF 阅读：上下连续滚动、双指缩放、夜间模式、记住阅读位置；
 * 在日期文件夹内可切换上一篇、下一篇；菜单支持刷新、分享 PDF、发给会话。
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
import 'open_file.dart';

/** 反色矩阵（夜间模式） */
const _invert = ColorFilter.matrix([-1, 0, 0, 0, 255, 0, -1, 0, 0, 255, 0, 0, -1, 0, 255, 0, 0, 0, 1, 0]);

/**
 * PdfReaderPage：PDF 阅读
 */
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({super.key, required this.ws, required this.entry, this.siblings = const [], this.readOnly = false});

  final Workspace ws;
  final FileEntry entry;

  /** 同一日期文件夹中的同类文件（按时间升序），用于上一篇、下一篇 */
  final List<FileEntry> siblings;
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
   * _open：下载 PDF 并打开，跳到上次阅读的页码
   */
  Future<void> _open() async {
    final app = context.read<AppState>();
    final scope = app.scope!;
    final api = scope.conn.api;
    setState(() {
      _error = '';
      _progress = 0;
      _step = '正在下载…';
    });
    try {
      final f = await fetchToFile(scope, api.fileUrl(widget.ws.id, widget.entry.path), cacheFileFor(app, widget.ws.id, widget.entry.path, sub: 'pdf'), onProgress: (got, total) {
        if (mounted && total > 0) setState(() => _progress = got / total);
      });
      final file = f.file;
      final etag = f.etag;
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
          _error = e.message;
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

  /** _menu：右上角菜单 */
  Future<void> _menu() async {
    final items = <(SheetAction, Future<void> Function())>[
      (const SheetAction('刷新', icon: LucideIcons.refreshCw300), _open),
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
    final nav = ReaderNav.of(widget.entry, widget.siblings);
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
        if (nav.prev != null || nav.next != null)
          ReaderNavBar(nav: nav, onGo: (e) => openDocument(context, ws: widget.ws, entry: e, siblings: widget.siblings, readOnly: widget.readOnly, replace: true)),
      ]),
    );
  }
}

/** ReaderNav：同一日期文件夹中的上一篇、下一篇（不在日期文件夹时都为空） */
class ReaderNav {
  const ReaderNav(this.prev, this.next);

  final FileEntry? prev;
  final FileEntry? next;

  static ReaderNav of(FileEntry entry, List<FileEntry> siblings) {
    final parent = entry.path.contains('/') ? entry.path.substring(0, entry.path.lastIndexOf('/')) : '';
    if (!isDateFolder(parent.split('/').last)) return const ReaderNav(null, null);
    final i = siblings.indexWhere((e) => e.path == entry.path);
    if (i < 0) return const ReaderNav(null, null);
    return ReaderNav(i > 0 ? siblings[i - 1] : null, i + 1 < siblings.length ? siblings[i + 1] : null);
  }
}

/** ReaderNavBar：阅读器底部的上一篇、下一篇，也可左右滑动切换 */
class ReaderNavBar extends StatelessWidget {
  const ReaderNavBar({super.key, required this.nav, required this.onGo});

  final ReaderNav nav;
  final void Function(FileEntry e) onGo;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final prev = nav.prev;
    final next = nav.next;
    return GestureDetector(
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v > 300 && prev != null) onGo(prev);
        if (v < -300 && next != null) onGo(next);
      },
      child: Container(
        decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
        child: SafeArea(
          top: false,
          child: Row(children: [
            Expanded(child: _NavButton(label: prev == null ? '' : '上一篇：${prev.name}', icon: LucideIcons.chevronLeft300, onTap: prev == null ? null : () => onGo(prev))),
            Container(width: PdSize.divider, height: 28, color: c.divider),
            Expanded(child: _NavButton(label: next == null ? '' : '下一篇：${next.name}', icon: LucideIcons.chevronRight300, trailing: true, onTap: next == null ? null : () => onGo(next))),
          ]),
        ),
      ),
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
