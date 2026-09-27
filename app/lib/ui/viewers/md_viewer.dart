/**
 * Markdown 阅读：在手机上直接排版显示，支持表格、任务列表、代码高亮、数学公式与工作区内的图片；
 * 大纲目录快速跳转、按屏翻页、显示阅读进度；跟随深浅色主题，记住阅读位置；在日期文件夹内可切换上一篇、下一篇；
 * 菜单支持刷新、查看或编辑源文件、分享、发给会话。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:provider/provider.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../chat/markdown.dart';
import '../pages/chat_page.dart';
import '../pages/session_actions.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'fetch.dart';
import 'image_viewer.dart';
import 'open_file.dart';
import 'pdf_viewer.dart';
import 'text_viewer.dart';

/**
 * MarkdownReaderPage：Markdown 阅读
 */
class MarkdownReaderPage extends StatefulWidget {
  const MarkdownReaderPage({super.key, required this.ws, required this.entry, this.siblings = const [], this.readOnly = false});

  final Workspace ws;
  final FileEntry entry;

  /** 同一日期文件夹中的文档（按时间升序），用于上一篇、下一篇 */
  final List<FileEntry> siblings;
  final bool readOnly;

  @override
  State<MarkdownReaderPage> createState() => _MarkdownReaderPageState();
}

class _MarkdownReaderPageState extends State<MarkdownReaderPage> {
  final _scroll = AutoScrollController();
  String? _text;
  String _error = '';
  Timer? _saveTimer;

  /** 排版结果按正文与深浅色缓存，避免每次重绘都重新解析 */
  List<Widget> _widgets = const [];
  List<Toc> _toc = const [];
  Object? _builtFor;

