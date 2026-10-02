/**
 * 幻灯片显示：按原稿比例画出背景、外形、边框、连接线箭头、图片与表格，文字按原稿字体类别换成手机上有的字体（含中文兜底），
 * 放不下时整体缩小；点开单页可双指放大、左右翻页；也可切换为文字大纲阅读。
 */
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../tokens.dart';
import '../../widgets.dart';
import 'office.dart';
import 'pptx.dart';

/* ---------- 字体 ---------- */

/**
 * 兜底字体：按顺序尝试，手机上没有的跳过，最后由系统按文字自动兜底（中文等）。
 * 无衬线文字不设字体，直接用手机默认字体与系统兜底：只设兜底列表时 Flutter 不会再沿用默认字体。
 */
const _cjkSerif = ['Noto Serif CJK SC', 'Noto Serif SC', 'Source Han Serif SC', 'Songti SC', 'STSong', 'PingFang SC', 'Noto Sans CJK SC', 'sans-serif'];
const _cjkMono = ['PingFang SC', 'Noto Sans CJK SC', 'sans-serif'];

const _serifNames = ['simsun', '宋体', 'nsimsun', '新宋体', 'songti', 'stsong', 'fangsong', '仿宋', 'kaiti', '楷体', 'stkaiti', 'times', 'georgia', 'cambria', 'garamond', 'book antiqua', 'palatino', 'constantia', 'serif', 'ming', '明体', 'baskerville', 'didot'];
const _monoNames = ['consolas', 'courier', 'menlo', 'monaco', 'lucida console', 'source code', 'jetbrains', 'fira code', 'sf mono', 'mono', 'inconsolata', 'cascadia'];

/** _hasCjk：是否含中日韩文字 */
bool _hasCjk(String s) => s.runes.any((r) => (r >= 0x3000 && r <= 0x9FFF) || (r >= 0xF900 && r <= 0xFAFF) || (r >= 0xFF00 && r <= 0xFFEF));

/**
 * pptFont：原稿字体换成手机上的字体族与兜底列表
 *
 * 含中文的文字优先看中文字体名，否则看西文字体名；按名称归为等宽、衬线或无衬线三类。
 */
({String? family, List<String> fallback}) pptFont(Run r) {
  final name = (_hasCjk(r.text) && r.eaFont.isNotEmpty ? r.eaFont : (r.font.isNotEmpty ? r.font : r.eaFont)).toLowerCase();
  if (_monoNames.any(name.contains)) return (family: PdFont.mono, fallback: [...PdFont.monoFallback, ..._cjkMono]);
  if (_serifNames.any(name.contains)) return (family: 'serif', fallback: _cjkSerif);
  return (family: null, fallback: const []);
}

/* ---------- 整份演示文稿 ---------- */

/**
 * DeckView：逐页显示幻灯片；outline 为 true 时显示文字大纲
 */
class DeckView extends StatelessWidget {
  const DeckView({super.key, required this.deck, this.outline = false});

  final Deck deck;
  final bool outline;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    if (deck.slides.isEmpty) return const EmptyHint(icon: LucideIcons.presentation300, text: '这份演示文稿没有幻灯片');
    if (outline) return _OutlineView(deck: deck);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      itemCount: deck.slides.length,
      separatorBuilder: (_, _) => const SizedBox(height: 14),
      itemBuilder: (_, i) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text('${i + 1} / ${deck.slides.length}', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
          ),
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SlideZoomPage(deck: deck, index: i))),
            child: _Card(child: SlideView(slide: deck.slides[i], deck: deck)),
          ),
        ],
      ),
    );
  }
}

/** _Card：幻灯片外框（白底、圆角、阴影） */
class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 16, offset: const Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/**
 * SlideZoomPage：单页全屏，双指放大，左右滑动翻页
 */
class SlideZoomPage extends StatefulWidget {
  const SlideZoomPage({super.key, required this.deck, required this.index});

  final Deck deck;
  final int index;

  @override
  State<SlideZoomPage> createState() => _SlideZoomPageState();
}

