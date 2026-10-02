/**
 * PPT 解析：幻灯片尺寸与页序；每页的背景、形状（几何外形、填充、边框、连接线箭头、旋转、组合）、
 * 文字（主题颜色与字体、版式与母版继承的位置和样式、项目符号、间距、对齐）、图片（裁剪）与表格。
 * 某一页解析出错时退回为只显示这一页的文字，整份文件不至于打不开。
 */
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'office.dart';

/* ---------- 模型 ---------- */

/** Fill：填充（纯色、渐变或图片），none 表示明确不填充 */
class Fill {
  const Fill({this.color, this.colors = const [], this.stops = const [], this.angle = 0, this.image, this.none = false});

  final int? color;
  final List<int> colors;
  final List<double> stops;

  /** 渐变方向（度，0 为从左到右） */
  final double angle;
  final Uint8List? image;
  final bool none;

  bool get gradient => colors.length >= 2;
  bool get visible => !none && (color != null || gradient || image != null);
}

/** Crop：图片裁剪，四边各裁掉的比例 */
class Crop {
  const Crop(this.l, this.t, this.r, this.b);
  final double l, t, r, b;
  bool get isNone => l == 0 && t == 0 && r == 0 && b == 0;
}

/** PathCmd：自定义外形的一段路径，坐标为占形状宽高的比例 */
class PathCmd {
  const PathCmd(this.op, this.pts);

  /** M 移动、L 直线、C 三次曲线、Q 二次曲线、Z 闭合 */
  final String op;
  final List<double> pts;
}

/** TableCell：表格单元格 */
class TableCell {
  const TableCell({required this.paras, this.fill, this.colSpan = 1, this.rowSpan = 1, this.hidden = false, this.anchor = 't'});
  final List<Para> paras;
  final int? fill;
  final int colSpan;
  final int rowSpan;

  /** 被合并进其他单元格 */
  final bool hidden;
  final String anchor;
}

/** SlideTable：表格，列宽与行高为占表格宽高的比例 */
class SlideTable {
  const SlideTable(this.cols, this.rows, this.cells);
  final List<double> cols;
  final List<double> rows;
  final List<List<TableCell>> cells;
}

/** Shape：幻灯片上的一个形状，位置与大小为占幻灯片的比例（0–1） */
class Shape {
  const Shape({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.paras = const [],
    this.image,
    this.title = false,
    this.fill,
    this.bg,
    this.geom = 'rect',
    this.adj = const [],
    this.path = const [],
    this.line,
    this.lineW = 0,
    this.dash = '',
    this.head = '',
    this.tail = '',
    this.connector = false,
    this.rot = 0,
    this.flipH = false,
    this.flipV = false,
    this.anchor = 't',
    this.insL = 7.2,
    this.insT = 3.6,
    this.insR = 7.2,
    this.insB = 3.6,
    this.wrap = true,
    this.fontScale = 1,
    this.crop,
    this.imageKind = '',
    this.table,
  });

  final double x;
  final double y;
  final double w;
  final double h;
  final List<Para> paras;
  final Uint8List? image;
  final bool title;

  /** fill：纯色填充（兼容旧字段），bg 为完整填充（渐变、图片） */
  final int? fill;
  final Fill? bg;

  /** geom：预设外形名（rect、roundRect、ellipse 等），adj 为外形参数（0–1） */
  final String geom;
  final List<double> adj;

  /** path：自定义外形 */
  final List<PathCmd> path;

  /** 边框颜色、粗细（磅）、虚线样式与两端箭头 */
  final int? line;
  final double lineW;
  final String dash;
  final String head;
  final String tail;
  final bool connector;

  /** 旋转（度）与翻转 */
  final double rot;
  final bool flipH;
  final bool flipV;

  /** 文字垂直对齐 t / ctr / b，文字区内边距（磅），是否自动换行，自动缩小比例 */
  final String anchor;
  final double insL, insT, insR, insB;
  final bool wrap;
  final double fontScale;

  /** 图片裁剪与格式（png、jpeg、svg 等，unsupported 表示手机无法显示） */
  final Crop? crop;
  final String imageKind;
  final SlideTable? table;
}

/** Slide：一页幻灯片；fallback 不为空时表示这页没能完整解析，只显示文字 */
class Slide {
  const Slide(this.shapes, {this.bg, this.fallback});
  final List<Shape> shapes;
  final Fill? bg;
  final List<String>? fallback;

  /** texts：这一页的全部文字（大纲模式与兜底显示用） */
  List<String> get texts {
    if (fallback != null) return fallback!;
    final out = <String>[];
    void paras(List<Para> ps) {
      for (final p in ps) {
        final t = p.text.trim();
        if (t.isNotEmpty) out.add('${'  ' * p.level}${p.bullet.isNotEmpty ? '${p.bullet} ' : ''}$t');
      }
    }

    for (final s in shapes) {
      paras(s.paras);
      final tb = s.table;
      if (tb != null) {
        for (final row in tb.cells) {
          final cells = [for (final c in row) if (!c.hidden) c.paras.map((p) => p.text).join(' ').trim()];
          if (cells.any((c) => c.isNotEmpty)) out.add(cells.join(' | '));
        }
      }
    }
    return out;
  }
}