  /** 阅读进度（0–1） */
  final _progress = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _open();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll.dispose();
    _progress.dispose();
    super.dispose();
  }

  /**
   * _open：读取源文件并回到上次阅读的位置
   */
  Future<void> _open() async {
    final scope = context.read<AppState>().scope!;
    setState(() => _error = '');
    try {
      final r = await scope.conn.api.readFile(widget.ws.id, widget.entry.path);
      final offset = await scope.sessions.db.offset(scope.host.id, widget.ws.id, widget.entry.path);
      if (!mounted) return;
      setState(() => _text = utf8.decode(r.bytes, allowMalformed: true));
      if (offset > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /** _onScroll：更新进度，滚动停下后保存阅读位置 */
  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.maxScrollExtent > 0) {
      _progress.value = (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0, 1);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      final scope = context.read<AppState>().scope;
      if (scope != null && _scroll.hasClients) scope.sessions.db.saveOffset(scope.host.id, widget.ws.id, widget.entry.path, _scroll.offset);
    });
  }

  /** _page：按屏翻页，保留一行左右的重叠，避免漏读 */
  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (pos.pixels + dir * (pos.viewportDimension - 48)).clamp(0.0, pos.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  /** _currentHeading：屏幕顶部所在的章节（最后一个已经滚过顶部的标题） */
  int _currentHeading() {
    var cur = -1;
    for (var i = 0; i < _toc.length; i++) {
      final tag = _scroll.tagMap[_toc[i].widgetIndex];
      final box = tag?.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) {
        // 没有构建的标题：在已知标题之前的都算已读过
        if (cur >= 0 && _toc[i].widgetIndex < _toc[cur].widgetIndex) cur = i;
        continue;
      }
      final top = box.localToGlobal(Offset.zero).dy;
      if (top <= kToolbarHeight + MediaQuery.paddingOf(context).top + 40) cur = i;
    }
    return cur;
  }

  /** _outline：大纲目录，点标题跳过去 */
  Future<void> _outline() async {
    if (_toc.isEmpty) {
      toast(context, '这篇文档没有标题');
      return;
    }
    final cur = _currentHeading();
    final c = context.pd;
    final minLevel = _toc.map(_level).reduce((a, b) => a < b ? a : b);
    final i = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Text('目录', style: TextStyle(fontSize: PdFont.listTitle, fontWeight: FontWeight.w600, color: c.text)),
                const Spacer(),
                Text('${_toc.length} 节', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
              ]),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _toc.length,
                itemBuilder: (_, k) {
                  final on = k == cur;
                  final lv = _level(_toc[k]) - minLevel;
                  return InkWell(
                    onTap: () => Navigator.pop(ctx, k),
                    child: Container(
                      padding: EdgeInsets.fromLTRB(20.0 + lv * 16, 11, 20, 11),
                      color: on ? c.accentSoft : null,
                      child: Text(
                        _tocTitle(_toc[k]),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: lv == 0 ? PdFont.item : PdFont.summary, fontWeight: lv == 0 ? FontWeight.w600 : FontWeight.w400, color: on ? c.accent : (lv == 0 ? c.text : c.text2)),
                      ),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
      ),
    );
    if (i != null) await _scroll.scrollToIndex(_toc[i].widgetIndex, preferPosition: AutoScrollPosition.begin, duration: const Duration(milliseconds: 320));
  }

  /** _level：标题层级 1–6 */
  static int _level(Toc t) => int.tryParse(t.node.headingConfig.tag.substring(1)) ?? 1;

  /** _tocTitle：标题文字 */
  static String _tocTitle(Toc t) => t.node.childrenSpan.toPlainText().trim();

  /** _build：排版，正文或深浅色变化时重新生成 */
  void _build(BuildContext context, String text) {
    final key = (text, Theme.of(context).brightness);
    if (key == _builtFor) return;
    _builtFor = key;
    final config = MdText.config(context, fontSize: 16).copy(configs: [
      ImgConfig(builder: (url, attrs) => _MdImage(ws: widget.ws, dir: _dir, url: url, alt: attrs['alt'] ?? '')),
    ]);
    var toc = <Toc>[];
    final widgets = MarkdownGenerator(
      linesMargin: const EdgeInsets.symmetric(vertical: 4),
      inlineSyntaxList: [_LatexSyntax()],
      generators: [_latexGenerator],
    ).buildWidgets(text, config: config, onTocList: (l) => toc = l);
    _widgets = [for (var i = 0; i < widgets.length; i++) AutoScrollTag(key: ValueKey(i), controller: _scroll, index: i, child: widgets[i])];
    _toc = toc;
  }

  /** _dir：文档所在目录（相对工作区根） */
  String get _dir => widget.entry.path.contains('/') ? widget.entry.path.substring(0, widget.entry.path.lastIndexOf('/')) : '';

  /** _menu：右上角菜单 */
  Future<void> _menu() async {
    final items = <(SheetAction, Future<void> Function())>[
      (const SheetAction('刷新', icon: LucideIcons.refreshCw300), _open),
      (SheetAction(widget.readOnly ? '以纯文本查看源文件' : '查看或编辑源文件', icon: LucideIcons.fileCode300), () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TextViewerPage(ws: widget.ws, path: widget.entry.path, readOnly: widget.readOnly)));
        if (mounted) await _open();
      }),
      (const SheetAction('分享', icon: LucideIcons.share2300), _share),
      (const SheetAction('发给会话', icon: LucideIcons.send300), _sendToSession),
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1]);
    if (i != null && mounted) await items[i].$2();
  }

  /** _share：下载到缓存后交给系统分享 */
  Future<void> _share() async {
    final app = context.read<AppState>();
    final scope = app.scope!;
    try {
      final f = await fetchToFile(scope, scope.conn.api.fileUrl(widget.ws.id, widget.entry.path), cacheFileFor(app, widget.ws.id, widget.entry.path));
      await shareFile(f.file.path, title: widget.entry.name);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
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
    final text = _text;
    Widget body;
    if (_error.isNotEmpty) {
      body = EmptyHint(icon: LucideIcons.fileX300, text: _error, action: '重试', onAction: _open);
    } else if (text == null) {
      body = Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent)));
    } else {
      _build(context, text);
      body = Stack(children: [
        Container(
          color: c.card,
          child: SelectionArea(
            child: ListView(
              key: const ValueKey('md-reader'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 96),
              children: _widgets,
            ),
          ),
        ),
        // 阅读进度
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, v, _) => Align(alignment: Alignment.centerLeft, child: FractionallySizedBox(widthFactor: v, child: Container(height: 2, color: c.accent))),
          ),
        ),
        // 翻页
        Positioned(
          right: 14,
          bottom: 16,
          child: Column(children: [
            ValueListenableBuilder<double>(
              valueListenable: _progress,
              builder: (_, v, _) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${(v * 100).round()}%', style: TextStyle(fontSize: PdFont.tiny, color: c.text3))),
            ),
            _PageButton(icon: LucideIcons.chevronUp300, tooltip: '上一页', onTap: () => _page(-1)),
            const SizedBox(height: 10),
            _PageButton(icon: LucideIcons.chevronDown300, tooltip: '下一页', onTap: () => _page(1)),
          ]),
        ),
      ]);
    }
    return Scaffold(
      appBar: PdBar(
        title: widget.entry.name,
        actions: [
          if (text != null) PdIconButton(icon: LucideIcons.listTree300, tooltip: '目录', onTap: _outline),
          PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', onTap: text == null ? null : _menu),
        ],
      ),
      body: Column(children: [
        Expanded(child: body),
        if (nav.prev != null || nav.next != null)
          ReaderNavBar(nav: nav, onGo: (e) => openDocument(context, ws: widget.ws, entry: e, siblings: widget.siblings, readOnly: widget.readOnly, replace: true)),
      ]),
    );
  }
}