class _SlideZoomPageState extends State<SlideZoomPage> {
  late final PageController _page = PageController(initialPage: widget.index);
  late int _i = widget.index;
  bool _zoomed = false;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: PdBar(title: '${_i + 1} / ${widget.deck.slides.length}', dark: true),
      body: PageView.builder(
        controller: _page,
        physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
        itemCount: widget.deck.slides.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) => _ZoomSlide(
          deck: widget.deck,
          slide: widget.deck.slides[i],
          onZoom: (z) {
            if (z != _zoomed) setState(() => _zoomed = z);
          },
        ),
      ),
    );
  }
}

/** _ZoomSlide：可缩放的一页 */
class _ZoomSlide extends StatefulWidget {
  const _ZoomSlide({required this.deck, required this.slide, required this.onZoom});
  final Deck deck;
  final Slide slide;
  final ValueChanged<bool> onZoom;

  @override
  State<_ZoomSlide> createState() => _ZoomSlideState();
}

class _ZoomSlideState extends State<_ZoomSlide> {
  final _ctrl = TransformationController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InteractiveViewer(
        transformationController: _ctrl,
        maxScale: 6,
        onInteractionEnd: (_) => widget.onZoom(_ctrl.value.getMaxScaleOnAxis() > 1.01),
        child: Center(child: Padding(padding: const EdgeInsets.all(8), child: _Card(child: SlideView(slide: widget.slide, deck: widget.deck)))),
      );
}

/** _OutlineView：文字大纲，每页一组 */
class _OutlineView extends StatelessWidget {
  const _OutlineView({required this.deck});
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: deck.slides.length,
      itemBuilder: (_, i) {
        final texts = deck.slides[i].texts;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(PdSize.cardRadius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('第 ${i + 1} 页', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
            const SizedBox(height: 6),
            if (texts.isEmpty) Text('（这一页没有文字）', style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
            for (final (j, t) in texts.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: SelectableText(t, style: TextStyle(fontSize: j == 0 ? 16 : 14.5, height: 1.5, color: c.text, fontWeight: j == 0 ? FontWeight.w600 : null)),
              ),
          ]),
        );
      },
    );
  }
}

/* ---------- 一页 ---------- */

/**
 * SlideView：一页幻灯片，形状按原稿比例定位，字号与线宽按幻灯片高度换算
 */
class SlideView extends StatelessWidget {
  const SlideView({super.key, required this.slide, required this.deck});

  final Slide slide;
  final Deck deck;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: deck.aspect,
      child: LayoutBuilder(builder: (context, box) {
        final k = box.maxHeight / deck.heightPt;
        final fb = slide.fallback;
        return Stack(clipBehavior: Clip.hardEdge, children: [
          Positioned.fill(child: _FillBox(fill: slide.bg ?? const Fill(color: 0xFFFFFFFF))),
          if (fb != null)
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.all(24 * k),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: box.maxWidth - 48 * k,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      for (final t in fb) Text(t, style: TextStyle(fontSize: 18 * k, height: 1.4, color: const Color(0xFF1D1D1F))),
                    ]),
                  ),
                ),
              ),
            ),
          for (final s in slide.shapes) _ShapeView(s: s, size: box.biggest, k: k),
        ]);
      }),
    );
  }
}

/** _FillBox：纯色、渐变或图片填充 */
class _FillBox extends StatelessWidget {
  const _FillBox({required this.fill});
  final Fill fill;

  @override
  Widget build(BuildContext context) {
    if (fill.image != null) return Image.memory(fill.image!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink());
    return DecoratedBox(decoration: BoxDecoration(color: fill.gradient ? null : (fill.color == null ? null : Color(fill.color!)), gradient: _gradient(fill)));
  }
}

/** _gradient：线性渐变，角度为原稿方向 */
Gradient? _gradient(Fill f) {
  if (!f.gradient) return null;
  final a = f.angle * math.pi / 180;
  final dx = math.cos(a), dy = math.sin(a);
  return LinearGradient(begin: Alignment(-dx, -dy), end: Alignment(dx, dy), colors: [for (final c in f.colors) Color(c)], stops: f.stops.length == f.colors.length ? f.stops : null);
}

