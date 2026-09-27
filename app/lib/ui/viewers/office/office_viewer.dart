/**
 * Office 文档查看：Word 按纸张排版显示，Excel 按工作表显示表格（列号与行号、底部切换工作表），
 * PPT 按原稿比例逐页还原；菜单可用其他应用打开、分享、发给会话。
 */
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../data/models.dart';
import '../../../net/api.dart';
import '../../pages/chat_page.dart';
import '../../pages/session_actions.dart';
import '../../share.dart';
import '../../tokens.dart';
import '../../widgets.dart';
import '../fetch.dart';
import '../open_file.dart';
import 'office.dart';

/** OfficeKind：文档类型 */
enum OfficeKind { word, excel, slides }

/** _parse：在后台线程解析 */
Object _parse((OfficeKind, Uint8List) a) => switch (a.$1) {
  OfficeKind.word => parseDocx(a.$2),
  OfficeKind.excel => parseXlsx(a.$2),
  OfficeKind.slides => parsePptx(a.$2),
};

/**
 * OfficeViewerPage：Office 文档查看
 */
class OfficeViewerPage extends StatefulWidget {
  const OfficeViewerPage({super.key, required this.ws, required this.entry, required this.kind, this.readOnly = false, this.load});

  final Workspace ws;
  final FileEntry entry;
  final OfficeKind kind;
  final bool readOnly;

  /** load：读取文件内容，默认从电脑下载（测试时替换） */
  final Future<Uint8List> Function()? load;

  @override
  State<OfficeViewerPage> createState() => _OfficeViewerPageState();
}

class _OfficeViewerPageState extends State<OfficeViewerPage> {
  Object? _doc;
  String _error = '';
  double _progress = 0;
  int _sheet = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  /** _open：下载并解析 */
  Future<void> _open() async {
    final app = context.read<AppState>();
    final scope = app.scope!;
    setState(() {
      _error = '';
      _progress = 0;
    });
    try {
      final bytes = widget.load != null
          ? await widget.load!()
          : await (await fetchWsFile(
              scope,
              widget.ws.id,
              widget.entry.path,
              cacheFileFor(app, widget.ws.id, widget.entry.path, sub: 'office'),
              onProgress: (got, total) {
                if (mounted && total > 0) setState(() => _progress = got / total);
              },
            )).file.readAsBytes();
      final doc = await compute(_parse, (widget.kind, bytes));
      if (mounted) setState(() => _doc = doc);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法解析这个文件，可以用其他应用打开');
    }
  }

  /** _menu：用其他应用打开、分享、发给会话 */
  Future<void> _menu() async {
    final items = <(SheetAction, Future<void> Function())>[
      (const SheetAction('用其他应用打开', icon: LucideIcons.externalLink300), () => openExternally(context, ws: widget.ws, entry: widget.entry, readOnly: widget.readOnly)),
      (
        const SheetAction('分享', icon: LucideIcons.share2300),
        () async {
          final app = context.read<AppState>();
          try {
            final f = await fetchWsFile(app.scope!, widget.ws.id, widget.entry.path, cacheFileFor(app, widget.ws.id, widget.entry.path, sub: 'office'));
            await shareFile(f.file.path, title: widget.entry.name);
          } on ApiException catch (e) {
            if (mounted) toast(context, e.message);
          }
        },
      ),
      if (!isPhoneWs(widget.ws.id)) (
        const SheetAction('发给会话', icon: LucideIcons.send300),
        () async {
          final scope = context.read<AppState>().scope!;
          final sessions = scope.sessions.sessions.where((s) => s.isAgent && s.workspaceId == widget.ws.id).toList();
          if (sessions.isEmpty) {
            toast(context, '这个工作区还没有 Agent 会话');
            return;
          }
          final k = await actionSheet(context, [for (final s in sessions) SheetAction(sessionTitle(s))], title: '发给哪个会话');
          if (k != null && mounted) {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ChatPage(sessionId: sessions[k].id, draft: '请查看工作区文件 `${widget.entry.path}` '),
              ),
            );
          }
        },
      ),
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1]);
    if (i != null && mounted) await items[i].$2();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final doc = _doc;
    Widget body;
    if (_error.isNotEmpty) {
      body = EmptyHint(
        icon: LucideIcons.fileX300,
        text: _error,
        action: '用其他应用打开',
        onAction: () => openExternally(context, ws: widget.ws, entry: widget.entry, readOnly: widget.readOnly),
      );
    } else if (doc == null) {
      body = Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent, value: _progress > 0 && _progress < 1 ? _progress : null),
        ),
      );
    } else {
      body = switch (doc) {
        final List<DocBlock> b => _WordView(blocks: b),
        final List<Sheet> s => s.isEmpty ? const EmptyHint(icon: LucideIcons.sheet300, text: '这个工作簿没有工作表') : _SheetView(sheets: s, index: _sheet, onSheet: (i) => setState(() => _sheet = i)),
        final Deck d => _DeckView(deck: d),
        _ => const SizedBox.shrink(),
      };
    }
    return Scaffold(
      backgroundColor: c.page,
      appBar: PdBar(
        title: widget.entry.name,
        actions: [PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', onTap: _menu)],
      ),
      body: body,
    );
  }
}