/** Deck：整个演示文稿，aspect 为宽高比 */
class Deck {
  const Deck(this.slides, this.aspect, this.heightPt);
  final List<Slide> slides;
  final double aspect;

  /** 幻灯片高度（磅），用于换算字号 */
  final double heightPt;
}

/* ---------- 包与 XML 工具 ---------- */

/** _Pkg：zip 包，按路径取文件与关系 */
class _Pkg {
  _Pkg(Uint8List bytes) : _a = ZipDecoder().decodeBytes(bytes);

  final Archive _a;
  final _cache = <String, XmlDocument?>{};

  Uint8List? bytes(String path) => _a.findFile(path)?.content;

  XmlDocument? xml(String path) => _cache.putIfAbsent(path, () {
        final b = bytes(path);
        return b == null ? null : XmlDocument.parse(utf8.decode(b, allowMalformed: true));
      });

  /** rels：部件的关系表 id → 目标路径；type 不为空时只取该类型 */
  Map<String, String> rels(String part, {String type = ''}) {
    final i = part.lastIndexOf('/');
    final dir = i < 0 ? '' : part.substring(0, i);
    final name = i < 0 ? part : part.substring(i + 1);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/$name.rels');
    if (doc == null) return {};
    return {
      for (final r in doc.findAllElements('Relationship'))
        if (type.isEmpty || (r.getAttribute('Type') ?? '').endsWith('/$type')) r.getAttribute('Id') ?? '': _resolve(dir, r.getAttribute('Target') ?? ''),
    };
  }