/** _PageButton：悬浮的翻页按钮，半透明磨砂底 */
class _PageButton extends StatelessWidget {
  const _PageButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Semantics(
      button: true,
      label: tooltip,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Material(
            color: c.bar.withValues(alpha: 0.72),
            child: InkWell(
              onTap: onTap,
              child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: c.text2)),
            ),
          ),
        ),
      ),
    );
  }
}

/**
 * _MdImage：文档中的图片；相对路径从工作区读取（经证书固定的连接），网络图片直接加载
 */
class _MdImage extends StatefulWidget {
  const _MdImage({required this.ws, required this.dir, required this.url, required this.alt});

  final Workspace ws;
  final String dir;
  final String url;
  final String alt;

  @override
  State<_MdImage> createState() => _MdImageState();
}

class _MdImageState extends State<_MdImage> {
  late final Future<Uint8List?> _bytes = _load();

  bool get _remote => widget.url.startsWith('http://') || widget.url.startsWith('https://');

  /** _path：相对 md 所在目录解析，越出工作区的由电脑端拒绝 */
  String get _path {
    var u = Uri.decodeFull(widget.url.split('?').first.split('#').first);
    if (u.startsWith('./')) u = u.substring(2);
    final parts = [if (widget.dir.isNotEmpty) ...widget.dir.split('/'), ...u.split('/')];
    final out = <String>[];
    for (final p in parts) {
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else if (p.isNotEmpty && p != '.') {
        out.add(p);
      }
    }
    return out.join('/');
  }

  Future<Uint8List?> _load() async {
    if (_remote || widget.url.startsWith('data:')) return null;
    try {
      final r = await context.read<AppState>().scope!.conn.api.readFile(widget.ws.id, _path);
      return Uint8List.fromList(r.bytes);
    } on ApiException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final broken = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(LucideIcons.imageOff300, size: 18, color: c.text3),
      if (widget.alt.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 6), child: Text(widget.alt, style: TextStyle(fontSize: PdFont.summary, color: c.text3))),
    ]);
    if (_remote) {
      return Image.network(widget.url, errorBuilder: (_, _, _) => broken);
    }
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) {
        final b = snap.data;
        if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 120);
        if (b == null) return broken;
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => ImageViewerPage(ws: widget.ws, images: [FileEntry(name: _path.split('/').last, path: _path, isDir: false, size: b.length, modTime: 0)], index: 0))),
          child: Image.memory(b, errorBuilder: (_, _, _) => broken),
        );
      },
    );
  }
}

/* ---------- 数学公式：$…$ 行内，$$…$$ 独占一行 ---------- */

const _latexTag = 'latex';

/** _latexGenerator：把公式节点交给 [_LatexNode] 绘制 */
final _latexGenerator = SpanNodeGeneratorWithTag(tag: _latexTag, generator: (e, config, visitor) => _LatexNode(e.attributes, e.textContent, config));

/** _LatexSyntax：识别 $$…$$ 与 $…$ */
class _LatexSyntax extends m.InlineSyntax {
  _LatexSyntax() : super(r'(\$\$[\s\S]+?\$\$)|(\$[^\$\n]+?\$)');

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final v = match[0]!;
    final block = v.startsWith(r'$$');
    final el = m.Element.text(_latexTag, v);
    el.attributes['content'] = block ? v.substring(2, v.length - 2).trim() : v.substring(1, v.length - 1);
    el.attributes['block'] = '$block';
    parser.addNode(el);
    return true;
  }
}

/** _LatexNode：公式，写错时原样显示 */
class _LatexNode extends SpanNode {
  _LatexNode(this.attributes, this.textContent, this.config);

  final Map<String, String> attributes;
  final String textContent;
  final MarkdownConfig config;

  @override
  InlineSpan build() {
    final content = attributes['content'] ?? '';
    final block = attributes['block'] == 'true';
    final style = parentStyle ?? config.p.textStyle;
    if (content.isEmpty) return TextSpan(style: style, text: textContent);
    final tex = Math.tex(content, mathStyle: block ? MathStyle.display : MathStyle.text, textStyle: style, onErrorFallback: (_) => Text(textContent, style: style));
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: block
          ? Container(
              width: double.infinity,
              alignment: Alignment.center,
              margin: const EdgeInsets.symmetric(vertical: 8),
              // 过宽的公式按屏幕宽度缩小
              child: FittedBox(fit: BoxFit.scaleDown, child: tex),
            )
          : tex,
    );
  }
}
