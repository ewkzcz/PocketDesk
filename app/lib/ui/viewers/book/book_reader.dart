/**
 * 小说阅读：整本 txt 按章节分页，衬线字体与纸张底色；点屏幕左右两侧或左右滑动翻页，点中间呼出控制栏；
 * 目录跳章、字号与行距、纸张 / 护眼 / 夜间三种底色；记住读到的章节与位置；菜单可改为纯文本查看或编辑。
 */
library;

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../core/settings.dart';
import '../../../data/models.dart';
import '../../../net/api.dart';
import '../../share.dart';
import '../../tokens.dart';
import '../../widgets.dart';
import '../fetch.dart';
import '../text_viewer.dart';
import 'book.dart';

/** BookTheme：一种阅读底色 */
class BookTheme {
  const BookTheme(this.id, this.name, this.page, this.text, this.muted);

  final String id;
  final String name;
  final Color page;
  final Color text;
  final Color muted;
}

/** 三种底色：纸张、护眼、夜间 */
const bookThemes = [
  BookTheme('paper', '纸张', Color(0xFFF6EEDC), Color(0xFF3A3024), Color(0xFF9A8B73)),
  BookTheme('green', '护眼', Color(0xFFD9EBD5), Color(0xFF263826), Color(0xFF6F8A6C)),
  BookTheme('night', '夜间', Color(0xFF121214), Color(0xFF8E8E93), Color(0xFF55555A)),
];

/** 中文衬线字体，各平台依次尝试 */
const _serif = ['Songti SC', 'STSong', 'Noto Serif CJK SC', 'Source Han Serif SC', 'serif'];

/** _Loaded：解码与分章结果（在后台线程完成） */
typedef _Loaded = ({String text, List<Chapter> chapters});

_Loaded _parse(Uint8List b) {
  final text = decodeText(b);
  return (text: text, chapters: splitChapters(text));
}

/**
 * BookReaderPage：小说阅读
 */
class BookReaderPage extends StatefulWidget {
  const BookReaderPage({super.key, required this.ws, required this.entry, this.readOnly = false, this.load});

  final Workspace ws;
  final FileEntry entry;
  final bool readOnly;

  /** load：读取文件内容，默认从电脑下载（测试时替换） */
  final Future<Uint8List> Function()? load;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  String? _text;
  List<Chapter> _chapters = const [];
  String _error = '';
  double _progress = 0;

  int _chapter = 0;
  int _page = 0;

  /** 待定位的章内位置：打开时恢复上次阅读，改字号后保持在同一段 */
  int? _seek;

  /** 各章整理后的文字与分页，排版参数变化时清空 */
  final _tidy = <int, String>{};
  final _pages = <int, List<int>>{};
  Object? _layoutKey;