  static String _resolve(String dir, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final parts = [if (dir.isNotEmpty) ...dir.split('/'), ...target.split('/')];
    final out = <String>[];
    for (final p in parts) {
      if (p == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else if (p != '.' && p.isNotEmpty) {
        out.add(p);
      }
    }
    return out.join('/');
  }
}

String? _attr(XmlElement? e, String local) {
  if (e == null) return null;
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

String _rid(XmlElement e, [String local = 'embed']) {
  for (final a in e.attributes) {
    if (a.name.local == local && (a.name.prefix == 'r' || (a.name.namespaceUri ?? '').contains('relationships'))) return a.value;
  }
  return '';
}

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

Iterable<XmlElement> _kids(XmlElement? e, String local) => e == null ? const [] : e.childElements.where((c) => c.name.local == local);

Iterable<XmlElement> _all(XmlNode? e, String local) => e == null ? const [] : e.descendants.whereType<XmlElement>().where((x) => x.name.local == local);

double _num(XmlElement? e, String k, [double d = 0]) => double.tryParse(_attr(e, k) ?? '') ?? d;

/** EMU 转磅 */
const _emuPerPt = 12700.0;

/* ---------- 主题与颜色 ---------- */

/** _Theme：主题颜色与字体 */
class _Theme {
  final colors = <String, int>{};
  String majorLatin = '', minorLatin = '', majorEa = '', minorEa = '';
}

_Theme _theme(XmlDocument? doc) {
  final t = _Theme();
  if (doc == null) return t;
  final scheme = _all(doc, 'clrScheme').firstOrNull;
  for (final c in scheme?.childElements ?? const <XmlElement>[]) {
    final v = c.childElements.firstOrNull;
    if (v == null) continue;
    final hex = v.name.local == 'sysClr' ? _attr(v, 'lastClr') : _attr(v, 'val');
    final rgb = int.tryParse(hex ?? '', radix: 16);
    if (rgb != null) t.colors[c.name.local] = 0xFF000000 | rgb;
  }
  String face(String which, String script) => _attr(_child(_all(doc, which).firstOrNull, script), 'typeface') ?? '';
  t.majorLatin = face('majorFont', 'latin');
  t.minorLatin = face('minorFont', 'latin');
  t.majorEa = face('majorFont', 'ea');
  t.minorEa = face('minorFont', 'ea');
  return t;
}

/** _Ctx：解析一页时的主题、颜色映射与包 */
class _Ctx {
  _Ctx(this.pkg, this.theme, this.clrMap);
  final _Pkg pkg;
  final _Theme theme;
  final Map<String, String> clrMap;

  /** 形状样式里的占位颜色（phClr） */
  int? ph;
}

const _prstColors = {'black': 0x000000, 'white': 0xFFFFFF, 'red': 0xFF0000, 'green': 0x008000, 'blue': 0x0000FF, 'yellow': 0xFFFF00, 'gray': 0x808080, 'grey': 0x808080, 'orange': 0xFFA500};

/**
 * _colorIn：取某元素下的颜色（srgbClr、schemeClr、sysClr、prstClr），并套用亮度、明暗与透明度调整
 */
int? _colorIn(XmlElement? holder, _Ctx c) {
  if (holder == null) return null;
  for (final e in holder.childElements) {
    int? base;
    switch (e.name.local) {
      case 'srgbClr':
        final v = int.tryParse(_attr(e, 'val') ?? '', radix: 16);
        if (v != null) base = 0xFF000000 | v;
      case 'sysClr':
        final v = int.tryParse(_attr(e, 'lastClr') ?? '', radix: 16);
        if (v != null) base = 0xFF000000 | v;
      case 'schemeClr':
        final name = _attr(e, 'val') ?? '';
        if (name == 'phClr') {
          base = c.ph;
        } else {
          base = c.theme.colors[c.clrMap[name] ?? name] ?? c.theme.colors[{'bg1': 'lt1', 'tx1': 'dk1', 'bg2': 'lt2', 'tx2': 'dk2'}[name] ?? name];
        }
      case 'prstClr':
        final v = _prstColors[_attr(e, 'val') ?? ''];
        if (v != null) base = 0xFF000000 | v;
      case 'scrgbClr':
        int ch(String k) => (_num(e, k) / 100000 * 255).round().clamp(0, 255);
        base = 0xFF000000 | (ch('r') << 16) | (ch('g') << 8) | ch('b');
      default:
        continue;
    }
    if (base == null) return null;
    return _mods(base, e);
  }
  return null;
}

/** _mods：颜色调整（lumMod/lumOff 按 HSL 亮度，tint 偏白，shade 偏黑，alpha 透明度） */
int _mods(int argb, XmlElement e) {
  var r = (argb >> 16 & 0xFF) / 255, g = (argb >> 8 & 0xFF) / 255, b = (argb & 0xFF) / 255;
  var a = 1.0;
  for (final m in e.childElements) {
    final v = _num(m, 'val') / 100000;
    switch (m.name.local) {
      case 'lumMod' || 'lumOff':
        final hsl = _toHsl(r, g, b);
        final l = m.name.local == 'lumMod' ? hsl[2] * v : hsl[2] + v;
        final rgb = _fromHsl(hsl[0], hsl[1], l.clamp(0.0, 1.0));
        r = rgb[0];
        g = rgb[1];
        b = rgb[2];
      case 'tint':
        r = 1 - (1 - r) * v;
        g = 1 - (1 - g) * v;
        b = 1 - (1 - b) * v;
      case 'shade':
        r *= v;
        g *= v;
        b *= v;
      case 'alpha':
        a = v;
    }
  }
  int ch(double x) => (x.clamp(0.0, 1.0) * 255).round();
  return (ch(a) << 24) | (ch(r) << 16) | (ch(g) << 8) | ch(b);
}

List<double> _toHsl(double r, double g, double b) {
  final mx = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final l = (mx + mn) / 2;
  if (mx == mn) return [0, 0, l];
  final d = mx - mn;
  final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
  double h;
  if (mx == r) {
    h = (g - b) / d + (g < b ? 6 : 0);
  } else if (mx == g) {
    h = (b - r) / d + 2;
  } else {
    h = (r - g) / d + 4;
  }
  return [h / 6, s, l];
}

List<double> _fromHsl(double h, double s, double l) {
  if (s == 0) return [l, l, l];
  double hue(double p, double q, double t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  }

  final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final p = 2 * l - q;
  return [hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3)];
}

/**
 * _fill：填充（solidFill、gradFill、blipFill、pattFill、noFill），没有填充设置时返回 null
 */
Fill? _fill(XmlElement? holder, _Ctx c, Map<String, String> rels) {
  if (holder == null) return null;
  for (final e in holder.childElements) {
    switch (e.name.local) {
      case 'noFill':
        return const Fill(none: true);
      case 'solidFill':
        return Fill(color: _colorIn(e, c));
      case 'gradFill':
        final stops = _all(e, 'gs').toList()..sort((a, b) => _num(a, 'pos').compareTo(_num(b, 'pos')));
        final colors = <int>[];
        final pos = <double>[];
        for (final s in stops) {
          final col = _colorIn(s, c);
          if (col != null) {
            colors.add(col);
            pos.add(_num(s, 'pos') / 100000);
          }
        }
        final ang = _num(_child(e, 'lin'), 'ang') / 60000;
        if (colors.length == 1) return Fill(color: colors.first);
        return colors.isEmpty ? null : Fill(colors: colors, stops: pos, angle: ang, color: colors.first);
      case 'blipFill':
        final blip = _child(e, 'blip');
        final img = blip == null ? null : c.pkg.bytes(rels[_rid(blip)] ?? '');
        return img == null ? null : Fill(image: img);
      case 'pattFill':
        return Fill(color: _colorIn(_child(e, 'fgClr'), c));
    }
  }
  return null;
}

/* ---------- 字体 ---------- */

/** _face：主题字体占位（+mj-lt 等）换成主题里的字体名 */
String _face(String? f, _Ctx c) => switch (f) {
      '+mj-lt' => c.theme.majorLatin,
      '+mn-lt' => c.theme.minorLatin,
      '+mj-ea' => c.theme.majorEa,
      '+mn-ea' => c.theme.minorEa,
      null => '',
      _ => f,
    };

/* ---------- 继承链 ---------- */

/**
 * _Sources：一个文字框的样式来源，从近到远：形状、版式占位符、母版占位符（near），母版文字样式、演示文稿默认（far）。
 * 形状样式的文字颜色（p:style/fontRef）排在 near 与 far 之间。
 */
class _Sources {
  _Sources(this.near, this.far, {this.fontColor, this.fontRefFace = ''});

  /** 各层的 lstStyle 类元素（含 lvl1pPr … lvl9pPr） */
  final List<XmlElement> near;
  final List<XmlElement> far;
  final int? fontColor;
  final String fontRefFace;