/**
 * _ShapeView：一个形状：外形与边框用画布绘制，图片按裁剪显示，文字叠在上面
 */
class _ShapeView extends StatelessWidget {
  const _ShapeView({required this.s, required this.size, required this.k});

  final Shape s;
  final Size size;
  final double k;

  @override
  Widget build(BuildContext context) {
    final w = s.w * size.width, h = s.h * size.height;
    Widget child;
    if (s.connector) {
      child = CustomPaint(painter: _LinePainter(s, k));
    } else if (s.table != null) {
      child = _TableView(table: s.table!, k: k);
    } else if (s.image != null || s.imageKind == 'chart' || s.imageKind == 'object') {
      child = _imageView(context, w, h);
    } else {
      child = Stack(fit: StackFit.expand, children: [
        CustomPaint(painter: _GeomPainter(s, k)),
        if (s.bg?.image != null) ClipPath(clipper: _GeomClipper(s), child: Image.memory(s.bg!.image!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink())),
        if (s.paras.any((p) => p.text.trim().isNotEmpty)) _TextBox(s: s, k: k, width: w, height: h),
      ]);
    }
    if (s.flipH || s.flipV) {
      child = Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(s.flipH && !s.connector ? -1 : 1, s.flipV && !s.connector ? -1 : 1, 1), child: child);
    }
    if (s.rot != 0) child = Transform.rotate(angle: s.rot * math.pi / 180, child: child);
    // 连接线可能宽或高为 0，留出线宽
    final pad = s.connector ? math.max(2.0, s.lineW * k * 4) : 0.0;
    return Positioned(left: s.x * size.width - pad, top: s.y * size.height - pad, width: w + pad * 2, height: h + pad * 2, child: Padding(padding: EdgeInsets.all(pad), child: child));
  }

  /** _imageView：图片（裁剪、矢量图）；手机无法显示的格式与图表显示为浅色占位框 */
  Widget _imageView(BuildContext context, double w, double h) {
    final data = s.image;
    if (data == null || s.imageKind == 'unsupported' || s.imageKind == 'chart' || s.imageKind == 'object') {
      return Container(
        decoration: BoxDecoration(color: const Color(0xFFF2F4F7), border: Border.all(color: const Color(0xFFD0D5DD), width: 0.5)),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(s.imageKind == 'chart' ? LucideIcons.chartColumn300 : LucideIcons.image300, color: const Color(0xFF98A2B3), size: math.max(12, math.min(w, h) * 0.3)),
          ),
        ),
      );
    }
    Widget img = s.imageKind == 'svg'
        ? SvgPicture.memory(data, fit: BoxFit.fill)
        : Image.memory(data, fit: BoxFit.fill, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink());
    final cr = s.crop;
    if (cr != null && !cr.isNone) {
      final vw = 1 - cr.l - cr.r, vh = 1 - cr.t - cr.b;
      if (vw > 0 && vh > 0) {
        img = ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: w / vw,
            maxWidth: w / vw,
            minHeight: h / vh,
            maxHeight: h / vh,
            child: Transform.translate(offset: Offset(-cr.l * w / vw, -cr.t * h / vh), child: img),
          ),
        );
      }
    }
    if (s.geom == 'ellipse' || s.geom == 'roundRect') img = ClipPath(clipper: _GeomClipper(s), child: img);
    if (s.line != null && s.lineW > 0) {
      img = Container(foregroundDecoration: BoxDecoration(border: Border.all(color: Color(s.line!), width: s.lineW * k)), child: img);
    }
    return img;
  }
}

/* ---------- 外形 ---------- */

