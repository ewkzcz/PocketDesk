/**
 * Office 文档解析（docx、xlsx、pptx 都是 zip 包内的 XML）：
 * Word 取段落、标题层级、文字样式、列表、表格与图片；Excel 取各工作表的单元格（含共享字符串与日期）；
 * PPT 的解析见 pptx.dart，文字与段落沿用这里的 Run、Para。
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/* ---------- 公共 ---------- */

/** _Pkg：zip 包，按路径取文件与关系 */
class _Pkg {
  _Pkg(Uint8List bytes) : _a = ZipDecoder().decodeBytes(bytes);

  final Archive _a;

  Uint8List? bytes(String path) => _a.findFile(path)?.content;

  XmlDocument? xml(String path) {
    final b = bytes(path);
    return b == null ? null : XmlDocument.parse(utf8.decode(b, allowMalformed: true));
  }

  /** rels：某个部件的关系表 id → 目标路径（已按部件所在目录解析） */
  Map<String, String> rels(String part) {
    final i = part.lastIndexOf('/');
    final dir = i < 0 ? '' : part.substring(0, i);
    final name = i < 0 ? part : part.substring(i + 1);
    final doc = xml('${dir.isEmpty ? '' : '$dir/'}_rels/$name.rels');
    if (doc == null) return {};
    return {
      for (final r in doc.findAllElements('Relationship'))
        r.getAttribute('Id') ?? '': _resolve(dir, r.getAttribute('Target') ?? ''),
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

/** _attr：取带命名空间前缀的属性（如 w:val） */
String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

/** _rid：关系编号（r:id），同一元素上可能还有普通的 id 属性 */
String _rid(XmlElement e) {
  for (final a in e.attributes) {
    if (a.name.local == 'id' && (a.name.prefix == 'r' || (a.name.namespaceUri ?? '').contains('relationships'))) return a.value;
  }
  return '';
}

/** _child：第一个指定本地名的直接子元素 */
XmlElement? _child(XmlElement e, String local) {
  for (final c in e.childElements) {
    if (c.name.local == local) return c;
  }
  return null;
}

/** _all：所有指定本地名的后代元素 */
Iterable<XmlElement> _all(XmlNode e, String local) => e.descendants.whereType<XmlElement>().where((x) => x.name.local == local);

/** _color：十六进制颜色转 ARGB，auto 或无效时为 null */
int? _color(String? hex) {
  if (hex == null || hex.length != 6) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : 0xFF000000 | v;
}

/** Run：一段样式相同的文字 */
class Run {
  const Run(this.text, {this.bold = false, this.italic = false, this.underline = false, this.strike = false, this.size, this.color, this.font = '', this.eaFont = '', this.spacing = 0, this.baseline = 0});

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /** 字号（磅） */
  final double? size;
  final int? color;

  /** 西文字体与中文字体（原稿里的字体名，显示时按类别换成手机上有的字体） */
  final String font;
  final String eaFont;

  /** 字间距（磅）与上下标（正数上标、负数下标，按字号比例） */
  final double spacing;
  final double baseline;
}

/** Para：一个段落 */
class Para {
  const Para(
    this.runs, {
    this.heading = 0,
    this.list = false,
    this.level = 0,
    this.align = 'left',
    this.bullet = '',
    this.bulletColor,
    this.marL = 0,
    this.indent = 0,
    this.spcBef = 0,
    this.spcAft = 0,
    this.lineSpacing,
    this.size,
  });

  final List<Run> runs;

  /** 幻灯片段落：项目符号、左缩进与首行缩进（磅）、段前段后（磅，负数为行高倍数）、行距倍数、空段落字号 */
  final String bullet;
  final int? bulletColor;
  final double marL;
  final double indent;
  final double spcBef;
  final double spcAft;
  final double? lineSpacing;
  final double? size;

  /** 标题层级 1–6，正文为 0 */
  final int heading;
  final bool list;
  final int level;
  final String align;

  String get text => runs.map((r) => r.text).join();
}

/* ---------- Word ---------- */

/** DocBlock：Word 文档中的一块内容 */
sealed class DocBlock {
  const DocBlock();
}

class DocPara extends DocBlock {
  const DocPara(this.para);
  final Para para;
}

class DocTable extends DocBlock {
  const DocTable(this.rows);

  /** 行 → 单元格 → 段落 */
  final List<List<List<Para>>> rows;
}

class DocImage extends DocBlock {
  const DocImage(this.bytes, {this.width, this.height});
  final Uint8List bytes;

  /** 原稿中的尺寸（EMU 换算成磅） */
  final double? width;
  final double? height;
}

/**
 * parseDocx：解析 Word 文档
 *
 * 处理流程：
 * 1、读取样式表，找出各标题样式的层级
 * 2、按顺序遍历正文的段落与表格；段落中的图片单独成块
 */
List<DocBlock> parseDocx(Uint8List bytes) {
  final pkg = _Pkg(bytes);
  final doc = pkg.xml('word/document.xml');
  if (doc == null) throw const FormatException('不是有效的 Word 文档');
  final rels = pkg.rels('word/document.xml');
  // 1、标题样式
  final headingOf = <String, int>{};
  final styles = pkg.xml('word/styles.xml');
  if (styles != null) {
    for (final s in _all(styles, 'style')) {
      final id = _attr(s, 'styleId') ?? '';
      final name = (_child(s, 'name') == null ? '' : _attr(_child(s, 'name')!, 'val') ?? '').toLowerCase();
      final m = RegExp(r'(?:heading|标题)\s*([1-6])').firstMatch(name) ?? RegExp(r'^(?:heading|标题)([1-6])$', caseSensitive: false).firstMatch(id);
      if (m != null) headingOf[id] = int.parse(m.group(1)!);
      if (name == 'title') headingOf[id] = 1;
    }
  }
  // 2、正文
  final body = _all(doc, 'body').firstOrNull;
  if (body == null) return const [];
  final out = <DocBlock>[];
  for (final e in body.childElements) {
    if (e.name.local == 'p') {
      out.addAll(_docPara(e, headingOf, rels, pkg));
    } else if (e.name.local == 'tbl') {
      out.add(DocTable([
        for (final tr in e.childElements.where((x) => x.name.local == 'tr'))
          [
            for (final tc in tr.childElements.where((x) => x.name.local == 'tc'))
              [for (final p in tc.childElements.where((x) => x.name.local == 'p')) ..._docPara(p, headingOf, rels, pkg).whereType<DocPara>().map((b) => b.para)],
          ],
      ]));
    }
  }
  return out;
}

/** _docPara：一个 Word 段落，文字与图片分成多块 */
List<DocBlock> _docPara(XmlElement p, Map<String, int> headingOf, Map<String, String> rels, _Pkg pkg) {
  final pPr = _child(p, 'pPr');
  final style = pPr == null || _child(pPr, 'pStyle') == null ? '' : _attr(_child(pPr, 'pStyle')!, 'val') ?? '';
  final numPr = pPr == null ? null : _child(pPr, 'numPr');
  final level = numPr == null || _child(numPr, 'ilvl') == null ? 0 : int.tryParse(_attr(_child(numPr, 'ilvl')!, 'val') ?? '') ?? 0;
  final jc = pPr == null || _child(pPr, 'jc') == null ? 'left' : _attr(_child(pPr, 'jc')!, 'val') ?? 'left';
  final runs = <Run>[];
  final images = <DocImage>[];
  for (final r in _all(p, 'r')) {
    final rPr = _child(r, 'rPr');
    bool on(String k) {
      final x = rPr == null ? null : _child(rPr, k);
      return x != null && _attr(x, 'val') != '0' && _attr(x, 'val') != 'false';
    }

    final sz = rPr == null || _child(rPr, 'sz') == null ? null : (int.tryParse(_attr(_child(rPr, 'sz')!, 'val') ?? '') ?? 0) / 2;
    final color = rPr == null || _child(rPr, 'color') == null ? null : _color(_attr(_child(rPr, 'color')!, 'val'));
    final u = rPr == null ? null : _child(rPr, 'u');
    final buf = StringBuffer();
    for (final c in r.childElements) {
      switch (c.name.local) {
        case 't':
          buf.write(c.innerText);
        case 'tab':
          buf.write('\t');
        case 'br' || 'cr':
          buf.write('\n');
        case 'drawing' || 'pict':
          for (final blip in _all(c, 'blip')) {
            final id = _attr(blip, 'embed') ?? '';
            final data = rels[id] == null ? null : pkg.bytes(rels[id]!);
            final ext = _all(c, 'extent').firstOrNull;
            if (data != null) {
              images.add(DocImage(data,
                  width: ext == null ? null : (double.tryParse(_attr(ext, 'cx') ?? '') ?? 0) / 12700,
                  height: ext == null ? null : (double.tryParse(_attr(ext, 'cy') ?? '') ?? 0) / 12700));
            }
          }
      }
    }
    if (buf.isNotEmpty) {
      runs.add(Run(buf.toString(), bold: on('b'), italic: on('i'), underline: u != null && _attr(u, 'val') != 'none', strike: on('strike'), size: sz, color: color));
    }
  }
  return [
    if (runs.isNotEmpty || images.isEmpty) DocPara(Para(runs, heading: headingOf[style] ?? 0, list: numPr != null, level: level, align: jc)),
    ...images,
  ];
}

/* ---------- Excel ---------- */

/** Sheet：一个工作表，cells[行][列] 为显示文字（从 0 开始） */
class Sheet {
  const Sheet(this.name, this.cells, this.rows, this.cols);

  final String name;
  final Map<int, Map<int, String>> cells;
  final int rows;
  final int cols;
}

/** 内置的日期数字格式编号 */
const _dateFormats = {14, 15, 16, 17, 22, 27, 30, 36, 45, 46, 47, 50, 57};

/**
 * parseXlsx：解析 Excel 工作簿
 *
 * 处理流程：
 * 1、共享字符串表与日期格式的样式
 * 2、按工作簿顺序读取各工作表的单元格；数字格式为日期的换算成日期
 */
List<Sheet> parseXlsx(Uint8List bytes, {int maxRows = 5000, int maxCols = 200}) {
  final pkg = _Pkg(bytes);
  final wb = pkg.xml('xl/workbook.xml');
  if (wb == null) throw const FormatException('不是有效的 Excel 文件');
  final rels = pkg.rels('xl/workbook.xml');
  // 1、共享字符串与日期样式
  final shared = <String>[];
  final ss = pkg.xml('xl/sharedStrings.xml');
  if (ss != null) {
    for (final si in _all(ss, 'si')) {
      shared.add(_all(si, 't').map((t) => t.innerText).join());
    }
  }
  final dateStyle = <int>{};
  final styles = pkg.xml('xl/styles.xml');
  if (styles != null) {
    final custom = <int>{
      for (final f in _all(styles, 'numFmt'))
        if (RegExp(r'[ymd]', caseSensitive: false).hasMatch((_attr(f, 'formatCode') ?? '').replaceAll(RegExp(r'\[[^\]]*\]|"[^"]*"'), '')))
          int.tryParse(_attr(f, 'numFmtId') ?? '') ?? -1,
    };
    final xfs = _all(styles, 'cellXfs').firstOrNull;
    if (xfs != null) {
      var i = 0;
      for (final xf in xfs.childElements.where((x) => x.name.local == 'xf')) {
        final id = int.tryParse(_attr(xf, 'numFmtId') ?? '') ?? 0;
        if (_dateFormats.contains(id) || custom.contains(id)) dateStyle.add(i);
        i++;
      }
    }
  }
  // 2、工作表
  final out = <Sheet>[];
  for (final s in _all(wb, 'sheet')) {
    final target = rels[_rid(s)];
    final doc = target == null ? null : pkg.xml(target);
    if (doc == null) continue;
    final cells = <int, Map<int, String>>{};
    var rows = 0, cols = 0;
    for (final c in _all(doc, 'c')) {
      final ref = _attr(c, 'r') ?? '';
      final pos = cellPos(ref);
      if (pos == null || pos.$1 >= maxRows || pos.$2 >= maxCols) continue;
      final t = _attr(c, 't') ?? 'n';
      final v = _child(c, 'v')?.innerText ?? '';
      final style = int.tryParse(_attr(c, 's') ?? '') ?? 0;
      final text = switch (t) {
        's' => shared.elementAtOrNull(int.tryParse(v) ?? -1) ?? '',
        'inlineStr' => _all(c, 't').map((x) => x.innerText).join(),
        'b' => v == '1' ? 'TRUE' : 'FALSE',
        'str' || 'e' => v,
        _ => dateStyle.contains(style) ? excelDate(double.tryParse(v)) : formatNumber(v),
      };
      if (text.isEmpty) continue;
      cells.putIfAbsent(pos.$1, () => {})[pos.$2] = text;
      if (pos.$1 + 1 > rows) rows = pos.$1 + 1;
      if (pos.$2 + 1 > cols) cols = pos.$2 + 1;
    }
    out.add(Sheet(_attr(s, 'name') ?? '工作表${out.length + 1}', cells, rows, cols));
  }
  return out;
}

/** cellPos：A1 形式的单元格位置转为 (行, 列)，从 0 开始 */
(int, int)? cellPos(String ref) {
  final m = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(ref.toUpperCase());
  if (m == null) return null;
  var col = 0;
  for (final ch in m.group(1)!.codeUnits) {
    col = col * 26 + (ch - 64);
  }
  return (int.parse(m.group(2)!) - 1, col - 1);
}

/** columnName：列号转字母（0 → A，26 → AA） */
String columnName(int col) {
  var n = col + 1;
  var s = '';
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

/** excelDate：Excel 日期序号转文字（含时间时带上时分） */
String excelDate(double? serial) {
  if (serial == null) return '';
  final d = DateTime.utc(1899, 12, 30).add(Duration(milliseconds: (serial * 86400000).round()));
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${d.year}-${two(d.month)}-${two(d.day)}';
  return serial % 1 == 0 ? date : '$date ${two(d.hour)}:${two(d.minute)}';
}

/** formatNumber：去掉浮点误差，最多保留 10 位小数 */
String formatNumber(String v) {
  final n = double.tryParse(v);
  if (n == null) return v;
  if (n == n.roundToDouble() && n.abs() < 1e15) return n.toInt().toString();
  var s = n.toStringAsFixed(10);
  s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return s;
}