  bool _controls = false;
  int _dir = 1;
  Timer? _saveTimer;
  HostScope? _scope;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _open();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _save();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  /**
   * _open：下载整本书、解码分章，回到上次读到的位置
   */
  Future<void> _open() async {
    final app = context.read<AppState>();
    final scope = app.scope!;
    _scope = scope;
    setState(() {
      _error = '';
      _progress = 0;
    });
    try {
      final bytes = widget.load != null
          ? await widget.load!()
          : await (await fetchToFile(scope, scope.conn.api.fileUrl(widget.ws.id, widget.entry.path), cacheFileFor(app, widget.ws.id, widget.entry.path, sub: 'book'), onProgress: (got, total) {
              if (mounted && total > 0) setState(() => _progress = got / total);
            }))
              .file
              .readAsBytes();
      final loaded = await compute(_parse, bytes);
      final pos = await scope.sessions.db.bookPos(scope.host.id, widget.ws.id, widget.entry.path);
      if (!mounted) return;
      setState(() {
        _text = loaded.text;
        _chapters = loaded.chapters;
        _chapter = pos.chapter.clamp(0, loaded.chapters.length - 1);
        _seek = pos.offset;
        _tidy.clear();
        _pages.clear();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /** _chapterText：整理后的章节文字 */
  String _chapterText(int i) => _tidy.putIfAbsent(i, () {
        final c = _chapters[i];
        return tidy(_text!.substring(c.start, c.end));
      });

  /** _pagesOf：一章的分页 */
  List<int> _pagesOf(int i, TextStyle style, Size size) => _pages.putIfAbsent(i, () => paginate(_chapterText(i), style, size));

  /** _save：延迟保存阅读位置（章节与本页开头在章内的位置） */
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _save);
  }

  void _save() {
    final scope = _scope;
    final pages = _pages[_chapter];
    if (scope == null || pages == null || _text == null) return;
    scope.sessions.db.saveBookPos(scope.host.id, widget.ws.id, widget.entry.path, _chapter, pages[_page.clamp(0, pages.length - 1)]);
  }

  /** _turn：翻页，跨章时进入上一章末页或下一章首页 */
  void _turn(int d) {
    final pages = _pages[_chapter];
    if (pages == null) return;
    setState(() {
      _dir = d;
      _controls = false;
      if (d > 0) {
        if (_page + 1 < pages.length) {
          _page++;
        } else if (_chapter + 1 < _chapters.length) {
          _chapter++;
          _page = 0;
        }
      } else {
        if (_page > 0) {
          _page--;
        } else if (_chapter > 0) {
          _chapter--;
          _page = -1; // 排版后定位到末页
        }
      }
    });
    HapticFeedback.selectionClick();
    _scheduleSave();
  }

  /** _goChapter：跳到某一章开头 */
  void _goChapter(int i) {
    setState(() {
      _dir = i >= _chapter ? 1 : -1;
      _chapter = i.clamp(0, _chapters.length - 1);
      _page = 0;
      _controls = false;
    });
    _scheduleSave();
  }

  /** _relayout：排版参数改变，保持在当前段落 */
  void _relayout(VoidCallback change) {
    final pages = _pages[_chapter];
    _seek = pages == null ? null : pages[_page.clamp(0, pages.length - 1)];
    change();
  }

  /** _catalog：目录 */
  Future<void> _catalog(BookTheme t) async {
    final i = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.page,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.72,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(children: [
                Text('目录', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.text)),
                const Spacer(),
                Text('共 ${_chapters.length} 章', style: TextStyle(fontSize: PdFont.time, color: t.muted)),
              ]),
            ),
            Expanded(
              child: ListView.builder(
                controller: ScrollController(initialScrollOffset: (_chapter - 4).clamp(0, _chapters.length) * 48.0),
                itemExtent: 48,
                itemCount: _chapters.length,
                itemBuilder: (_, k) => InkWell(
                  onTap: () => Navigator.pop(ctx, k),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(_chapters[k].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 15, fontFamilyFallback: _serif, color: k == _chapter ? context.pd.accent : t.text, fontWeight: k == _chapter ? FontWeight.w600 : FontWeight.w400)),
                    ),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
    if (i != null) _goChapter(i);
  }

  /** _menu：以纯文本查看或编辑、分享 */
  Future<void> _menu() async {
    final items = <(SheetAction, Future<void> Function())>[
      (SheetAction(widget.readOnly ? '以纯文本查看' : '以纯文本查看或编辑', icon: LucideIcons.fileCode300), () async {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TextViewerPage(ws: widget.ws, path: widget.entry.path, readOnly: widget.readOnly)));
      }),
      (const SheetAction('分享', icon: LucideIcons.share2300), () async {
        final app = context.read<AppState>();
        await shareFile(cacheFileFor(app, widget.ws.id, widget.entry.path, sub: 'book').path, title: widget.entry.name);
      }),
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1]);
    if (i != null && mounted) await items[i].$2();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final t = bookThemes.firstWhere((x) => x.id == s.readerTheme, orElse: () => dark ? bookThemes[2] : bookThemes[0]);
    final style = TextStyle(fontSize: s.readerFontSize, height: s.readerLineHeight, color: t.text, fontFamilyFallback: _serif, letterSpacing: 0.3);
    final text = _text;
    Widget content;
    if (_error.isNotEmpty) {
      content = EmptyHint(icon: LucideIcons.fileX300, text: _error, action: '重试', onAction: _open);
    } else if (text == null) {
      content = Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: t.muted, value: _progress > 0 && _progress < 1 ? _progress : null)),
          const SizedBox(height: 12),
          Text('正在打开…', style: TextStyle(fontSize: PdFont.summary, color: t.muted)),
        ]),
      );
    } else {
      content = LayoutBuilder(builder: (context, box) {
        const pad = EdgeInsets.fromLTRB(26, 12, 26, 12);
        final size = Size(box.maxWidth - pad.horizontal, box.maxHeight - 64 - pad.vertical);
        final key = (size, style.fontSize, style.height);
        if (key != _layoutKey) {
          _layoutKey = key;
          _pages.clear();
        }
        final pages = _pagesOf(_chapter, style, size);
        // 定位：恢复位置或改字号后找到包含该位置的页；跨章回翻时为末页
        if (_seek != null) {
          final off = _seek!;
          _page = pages.lastIndexWhere((p) => p <= off).clamp(0, pages.length - 1);
          _seek = null;
        } else if (_page < 0 || _page >= pages.length) {
          _page = pages.length - 1;
        }
        final chapterText = _chapterText(_chapter);
        final overall = _chapters.length <= 1 ? (_page + 1) / pages.length : (_chapter + (_page + 1) / pages.length) / _chapters.length;
        return Column(children: [
          SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Align(alignment: Alignment.bottomLeft, child: Text(_chapters[_chapter].title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: t.muted, fontFamilyFallback: _serif))),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, a) {
                final incoming = child.key == ValueKey((_chapter, _page));
                final from = Offset(incoming ? 0.18 * _dir : -0.06 * _dir, 0);
                return FadeTransition(opacity: a, child: SlideTransition(position: Tween(begin: from, end: Offset.zero).animate(a), child: child));
              },
              child: Padding(
                key: ValueKey((_chapter, _page)),
                padding: pad,
                child: SizedBox.expand(
                  child: Text(pageText(chapterText, pages, _page), style: style, overflow: TextOverflow.clip),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 32,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 26),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_page + 1} / ${pages.length}', style: TextStyle(fontSize: 12, color: t.muted)),
                const Spacer(),
                Text('${(overall * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 12, color: t.muted)),
              ]),
            ),
          ),
        ]);
      });
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: t.id == 'night' ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: t.page,
        body: Stack(children: [
          // 纸张质感：极淡的上下渐变，四角略暗
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.2,
                  colors: [t.page, Color.lerp(t.page, t.id == 'night' ? Colors.black : const Color(0xFF8A7650), 0.06)!],
                ),
              ),
            ),
          ),
          SafeArea(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: text == null
                  ? null
                  : (d) {
                      final w = MediaQuery.sizeOf(context).width;
                      if (d.localPosition.dx < w / 3) {
                        _turn(-1);
                      } else if (d.localPosition.dx > w * 2 / 3) {
                        _turn(1);
                      } else {
                        setState(() => _controls = !_controls);
                      }
                    },
              onHorizontalDragEnd: text == null
                  ? null
                  : (d) {
                      final v = d.primaryVelocity ?? 0;
                      if (v < -200) _turn(1);
                      if (v > 200) _turn(-1);
                    },
              child: content,
            ),
          ),
          if (text != null) ..._overlay(context, s, t),
        ]),
      ),
    );
  }

  /** _overlay：顶部与底部的磨砂控制栏 */
  List<Widget> _overlay(BuildContext context, AppSettings s, BookTheme t) {
    final bar = Color.lerp(t.page, t.id == 'night' ? Colors.black : Colors.white, 0.35)!.withValues(alpha: 0.86);
    Widget frosted(Widget child) => ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24), child: Container(color: bar, child: child)));
    Widget chip(String label, bool on, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(color: on ? context.pd.accent : t.text.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(16)),
            child: Text(label, style: TextStyle(fontSize: 13, color: on ? Colors.white : t.text)),
          ),
        );
    return [
      AnimatedPositioned(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        left: 0,
        right: 0,
        top: _controls ? 0 : -120,
        child: frosted(SafeArea(
          bottom: false,
          child: SizedBox(
            height: 48,
            child: Row(children: [
              PdIconButton(icon: LucideIcons.chevronLeft300, color: t.text, tooltip: '返回', onTap: () => Navigator.of(context).maybePop()),
              Expanded(child: Text(widget.entry.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, color: t.text, fontWeight: FontWeight.w500))),
              PdIconButton(icon: LucideIcons.listTree300, color: t.text, tooltip: '目录', onTap: () => _catalog(t)),
              PdIconButton(icon: LucideIcons.ellipsis300, color: t.text, tooltip: '更多', onTap: _menu),
            ]),
          ),
        )),
      ),
      AnimatedPositioned(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        left: 0,
        right: 0,
        bottom: _controls ? 0 : -260,
        child: frosted(SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                TextButton(onPressed: _chapter > 0 ? () => _goChapter(_chapter - 1) : null, child: const Text('上一章')),
                Expanded(
                  child: Slider(
                    value: _chapter.toDouble(),
                    max: (_chapters.length - 1).clamp(1, 1 << 30).toDouble(),
                    activeColor: context.pd.accent,
                    onChanged: _chapters.length <= 1 ? null : (v) => _goChapter(v.round()),
                  ),
                ),
                TextButton(onPressed: _chapter + 1 < _chapters.length ? () => _goChapter(_chapter + 1) : null, child: const Text('下一章')),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Text('字号', style: TextStyle(fontSize: 13, color: t.muted)),
                const SizedBox(width: 12),
                PdIconButton(icon: LucideIcons.aArrowDown300, color: t.text, tooltip: '字号减小', onTap: () => _relayout(() => s.readerFontSize = s.readerFontSize - 1)),
                SizedBox(width: 32, child: Text('${s.readerFontSize.round()}', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: t.text))),
                PdIconButton(icon: LucideIcons.aArrowUp300, color: t.text, tooltip: '字号增大', onTap: () => _relayout(() => s.readerFontSize = s.readerFontSize + 1)),
                const Spacer(),
                for (final (v, label) in [(1.55, '紧'), (1.85, '中'), (2.2, '松')]) ...[
                  chip(label, (s.readerLineHeight - v).abs() < 0.01, () => _relayout(() => s.readerLineHeight = v)),
                  const SizedBox(width: 6),
                ],
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Text('底色', style: TextStyle(fontSize: 13, color: t.muted)),
                const SizedBox(width: 16),
                for (final b in bookThemes) ...[
                  Semantics(
                    button: true,
                    label: b.name,
                    child: GestureDetector(
                      onTap: () => s.readerTheme = b.id,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: b.page,
                          shape: BoxShape.circle,
                          border: Border.all(color: b.id == t.id ? context.pd.accent : t.text.withValues(alpha: 0.15), width: b.id == t.id ? 2 : 1),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
              ]),
            ]),
          ),
        )),
      ),
    ];
  }
}