/** _geomPath：预设外形或自定义外形的路径 */
Path _geomPath(Shape s, Size sz) {
  final w = sz.width, h = sz.height, m = math.min(w, h);
  double adj(int i, double d) => i < s.adj.length ? s.adj[i] : d;
  final p = Path();
  switch (s.geom) {
    case 'cust':
      for (final c in s.path) {
        final pts = [for (var i = 0; i + 1 < c.pts.length; i += 2) Offset(c.pts[i] * w, c.pts[i + 1] * h)];
        switch (c.op) {
          case 'M':
            if (pts.isNotEmpty) p.moveTo(pts[0].dx, pts[0].dy);
          case 'L':
            if (pts.isNotEmpty) p.lineTo(pts[0].dx, pts[0].dy);
          case 'C':
            if (pts.length >= 3) p.cubicTo(pts[0].dx, pts[0].dy, pts[1].dx, pts[1].dy, pts[2].dx, pts[2].dy);
          case 'Q':
            if (pts.length >= 2) p.quadraticBezierTo(pts[0].dx, pts[0].dy, pts[1].dx, pts[1].dy);
          case 'Z':
            p.close();
        }
      }
      if (s.path.isEmpty) p.addRect(Offset.zero & sz);
    case 'roundRect':
      final r = (adj(0, 0.16667) * m).clamp(0.0, m / 2);
      p.addRRect(RRect.fromRectAndRadius(Offset.zero & sz, Radius.circular(r)));
    case 'ellipse' || 'flowChartConnector':
      p.addOval(Offset.zero & sz);
    case 'triangle':
      final top = adj(0, 0.5) * w;
      p.addPolygon([Offset(top, 0), Offset(w, h), Offset(0, h)], true);
    case 'rtTriangle':
      p.addPolygon([Offset.zero, Offset(w, h), Offset(0, h)], true);
    case 'diamond' || 'flowChartDecision':
      p.addPolygon([Offset(w / 2, 0), Offset(w, h / 2), Offset(w / 2, h), Offset(0, h / 2)], true);
    case 'parallelogram' || 'flowChartInputOutput':
      final o = adj(0, 0.25) * m;
      p.addPolygon([Offset(o, 0), Offset(w, 0), Offset(w - o, h), Offset(0, h)], true);
    case 'trapezoid':
      final o = adj(0, 0.25) * m;
      p.addPolygon([Offset(o, 0), Offset(w - o, 0), Offset(w, h), Offset(0, h)], true);
    case 'hexagon':
      final o = adj(0, 0.25) * m;
      p.addPolygon([Offset(o, 0), Offset(w - o, 0), Offset(w, h / 2), Offset(w - o, h), Offset(o, h), Offset(0, h / 2)], true);
    case 'octagon':
      final o = adj(0, 0.29289) * m;
      p.addPolygon([Offset(o, 0), Offset(w - o, 0), Offset(w, o), Offset(w, h - o), Offset(w - o, h), Offset(o, h), Offset(0, h - o), Offset(0, o)], true);
    case 'homePlate':
      final o = adj(0, 0.5) * m;
      p.addPolygon([Offset.zero, Offset(w - o, 0), Offset(w, h / 2), Offset(w - o, h), Offset(0, h)], true);
    case 'chevron':
      final o = adj(0, 0.5) * m;
      p.addPolygon([Offset.zero, Offset(w - o, 0), Offset(w, h / 2), Offset(w - o, h), Offset(0, h), Offset(o, h / 2)], true);
    case 'rightArrow' || 'leftArrow':
      final t = adj(0, 0.5) * h, hd = adj(1, 0.5) * m;
      final y0 = (h - t) / 2, y1 = (h + t) / 2;
      final pts = [Offset(0, y0), Offset(w - hd, y0), Offset(w - hd, 0), Offset(w, h / 2), Offset(w - hd, h), Offset(w - hd, y1), Offset(0, y1)];
      p.addPolygon(s.geom == 'leftArrow' ? [for (final q in pts) Offset(w - q.dx, q.dy)] : pts, true);
    case 'upArrow' || 'downArrow':
      final t = adj(0, 0.5) * w, hd = adj(1, 0.5) * m;
      final x0 = (w - t) / 2, x1 = (w + t) / 2;
      final pts = [Offset(x0, h), Offset(x0, hd), Offset(0, hd), Offset(w / 2, 0), Offset(w, hd), Offset(x1, hd), Offset(x1, h)];
      p.addPolygon(s.geom == 'downArrow' ? [for (final q in pts) Offset(q.dx, h - q.dy)] : pts, true);
    case 'plus' || 'mathPlus':
      final o = adj(0, 0.25) * m;
      p.addPolygon([Offset(o, 0), Offset(w - o, 0), Offset(w - o, o), Offset(w, o), Offset(w, h - o), Offset(w - o, h - o), Offset(w - o, h), Offset(o, h), Offset(o, h - o), Offset(0, h - o), Offset(0, o), Offset(o, o)], true);
    case 'snip1Rect' || 'snipRoundRect' || 'round1Rect' || 'round2SameRect':
      final r = (adj(0, 0.16667) * m).clamp(0.0, m / 2);
      p.addRRect(RRect.fromRectAndCorners(Offset.zero & sz, topLeft: s.geom == 'round2SameRect' ? Radius.circular(r) : Radius.zero, topRight: Radius.circular(r)));
    default:
      p.addRect(Offset.zero & sz);
  }
  return p;
}