  /** levels：某一级的段落属性元素，从近到远 */
  List<XmlElement> levels(int lvl, {bool nearOnly = false}) => [for (final l in [...near, if (!nearOnly) ...far]) ?_child(l, 'lvl${lvl + 1}pPr')];
}

/* ---------- 解析 ---------- */

/**
 * parsePptx：解析演示文稿
 *
 * 处理流程：
 * 1、幻灯片尺寸、页序与默认文字样式
 * 2、逐页找到版式、母版与主题，解析背景与形状；某页出错时只保留这页的文字
 */
Deck parsePptx(Uint8List bytes) {
  final pkg = _Pkg(bytes);
  final pres = pkg.xml('ppt/presentation.xml');
  if (pres == null) throw const FormatException('不是有效的 PPT 文件');
  // 1、尺寸、页序、默认样式
  final sz = _all(pres, 'sldSz').firstOrNull;
  final cx = _num(sz, 'cx', 12192000), cy = _num(sz, 'cy', 6858000);
  final defaults = _all(pres, 'defaultTextStyle').firstOrNull;
  final rels = pkg.rels('ppt/presentation.xml');
  final slides = <Slide>[];
  // 2、逐页
  for (final id in _all(pres, 'sldId')) {
    final path = rels[_rid(id, 'id')];
    if (path == null) continue;
    final doc = pkg.xml(path);
    if (doc == null) continue;
    try {
      slides.add(_SlideParser(pkg, path, doc, cx, cy, defaults).parse());
    } catch (_) {
      slides.add(Slide(const [], fallback: [for (final t in _all(doc, 't')) if (t.innerText.trim().isNotEmpty) t.innerText.trim()]));
    }
  }
  return Deck(slides, cx / cy, cy / _emuPerPt);
}

/** _Xf：组合形状的坐标变换（子坐标 → 幻灯片 EMU） */
class _Xf {
  const _Xf(this.sx, this.sy, this.ox, this.oy);
  static const identity = _Xf(1, 1, 0, 0);
  final double sx, sy, ox, oy;
  double x(double v) => ox + v * sx;
  double y(double v) => oy + v * sy;
}

/** _Ph：占位符的类型与编号 */
typedef _Ph = ({String type, String idx});

/**
 * _SlideParser：解析一页
 */
class _SlideParser {
  _SlideParser(this.pkg, this.path, this.doc, this.cx, this.cy, this.defaults);

  final _Pkg pkg;
  final String path;
  final XmlDocument doc;
  final double cx, cy;
  final XmlElement? defaults;

  late final _Ctx ctx;
  late final XmlDocument? layout;
  late final XmlDocument? master;
  late final String layoutPath, masterPath;

  /**
   * parse：背景（本页 → 版式 → 母版）、母版与版式上的装饰形状、本页形状
   */
  Slide parse() {
    layoutPath = pkg.rels(path, type: 'slideLayout').values.firstOrNull ?? '';
    layout = layoutPath.isEmpty ? null : pkg.xml(layoutPath);
    masterPath = layoutPath.isEmpty ? '' : pkg.rels(layoutPath, type: 'slideMaster').values.firstOrNull ?? '';
    master = masterPath.isEmpty ? null : pkg.xml(masterPath);
    final themePath = masterPath.isEmpty ? '' : pkg.rels(masterPath, type: 'theme').values.firstOrNull ?? '';
    final clr = _all(master, 'clrMap').firstOrNull;
    ctx = _Ctx(pkg, _theme(themePath.isEmpty ? null : pkg.xml(themePath)), {for (final a in clr?.attributes ?? const <XmlAttribute>[]) a.name.local: a.value});
    // 背景
    Fill? bg;
    for (final (d, p) in [(doc, path), (layout, layoutPath), (master, masterPath)]) {
      bg = _background(d, p);
      if (bg != null) break;
    }
    // 形状
    final shapes = <Shape>[];
    final sld = doc.rootElement;
    final lay = layout?.rootElement;
    if (_attr(sld, 'showMasterSp') != '0') {
      if (_attr(lay, 'showMasterSp') != '0') shapes.addAll(_tree(master, masterPath, decor: true));
      shapes.addAll(_tree(layout, layoutPath, decor: true));
    }
    shapes.addAll(_tree(doc, path));
    return Slide(shapes, bg: bg);
  }

  /** _background：p:bg 的填充或背景样式引用 */
  Fill? _background(XmlDocument? d, String part) {
    final bg = _all(d, 'bg').firstOrNull;
    if (bg == null) return null;
    final pr = _child(bg, 'bgPr');
    if (pr != null) return _fill(pr, ctx, pkg.rels(part));
    final ref = _child(bg, 'bgRef');
    final col = _colorIn(ref, ctx);
    return col == null ? null : Fill(color: col);
  }

  /** _tree：一个部件的形状树；decor 为 true 时（版式、母版）跳过占位符，只取装饰形状 */
  List<Shape> _tree(XmlDocument? d, String part, {bool decor = false}) {
    final tree = _all(d, 'spTree').firstOrNull;
    if (tree == null) return const [];
    final out = <Shape>[];
    _walk(tree, part, pkg.rels(part), _Xf.identity, out, decor);
    return out;
  }