/* ---------- Word ---------- */

/** _span：一段文字的样式 */
TextSpan _span(Run r, TextStyle base, {double scale = 1}) => TextSpan(
  text: r.text,
  style: base.copyWith(
    fontWeight: r.bold ? FontWeight.w600 : null,
    fontStyle: r.italic ? FontStyle.italic : null,
    decoration: TextDecoration.combine([if (r.underline) TextDecoration.underline, if (r.strike) TextDecoration.lineThrough]),
    // scale 为 0 时忽略原稿字号（标题统一用标题字号）
    fontSize: r.size == null || r.size == 0 || scale == 0 ? null : r.size! * scale,
    color: r.color == null ? null : Color(r.color!),
  ),
);

/** _align：段落对齐 */
TextAlign _align(String a) => switch (a) {
  'center' => TextAlign.center,
  'right' || 'end' => TextAlign.right,
  'both' || 'distribute' => TextAlign.justify,
  _ => TextAlign.left,
};

/** _WordView：白色纸张上按段落排版 */
class _WordView extends StatelessWidget {
  const _WordView({required this.blocks});

  final List<DocBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final paper = dark ? const Color(0xFF1E1E20) : Colors.white;
    final ink = dark ? const Color(0xFFE5E5E7) : const Color(0xFF1D1D1F);
    final base = TextStyle(fontSize: 15, height: 1.65, color: ink);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth - 24;
        // Word 字号以磅为单位，按 A4 版心（约 450 磅）缩放到屏幕宽度
        final scale = (width - 40) / 450 * 1.25;
        Widget paragraph(Para p) {
          const hs = [0.0, 24.0, 20.0, 18.0, 16.5, 15.5, 15.0];
          final style = p.heading > 0 ? base.copyWith(fontSize: hs[p.heading], fontWeight: FontWeight.w700, height: 1.35, letterSpacing: -0.2) : base;
          final text = Text.rich(
            TextSpan(children: [for (final r in p.runs) _span(r, style, scale: p.heading > 0 ? 0 : scale)]),
            textAlign: _align(p.align),
          );
          final child = p.list
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 18.0 + p.level * 18,
                      child: Text(p.level.isEven ? '•' : '◦', textAlign: TextAlign.right, style: base),
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: text),
                  ],
                )
              : text;
          return Padding(
            padding: EdgeInsets.only(top: p.heading > 0 ? 14 : 3, bottom: p.heading > 0 ? 6 : 3),
            child: p.runs.isEmpty ? const SizedBox(height: 10) : child,
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              decoration: BoxDecoration(
                color: paper,
                borderRadius: BorderRadius.circular(6),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.4 : 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final b in blocks)
                    switch (b) {
                      DocPara(:final para) => paragraph(para),
                      DocImage(:final bytes, width: final w) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: SizedBox(
                            width: w == null ? null : math.min(w * scale, width - 40),
                            child: Image.memory(bytes, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                          ),
                        ),
                      ),
                      DocTable(:final rows) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minWidth: width - 40),
                            child: Table(
                              defaultColumnWidth: const IntrinsicColumnWidth(),
                              border: TableBorder.all(color: ink.withValues(alpha: 0.18), width: 0.6),
                              children: [
                                for (var i = 0; i < rows.length; i++)
                                  TableRow(
                                    decoration: i == 0 ? BoxDecoration(color: ink.withValues(alpha: 0.05)) : null,
                                    children: [
                                      for (var j = 0; j < rows.map((r) => r.length).reduce(math.max); j++)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 220),
                                            child: j < rows[i].length
                                                ? Column(
                                                    crossAxisAlignment: CrossAxisAlignment.start,
                                                    children: [
                                                      for (final p in rows[i][j]) Text(p.text, style: base.copyWith(fontSize: 13.5, height: 1.45, fontWeight: i == 0 ? FontWeight.w600 : null)),
                                                    ],
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                        ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    },
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/* ---------- Excel ---------- */

/** _SheetView：表格，顶部列号、左侧行号，底部切换工作表 */
class _SheetView extends StatelessWidget {
  const _SheetView({required this.sheets, required this.index, required this.onSheet});

  final List<Sheet> sheets;
  final int index;
  final ValueChanged<int> onSheet;

  static const _rowH = 34.0;
  static const _numW = 44.0;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final s = sheets[index.clamp(0, sheets.length - 1)];
    final rows = math.max(s.rows, 1);
    final cols = math.max(s.cols, 1);
    // 列宽按内容估算
    final widths = List<double>.generate(cols, (j) {
      var n = columnName(j).length;
      for (final r in s.cells.values) {
        final t = r[j];
        if (t != null) n = math.max(n, t.runes.fold<int>(0, (a, ch) => a + (ch > 0x2E80 ? 2 : 1)));
      }
      return (n * 7.5 + 20).clamp(56, 260).toDouble();
    });
    final total = widths.fold<double>(_numW, (a, b) => a + b);
    final line = BorderSide(color: c.divider, width: 0.5);
    Widget cell(String t, double w, {bool head = false}) => Container(
      width: w,
      height: _rowH,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: head ? Alignment.center : (double.tryParse(t) != null ? Alignment.centerRight : Alignment.centerLeft),
      decoration: BoxDecoration(
        color: head ? c.bar : null,
        border: Border(right: line, bottom: line),
      ),
      child: Text(
        t,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: head ? 12 : 13.5, color: head ? c.text3 : c.text, fontWeight: head ? FontWeight.w500 : null),
      ),
    );
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Container(
                // 表格窄于屏幕时靠左并铺满，右侧留白而不是露出底色
                width: math.max(total, box.maxWidth),
                color: c.card,
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: total,
                  child: Column(
                    children: [
                      Row(children: [cell('', _numW, head: true), for (var j = 0; j < cols; j++) cell(columnName(j), widths[j], head: true)]),
                      Expanded(
                        child: ListView.builder(
                          key: ValueKey('sheet-$index'),
                          itemCount: rows,
                          itemExtent: _rowH,
                          itemBuilder: (_, i) => Row(children: [cell('${i + 1}', _numW, head: true), for (var j = 0; j < cols; j++) cell(s.cells[i]?[j] ?? '', widths[j])]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (sheets.length > 1)
          Container(
            color: c.bar,
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  children: [
                    for (var i = 0; i < sheets.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => onSheet(i),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: i == index ? c.accent : c.card, borderRadius: BorderRadius.circular(15)),
                            child: Text(sheets[i].name, style: TextStyle(fontSize: 13, color: i == index ? Colors.white : c.text2)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/* ---------- PPT ---------- */

/** _DeckView：逐页显示幻灯片 */
class _DeckView extends StatelessWidget {
  const _DeckView({required this.deck});

  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    if (deck.slides.isEmpty) return const EmptyHint(icon: LucideIcons.presentation300, text: '这份演示文稿没有幻灯片');
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      itemCount: deck.slides.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (_, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              '${i + 1} / ${deck.slides.length}',
              style: TextStyle(fontSize: PdFont.time, color: c.text3),
            ),
          ),
          _SlideView(slide: deck.slides[i], deck: deck),
        ],
      ),
    );
  }
}

/** _SlideView：一页幻灯片，形状按原稿比例定位，字号按幻灯片高度缩放 */
class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide, required this.deck});

  final Slide slide;
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: deck.aspect,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 16, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, box) {
            final k = box.maxHeight / deck.heightPt;
            return Stack(
              children: [
                for (final s in slide.shapes)
                  Positioned(
                    left: s.x * box.maxWidth,
                    top: s.y * box.maxHeight,
                    width: s.w * box.maxWidth,
                    height: s.h * box.maxHeight,
                    child: s.image != null
                        ? Image.memory(s.image!, fit: BoxFit.fill, errorBuilder: (_, _, _) => const SizedBox.shrink())
                        : Container(
                            color: s.fill == null ? null : Color(s.fill!),
                            padding: EdgeInsets.all(4 * k),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: s.title ? Alignment.centerLeft : Alignment.topLeft,
                              child: SizedBox(
                                width: s.w * box.maxWidth - 8 * k,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    for (final p in s.paras)
                                      Padding(
                                        padding: EdgeInsets.only(left: p.level * 18 * k, bottom: 4 * k),
                                        child: Text.rich(
                                          TextSpan(
                                            children: [
                                              for (final r in p.runs)
                                                _span(
                                                  r,
                                                  TextStyle(fontSize: (r.size ?? (s.title ? 32 : 18)) * k, height: 1.25, color: const Color(0xFF1D1D1F), fontWeight: s.title ? FontWeight.w700 : null),
                                                ),
                                            ],
                                          ),
                                          textAlign: _align(p.align),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