/** _GeomClipper：按外形裁剪 */
class _GeomClipper extends CustomClipper<Path> {
  _GeomClipper(this.s);
  final Shape s;

  @override
  Path getClip(Size size) => _geomPath(s, size);

  @override
  bool shouldReclip(_GeomClipper old) => old.s != s;
}

/** _dashed：按虚线样式切分路径 */
Path _dashed(Path src, String dash, double w) {
  final pattern = switch (dash) {
    'dot' || 'sysDot' => [w, w * 2],
    'dash' || 'sysDash' => [w * 4, w * 3],
    'lgDash' => [w * 8, w * 3],
    'dashDot' || 'sysDashDot' => [w * 4, w * 3, w, w * 3],
    _ => <double>[],
  };
  if (pattern.isEmpty) return src;
  final out = Path();
  for (final m in src.computeMetrics()) {
    var d = 0.0, i = 0;
    while (d < m.length) {
      final len = pattern[i % pattern.length];
      if (i.isEven) out.addPath(m.extractPath(d, math.min(d + len, m.length)), Offset.zero);
      d += len;
      i++;
    }
  }
  return out;
}

/** _GeomPainter：填充与边框 */
class _GeomPainter extends CustomPainter {
  _GeomPainter(this.s, this.k);
  final Shape s;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _geomPath(s, size);
    final f = s.bg;
    if (f != null && f.visible && f.image == null) {
      final paint = Paint()..style = PaintingStyle.fill;
      final g = _gradient(f);
      if (g != null) {
        paint.shader = g.createShader(Offset.zero & size);
      } else {
        paint.color = Color(f.color!);
      }
      canvas.drawPath(path, paint);
    }
    if (s.line != null && s.lineW > 0) {
      final sw = math.max(0.5, s.lineW * k);
      canvas.drawPath(
        _dashed(path, s.dash, sw),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sw
          ..color = Color(s.line!),
      );
    }
  }

  @override
  bool shouldRepaint(_GeomPainter old) => old.s != s || old.k != k;
}

/**
 * _LinePainter：连接线（直线、折线、曲线）与两端箭头
 */