  /** _walk：逐个子元素解析，组合形状递归并换算坐标 */
  void _walk(XmlElement parent, String part, Map<String, String> rels, _Xf xf, List<Shape> out, bool decor) {
    for (final e in parent.childElements) {
      switch (e.name.local) {
        case 'sp' || 'cxnSp':
          if (decor && _phOf(e) != null) continue;
          final s = _shape(e, rels, xf);
          if (s != null) out.add(s);
        case 'pic':
          if (decor && _phOf(e) != null) continue;
          final s = _picture(e, rels, xf);
          if (s != null) out.add(s);
        case 'graphicFrame':
          final s = _frame(e, xf);
          if (s != null) out.add(s);
        case 'grpSp':
          final x = _child(_child(e, 'grpSpPr'), 'xfrm');
          var inner = xf;
          if (x != null) {
            final off = _child(x, 'off'), ext = _child(x, 'ext'), chOff = _child(x, 'chOff'), chExt = _child(x, 'chExt');
            final ecx = _num(ext, 'cx'), ecy = _num(ext, 'cy'), ccx = _num(chExt, 'cx', ecx), ccy = _num(chExt, 'cy', ecy);
            final kx = ccx == 0 ? 1.0 : ecx / ccx, ky = ccy == 0 ? 1.0 : ecy / ccy;
            inner = _Xf(xf.sx * kx, xf.sy * ky, xf.x(_num(off, 'x') - _num(chOff, 'x') * kx), xf.y(_num(off, 'y') - _num(chOff, 'y') * ky));
          }
          _walk(e, part, rels, inner, out, decor);
        case 'AlternateContent':
          final choice = _child(e, 'Choice');
          final pick = choice != null && _all(choice, 'spPr').isNotEmpty ? choice : _child(e, 'Fallback');
          if (pick != null) _walk(pick, part, rels, xf, out, decor);
      }
    }
  }

  /** _phOf：占位符信息，不是占位符时为空 */
  _Ph? _phOf(XmlElement e) {
    final ph = _all(e, 'ph').firstOrNull;
    if (ph == null) return null;
    return (type: _attr(ph, 'type') ?? '', idx: _attr(ph, 'idx') ?? '');
  }

  /** _findPh：在版式或母版里找对应的占位符（先按编号，再按类型） */
  XmlElement? _findPh(XmlDocument? d, _Ph ph, {bool byType = false}) {
    if (d == null) return null;
    String norm(String t) => switch (t) { 'ctrTitle' => 'title', 'subTitle' || 'obj' || '' => 'body', _ => t };
    final all = _all(d, 'sp').toList();
    if (!byType && ph.idx.isNotEmpty) {
      for (final s in all) {
        final p = _phOf(s);
        if (p != null && p.idx == ph.idx) return s;
      }
    }
    for (final s in all) {
      final p = _phOf(s);
      if (p != null && norm(p.type) == norm(ph.type)) return s;
    }
    return null;
  }

  /** _xfrm：位置与大小（EMU），本元素没有时用继承链上的 */
  XmlElement? _xfrmOf(List<XmlElement?> chain) {
    for (final e in chain) {
      final x = _child(_child(e, 'spPr'), 'xfrm');
      if (x != null && _child(x, 'off') != null) return x;
    }
    return null;
  }

  /** _box：换算为比例坐标 */
  ({double x, double y, double w, double h, double rot, bool fh, bool fv}) _box(XmlElement x, _Xf xf) {
    final off = _child(x, 'off'), ext = _child(x, 'ext');
    final ox = xf.x(_num(off, 'x')), oy = xf.y(_num(off, 'y'));
    final w = _num(ext, 'cx') * xf.sx, h = _num(ext, 'cy') * xf.sy;
    return (x: ox / cx, y: oy / cy, w: w / cx, h: h / cy, rot: _num(x, 'rot') / 60000, fh: _attr(x, 'flipH') == '1', fv: _attr(x, 'flipV') == '1');
  }