class _LinePainter extends CustomPainter {
  _LinePainter(this.s, this.k);
  final Shape s;
  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    final color = Color(s.line ?? 0xFF000000);
    final sw = math.max(0.75, (s.lineW == 0 ? 0.75 : s.lineW) * k);
    final a = Offset(s.flipH ? size.width : 0, s.flipV ? size.height : 0);
    final b = Offset(s.flipH ? 0 : size.width, s.flipV ? 0 : size.height);
    final path = Path()..moveTo(a.dx, a.dy);
    Offset startDir, endDir;
    if (s.geom.startsWith('bentConnector')) {
      final mx = (a.dx + b.dx) / 2;
      path
        ..lineTo(mx, a.dy)
        ..lineTo(mx, b.dy)
        ..lineTo(b.dx, b.dy);
      startDir = Offset(mx - a.dx, 0);
      endDir = Offset(b.dx - mx, 0);
      if (startDir.distance < 0.01) startDir = b - a;
      if (endDir.distance < 0.01) endDir = b - a;
    } else if (s.geom.startsWith('curvedConnector')) {
      final mx = (a.dx + b.dx) / 2;
      path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
      startDir = Offset(mx - a.dx, 0);
      endDir = Offset(b.dx - mx, 0);
      if (startDir.distance < 0.01) startDir = b - a;
      if (endDir.distance < 0.01) endDir = b - a;
    } else {
      path.lineTo(b.dx, b.dy);
      startDir = endDir = b - a;
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawPath(_dashed(path, s.dash, sw), stroke);
    final fill = Paint()..color = color;
    if (s.tail.isNotEmpty && s.tail != 'none') _arrow(canvas, b, endDir, s.tail, sw, fill);
    if (s.head.isNotEmpty && s.head != 'none') _arrow(canvas, a, -startDir, s.head, sw, fill);
  }

  /** _arrow：在端点画箭头，dir 为指向端点的方向 */
  void _arrow(Canvas canvas, Offset tip, Offset dir, String type, double sw, Paint paint) {
    if (dir.distance == 0) return;
    final u = dir / dir.distance;
    final n = Offset(-u.dy, u.dx);
    final len = math.max(6.0, sw * 3.5), half = len * 0.5;
    final base = tip - u * len;
    switch (type) {
      case 'oval':
        canvas.drawCircle(tip, half, paint);
      case 'diamond':
        canvas.drawPath(Path()..addPolygon([tip, base + n * half + u * (len / 2), tip - u * len, base - n * half + u * (len / 2)], true), paint);
      case 'arrow':
        canvas.drawPath(
          Path()
            ..moveTo((base + n * half).dx, (base + n * half).dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo((base - n * half).dx, (base - n * half).dy),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = sw
            ..color = paint.color,
        );
      default:
        canvas.drawPath(Path()..addPolygon([tip, base + n * half, base - n * half], true), paint);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) => old.s != s || old.k != k;
}

/* ---------- 文字 ---------- */

/** _style：一段文字的样式，字号缺省时用标题 32、正文 18 */
TextStyle _style(Run r, Para p, Shape? s, double k, double scale) {
  final f = pptFont(r);
  final size = (r.size ?? p.size ?? (s?.title == true ? 32 : 18)) * scale;
  return TextStyle(
    fontSize: size * k * (r.baseline != 0 ? 0.66 : 1),
    height: 1.2 * (p.lineSpacing ?? 1),
    color: Color(r.color ?? 0xFF1D1D1F),
    fontWeight: r.bold ? FontWeight.w700 : null,
    fontStyle: r.italic ? FontStyle.italic : null,
    letterSpacing: r.spacing == 0 ? null : r.spacing * k,
    decoration: TextDecoration.combine([if (r.underline) TextDecoration.underline, if (r.strike) TextDecoration.lineThrough]),
    fontFamily: f.family,
    fontFamilyFallback: f.fallback.isEmpty ? null : f.fallback,
  );
}

/** _paraWidget：一个段落（项目符号、缩进、段前段后、对齐） */
Widget _paraWidget(Para p, Shape? s, double k, double scale, bool wrap) {
  final first = p.runs.firstWhere((r) => r.text.trim().isNotEmpty, orElse: () => p.runs.isEmpty ? const Run('') : p.runs.first);
  final base = _style(first, p, s, k, scale);
  final fs = base.fontSize ?? 18 * k;
  double space(double v) => v < 0 ? -v * fs * 1.2 : v * k;
  final align = switch (p.align) { 'center' => TextAlign.center, 'right' => TextAlign.right, 'both' => TextAlign.justify, _ => TextAlign.left };
  final text = Text.rich(
    TextSpan(children: [
      for (final r in p.runs) TextSpan(text: r.text, style: _style(r, p, s, k, scale)),
      // 空段落保留一行高度
      if (p.runs.every((r) => r.text.isEmpty)) TextSpan(text: ' ', style: base),
    ]),
    textAlign: align,
    softWrap: wrap,
  );
  final left = math.max(0.0, p.marL * k);
  Widget body = text;
  if (p.bullet.isNotEmpty) {
    final hang = p.indent < 0 ? -p.indent * k : fs * 0.9;
    body = Row(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: wrap ? MainAxisSize.max : MainAxisSize.min, children: [
      SizedBox(
        width: math.max(hang, fs * 0.9),
        child: Text(p.bullet, style: base.copyWith(color: p.bulletColor == null ? null : Color(p.bulletColor!), fontWeight: FontWeight.w400, decoration: TextDecoration.none)),
      ),
      if (wrap) Flexible(child: text) else text,
    ]);
  }
  return Padding(
    padding: EdgeInsets.only(left: p.bullet.isNotEmpty ? math.max(0.0, left - (p.indent < 0 ? -p.indent * k : 0)) : left, top: space(p.spcBef), bottom: space(p.spcAft)),
    child: body,
  );
}

/**
 * _TextBox：文字区：按内边距留白，按垂直对齐放置，放不下时整体缩小
 */
class _TextBox extends StatelessWidget {
  const _TextBox({required this.s, required this.k, required this.width, required this.height});

  final Shape s;
  final double k;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final innerW = math.max(1.0, width - (s.insL + s.insR) * k);
    final align = switch (s.anchor) { 'ctr' => Alignment.center, 'b' => Alignment.bottomCenter, _ => Alignment.topCenter };
    final paras = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [for (final p in s.paras) _paraWidget(p, s, k, s.fontScale, s.wrap)],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(s.insL * k, s.insT * k, s.insR * k, s.insB * k),
      child: Align(
        alignment: align,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: align,
          child: s.wrap ? SizedBox(width: innerW, child: paras) : IntrinsicWidth(child: ConstrainedBox(constraints: BoxConstraints(minWidth: innerW), child: paras)),
        ),
      ),
    );
  }
}

/* ---------- 表格 ---------- */

/** _TableView：按列宽行高排布单元格，支持合并单元格 */
class _TableView extends StatelessWidget {
  const _TableView({required this.table, required this.k});
  final SlideTable table;
  final double k;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final xs = <double>[0];
        for (final c in table.cols) {
          xs.add(xs.last + c * box.maxWidth);
        }
        final ys = <double>[0];
        for (final r in table.rows) {
          ys.add(ys.last + r * box.maxHeight);
        }
        const border = Color(0xFFD0D5DD);
        final cells = <Widget>[];
        for (var r = 0; r < table.cells.length && r < table.rows.length; r++) {
          for (var c = 0; c < table.cells[r].length && c < table.cols.length; c++) {
            final cell = table.cells[r][c];
            if (cell.hidden) continue;
            final c2 = math.min(table.cols.length, c + cell.colSpan), r2 = math.min(table.rows.length, r + cell.rowSpan);
            cells.add(Positioned(
              left: xs[c],
              top: ys[r],
              width: xs[c2] - xs[c],
              height: ys[r2] - ys[r],
              child: Container(
                decoration: BoxDecoration(color: cell.fill == null ? null : Color(cell.fill!), border: Border.all(color: border, width: 0.5)),
                padding: EdgeInsets.symmetric(horizontal: 7.2 * k, vertical: 3.6 * k),
                alignment: switch (cell.anchor) { 'ctr' => Alignment.centerLeft, 'b' => Alignment.bottomLeft, _ => Alignment.topLeft },
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: math.max(1.0, xs[c2] - xs[c] - 14.4 * k),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [for (final p in cell.paras) _paraWidget(p, null, k, 1, true)]),
                  ),
                ),
              ),
            ));
          }
        }
        return Stack(children: cells);
      });
}