  /**
   * _shape：普通形状或连接线
   *
   * 处理流程：
   * 1、占位符：找到版式与母版里的同一占位符，位置、文字区设置与样式沿用它们
   * 2、外形、填充与边框（没有设置时取形状样式里的颜色）
   * 3、文字区设置与段落
   */
  Shape? _shape(XmlElement e, Map<String, String> rels, _Xf xf) {
    // 1、占位符
    final ph = _phOf(e);
    final lph = ph == null ? null : _findPh(layout, ph);
    final mph = ph == null ? null : _findPh(master, ph, byType: true);
    final x = _xfrmOf([e, lph, mph]);
    if (x == null) return null;
    final box = _box(x, xf);
    // 2、外形、填充、边框
    final spPr = _child(e, 'spPr');
    final style = _child(e, 'style');
    final prst = _child(spPr, 'prstGeom') ?? _child(_child(lph, 'spPr'), 'prstGeom');
    final geom = _attr(prst, 'prst') ?? (_child(spPr, 'custGeom') != null ? 'cust' : 'rect');
    final adj = [for (final g in _all(prst, 'gd')) (double.tryParse((_attr(g, 'fmla') ?? '').replaceFirst('val ', '')) ?? 0) / 100000];
    ctx.ph = _colorIn(_child(style, 'fillRef'), ctx);
    var fill = _fill(spPr, ctx, rels) ?? _fill(_child(lph, 'spPr'), ctx, rels);
    if (fill == null && style != null && _num(_child(style, 'fillRef'), 'idx') > 0) fill = Fill(color: ctx.ph);
    final ln = _child(spPr, 'ln');
    ctx.ph = _colorIn(_child(style, 'lnRef'), ctx);
    var lineFill = ln == null ? null : _fill(ln, ctx, rels);
    if (lineFill == null && style != null && _num(_child(style, 'lnRef'), 'idx') > 0) lineFill = Fill(color: ctx.ph);
    final lineColor = lineFill == null || lineFill.none ? null : lineFill.color;
    final lineW = ln == null || _attr(ln, 'w') == null ? (lineColor == null ? 0.0 : 0.75) : _num(ln, 'w') / _emuPerPt;
    final connector = e.name.local == 'cxnSp' || geom == 'line' || geom.contains('Connector');
    // 3、文字
    final txBody = _child(e, 'txBody');
    final bodyPrs = [_child(txBody, 'bodyPr'), _child(_child(lph, 'txBody'), 'bodyPr'), _child(_child(mph, 'txBody'), 'bodyPr')];
    String? body(String k) {
      for (final b in bodyPrs) {
        final v = _attr(b, k);
        if (v != null) return v;
      }
      return null;
    }

    double ins(String k, double d) => double.tryParse(body(k) ?? '') == null ? d : double.parse(body(k)!) / _emuPerPt;
    final auto = _all(_child(txBody, 'bodyPr'), 'normAutofit').firstOrNull;
    final kind = ph == null ? 'other' : (ph.type == 'title' || ph.type == 'ctrTitle' ? 'title' : 'body');
    final master0 = _all(master, kind == 'title' ? 'titleStyle' : (kind == 'body' ? 'bodyStyle' : 'otherStyle')).firstOrNull;
    ctx.ph = _colorIn(_child(style, 'fontRef'), ctx);
    final src = _Sources(
      [?_child(txBody, 'lstStyle'), ?_child(_child(lph, 'txBody'), 'lstStyle'), ?_child(_child(mph, 'txBody'), 'lstStyle')],
      [?master0, ?defaults],
      fontColor: style == null ? null : ctx.ph,
      fontRefFace: _attr(_child(style, 'fontRef'), 'idx') == 'major' ? '+mj-lt' : '',
    );
    final paras = txBody == null ? <Para>[] : _paras(txBody, src, kind == 'title');
    final hasText = paras.any((p) => p.text.trim().isNotEmpty);
    if (!hasText && (fill == null || !fill.visible) && lineColor == null) return null;
    return Shape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      rot: box.rot,
      flipH: box.fh,
      flipV: box.fv,
      paras: paras,
      title: kind == 'title',
      fill: fill?.none == true ? null : fill?.color,
      bg: fill,
      geom: geom,
      adj: adj,
      path: geom == 'cust' ? _custPath(_child(spPr, 'custGeom')) : const [],
      line: lineColor,
      lineW: lineW,
      dash: _attr(_child(ln, 'prstDash'), 'val') ?? '',
      head: _attr(_child(ln, 'headEnd'), 'type') ?? '',
      tail: _attr(_child(ln, 'tailEnd'), 'type') ?? '',
      connector: connector,
      anchor: body('anchor') ?? 't',
      insL: ins('lIns', 7.2),
      insT: ins('tIns', 3.6),
      insR: ins('rIns', 7.2),
      insB: ins('bIns', 3.6),
      wrap: body('wrap') != 'none',
      fontScale: auto == null ? 1 : _num(auto, 'fontScale', 100000) / 100000,
    );
  }

  /** _custPath：自定义外形的路径，坐标换算为占形状的比例 */
  List<PathCmd> _custPath(XmlElement? geom) {
    final out = <PathCmd>[];
    for (final p in _all(geom, 'path')) {
      final w = _num(p, 'w', 1), h = _num(p, 'h', 1);
      List<double> pts(XmlElement e) => [for (final pt in _kids(e, 'pt')) ...[_num(pt, 'x') / (w == 0 ? 1 : w), _num(pt, 'y') / (h == 0 ? 1 : h)]];
      for (final c in p.childElements) {
        switch (c.name.local) {
          case 'moveTo':
            out.add(PathCmd('M', pts(c)));
          case 'lnTo':
            out.add(PathCmd('L', pts(c)));
          case 'cubicBezTo':
            out.add(PathCmd('C', pts(c)));
          case 'quadBezTo':
            out.add(PathCmd('Q', pts(c)));
          case 'close':
            out.add(const PathCmd('Z', []));
        }
      }
    }
    return out;
  }

  /**
   * _paras：段落与文字，样式按「文字 → 段落 → 形状 → 版式 → 母版 → 默认」逐级查找
   */
  List<Para> _paras(XmlElement txBody, _Sources src, bool title) {
    final out = <Para>[];
    final counters = <int, int>{};
    for (final p in _kids(txBody, 'p')) {
      final pPr = _child(p, 'pPr');
      final lvl = _num(pPr, 'lvl').toInt().clamp(0, 8);
      final levels = [?pPr, ...src.levels(lvl)];
      String? pa(String k) {
        for (final l in levels) {
          final v = _attr(l, k);
          if (v != null) return v;
        }
        return null;
      }

      XmlElement? pc(String k) {
        for (final l in levels) {
          final v = _child(l, k);
          if (v != null) return v;
        }
        return null;
      }

      double? spc(String k) {
        final e = pc(k);
        if (e == null) return null;
        final pts = _child(e, 'spcPts');
        if (pts != null) return _num(pts, 'val') / 100;
        final pct = _child(e, 'spcPct');
        return pct == null ? null : -_num(pct, 'val') / 100000;
      }

      // 文字
      final runs = <Run>[];
      for (final r in p.childElements) {
        if (r.name.local == 'br') {
          runs.add(const Run('\n'));
          continue;
        }
        if (r.name.local != 'r' && r.name.local != 'fld') continue;
        final text = _child(r, 't')?.innerText ?? '';
        final rprs = [?_child(r, 'rPr'), for (final l in levels) ?_child(l, 'defRPr')];
        String? ra(String k) {
          for (final x in rprs) {
            final v = _attr(x, k);
            if (v != null) return v;
          }
          return null;
        }

        XmlElement? rc(String k) {
          for (final x in rprs) {
            final v = _child(x, k);
            if (v != null) return v;
          }
          return null;
        }

        // 颜色：文字、段落、near 来源 → 形状样式 → far 来源
        final nearFill = [?_child(r, 'rPr'), for (final l in [?pPr, ...src.levels(lvl, nearOnly: true)]) ?_child(l, 'defRPr')].map((x) => _child(x, 'solidFill')).whereType<XmlElement>().firstOrNull;
        final color = nearFill != null ? _colorIn(nearFill, ctx) : (src.fontColor ?? _colorIn(rc('solidFill'), ctx));
        var latin = _face(_attr(rc('latin'), 'typeface'), ctx);
        var ea = _face(_attr(rc('ea'), 'typeface'), ctx);
        if (latin.isEmpty) latin = _face(src.fontRefFace.isNotEmpty ? src.fontRefFace : (title ? '+mj-lt' : '+mn-lt'), ctx);
        if (ea.isEmpty) ea = _face(title ? '+mj-ea' : '+mn-ea', ctx);
        final sz = double.tryParse(ra('sz') ?? '');
        runs.add(Run(
          text,
          bold: ra('b') == '1' || ra('b') == 'true',
          italic: ra('i') == '1' || ra('i') == 'true',
          underline: (ra('u') ?? 'none') != 'none',
          strike: (ra('strike') ?? 'noStrike') != 'noStrike',
          size: sz == null ? null : sz / 100,
          color: color,
          font: latin,
          eaFont: ea,
          spacing: (double.tryParse(ra('spc') ?? '') ?? 0) / 100,
          baseline: (double.tryParse(ra('baseline') ?? '') ?? 0) / 1000,
        ));
      }
      // 项目符号
      var bullet = '';
      final bu = levels.map((l) => l.childElements.where((c) => const {'buNone', 'buChar', 'buAutoNum'}.contains(c.name.local)).firstOrNull).whereType<XmlElement>().firstOrNull;
      final hasText = runs.any((r) => r.text.trim().isNotEmpty);
      if (bu != null && hasText) {
        if (bu.name.local == 'buChar') {
          bullet = _attr(bu, 'char') ?? '•';
          if (const {'§', 'Ø', 'ü', 'n', 'l', 'q', 'v', 'w'}.contains(bullet)) bullet = '•';
          counters.remove(lvl);
        } else if (bu.name.local == 'buAutoNum') {
          final n = (counters[lvl] ?? (_num(bu, 'startAt', 1).toInt() - 1)) + 1;
          counters[lvl] = n;
          bullet = _autoNum(_attr(bu, 'type') ?? 'arabicPeriod', n);
        }
      } else if (hasText) {
        counters.remove(lvl);
      }
      final lnPct = () {
        final e = pc('lnSpc');
        final pct = _child(e, 'spcPct');
        return pct == null ? null : _num(pct, 'val') / 100000;
      }();
      out.add(Para(
        runs,
        level: lvl,
        align: switch (pa('algn')) { 'ctr' => 'center', 'r' => 'right', 'just' || 'dist' => 'both', _ => 'left' },
        bullet: bullet,
        bulletColor: _colorIn(pc('buClr'), ctx),
        marL: (double.tryParse(pa('marL') ?? '') ?? 0) / _emuPerPt,
        indent: (double.tryParse(pa('indent') ?? '') ?? 0) / _emuPerPt,
        spcBef: spc('spcBef') ?? 0,
        spcAft: spc('spcAft') ?? 0,
        lineSpacing: lnPct,
        size: double.tryParse(_attr(_child(p, 'endParaRPr'), 'sz') ?? '') == null ? null : double.parse(_attr(_child(p, 'endParaRPr'), 'sz')!) / 100,
      ));
    }
    return out;
  }

  /** _autoNum：自动编号的文字 */
  static String _autoNum(String type, int n) {
    String roman(int v) {
      const m = [(1000, 'm'), (900, 'cm'), (500, 'd'), (400, 'cd'), (100, 'c'), (90, 'xc'), (50, 'l'), (40, 'xl'), (10, 'x'), (9, 'ix'), (5, 'v'), (4, 'iv'), (1, 'i')];
      final b = StringBuffer();
      for (final (k, s) in m) {
        while (v >= k) {
          b.write(s);
          v -= k;
        }
      }
      return b.toString();
    }

    final base = type.startsWith('alphaLc')
        ? String.fromCharCode(96 + ((n - 1) % 26) + 1)
        : type.startsWith('alphaUc')
            ? String.fromCharCode(64 + ((n - 1) % 26) + 1)
            : type.startsWith('romanLc')
                ? roman(n)
                : type.startsWith('romanUc')
                    ? roman(n).toUpperCase()
                    : type.startsWith('circleNum')
                        ? String.fromCharCode(0x2460 + (n - 1).clamp(0, 19))
                        : '$n';
    if (type.endsWith('ParenBoth')) return '($base)';
    if (type.endsWith('ParenR')) return '$base)';
    if (type.startsWith('circleNum')) return base;
    return '$base.';
  }

  /** _picture：图片（含裁剪），手机无法显示的格式标记为 unsupported */
  Shape? _picture(XmlElement e, Map<String, String> rels, _Xf xf) {
    final ph = _phOf(e);
    final x = _xfrmOf([e, ph == null ? null : _findPh(layout, ph)]);
    if (x == null) return null;
    final box = _box(x, xf);
    final blipFill = _child(e, 'blipFill');
    final blip = _child(blipFill, 'blip');
    if (blip == null) return null;
    // 优先使用矢量图（svgBlip），其次位图
    final svg = _all(blip, 'svgBlip').firstOrNull;
    Uint8List? data = svg == null ? null : pkg.bytes(rels[_rid(svg)] ?? '');
    var kind = data == null ? '' : 'svg';
    if (data == null) {
      data = pkg.bytes(rels[_rid(blip)] ?? '');
      kind = data == null ? '' : imageKind(data);
    }
    if (data == null) return null;
    final src = _child(blipFill, 'srcRect');
    final ln = _child(_child(e, 'spPr'), 'ln');
    final lf = ln == null ? null : _fill(ln, ctx, rels);
    return Shape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      rot: box.rot,
      flipH: box.fh,
      flipV: box.fv,
      image: data,
      imageKind: kind,
      geom: _attr(_child(_child(e, 'spPr'), 'prstGeom'), 'prst') ?? 'rect',
      crop: src == null ? null : Crop(_num(src, 'l') / 100000, _num(src, 't') / 100000, _num(src, 'r') / 100000, _num(src, 'b') / 100000),
      line: lf == null || lf.none ? null : lf.color,
      lineW: ln == null ? 0 : _num(ln, 'w', 9525) / _emuPerPt,
    );
  }

  /** _frame：表格；图表等其他内容显示为带名称的占位框 */
  Shape? _frame(XmlElement e, _Xf xf) {
    final x = _child(e, 'xfrm');
    if (x == null) return null;
    final box = _box(x, xf);
    final tbl = _all(e, 'tbl').firstOrNull;
    if (tbl == null) {
      final chart = _all(e, 'chart').isNotEmpty;
      return Shape(x: box.x, y: box.y, w: box.w, h: box.h, imageKind: chart ? 'chart' : 'object', fill: 0xFFF2F4F7);
    }
    final cols = [for (final g in _all(_child(tbl, 'tblGrid'), 'gridCol')) _num(g, 'w')];
    final rows = _kids(tbl, 'tr').toList();
    final heights = [for (final r in rows) _num(r, 'h')];
    final tw = cols.fold(0.0, (a, b) => a + b), th = heights.fold(0.0, (a, b) => a + b);
    final src = _Sources(const [], [?_all(master, 'otherStyle').firstOrNull, ?defaults]);
    final cells = <List<TableCell>>[];
    for (final r in rows) {
      final row = <TableCell>[];
      for (final tc in _kids(r, 'tc')) {
        final tcPr = _child(tc, 'tcPr');
        final f = _fill(tcPr, ctx, const {});
        row.add(TableCell(
          paras: _child(tc, 'txBody') == null ? const [] : _paras(_child(tc, 'txBody')!, src, false),
          fill: f == null || f.none ? null : f.color,
          colSpan: _num(tc, 'gridSpan', 1).toInt(),
          rowSpan: _num(tc, 'rowSpan', 1).toInt(),
          hidden: _attr(tc, 'hMerge') == '1' || _attr(tc, 'vMerge') == '1',
          anchor: _attr(tcPr, 'anchor') ?? 't',
        ));
      }
      cells.add(row);
    }
    return Shape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      table: SlideTable([for (final c in cols) tw == 0 ? 0 : c / tw], [for (final h in heights) th == 0 ? 1 / heights.length : h / th], cells),
    );
  }
}

/** imageKind：按文件头判断图片格式，手机无法显示的（emf、wmf、tiff 等）为 unsupported */
String imageKind(Uint8List b) {
  if (b.length >= 4 && b[0] == 0x89 && b[1] == 0x50) return 'png';
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8) return 'jpeg';
  if (b.length >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
  if (b.length >= 2 && b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
  if (b.length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) return 'webp';
  final head = utf8.decode(b.sublist(0, math.min(256, b.length)), allowMalformed: true).trimLeft();
  if (head.startsWith('<svg') || (head.startsWith('<?xml') && head.contains('<svg'))) return 'svg';
  return 'unsupported';
}
