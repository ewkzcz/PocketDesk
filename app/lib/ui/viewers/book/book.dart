/**
 * 电子书排版：文本解码（UTF-8、UTF-16、GBK 自动识别）、章节识别、段落整理与按页面尺寸分页。
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/painting.dart';

/**
 * decodeText：把文件内容解码为文本
 *
 * 处理流程：
 * 1、有 BOM 时按 BOM（UTF-8、UTF-16 LE/BE）
 * 2、严格按 UTF-8 解码，失败时按 GBK（国内常见的小说编码）
 */
String decodeText(Uint8List b) {
  // 1、BOM
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) return utf8.decode(b.sublist(3), allowMalformed: true);
  if (b.length >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) {
    final le = b[0] == 0xFF;
    final units = <int>[for (var i = 2; i + 1 < b.length; i += 2) le ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]];
    return String.fromCharCodes(units);
  }
  // 2、UTF-8 或 GBK
  try {
    return utf8.decode(b);
  } on FormatException {
    return gbk.decode(b);
  }
}

/** Chapter：一章，[start, end) 为在整本书中的范围 */
class Chapter {
  const Chapter(this.title, this.start, this.end);

  final String title;
  final int start;
  final int end;
}

/** 章节标题：第一章、第 12 回、卷三、Chapter 5、序章、楔子等，单独成行且不太长 */
final _chapterLine = RegExp(
  r'^[ \t　]*(?:(?:第[0-9０-９零〇一二两三四五六七八九十百千万]+[章回节卷集部篇幕])|(?:卷[0-9０-９零〇一二三四五六七八九十百千]+)|(?:chapter\s*[0-9ivxlc]+)|序章|序言|楔子|引子|尾声|后记|番外)[^\n]{0,30}$',
  caseSensitive: false,
  multiLine: true,
);

/** 没有章节标题的长文本按这个长度切段，便于分页与跳转 */
const _chunk = 20000;

/**
 * splitChapters：识别章节
 *
 * 处理流程：
 * 1、按标题行切分，第一个标题之前的内容作为「开始」
 * 2、识别不到或只有一章时，按固定长度切成若干段
 */
List<Chapter> splitChapters(String text) {
  // 1、标题
  final marks = _chapterLine.allMatches(text).toList();
  if (marks.length >= 2) {
    final out = <Chapter>[];
    if (marks.first.start > 0 && text.substring(0, marks.first.start).trim().isNotEmpty) out.add(Chapter('开始', 0, marks.first.start));
    for (var i = 0; i < marks.length; i++) {
      final end = i + 1 < marks.length ? marks[i + 1].start : text.length;
      out.add(Chapter(marks[i].group(0)!.trim(), marks[i].start, end));
    }
    return out;
  }
  // 2、按长度，在换行处切开
  if (text.length <= _chunk) return [Chapter('正文', 0, text.length)];
  final out = <Chapter>[];
  var s = 0;
  while (s < text.length) {
    var e = s + _chunk;
    if (e >= text.length) {
      e = text.length;
    } else {
      final nl = text.indexOf('\n', e);
      e = nl < 0 ? text.length : nl + 1;
    }
    out.add(Chapter('第 ${out.length + 1} 部分', s, e));
    s = e;
  }
  return out;
}

/** tidy：整理一章的段落：去掉空行与行首空白，每段首行缩进两个汉字 */
String tidy(String raw) {
  final lines = raw.split(RegExp(r'\r?\n')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return '';
  return [lines.first, for (final l in lines.skip(1)) '　　$l'].join('\n');
}

/**
 * paginate：按页面尺寸分页，返回每页的起始位置
 *
 * 处理流程：
 * 1、从当前位置取一段文字排版（足够填满一页）
 * 2、找到第一行超出页面底部的位置，作为下一页的起点，保证不截断半行
 */
List<int> paginate(String text, TextStyle style, Size page, {TextScaler scaler = TextScaler.noScaling}) {
  final starts = <int>[];
  if (text.isEmpty) return [0];
  final tp = TextPainter(textDirection: TextDirection.ltr, textScaler: scaler);
  final perLine = (page.width / (style.fontSize ?? 16)).ceil() + 1;
  final lines = (page.height / ((style.fontSize ?? 16) * (style.height ?? 1.2))).ceil() + 2;
  final window = perLine * lines + 64;
  var start = 0;
  while (start < text.length) {
    starts.add(start);
    // 1、排版一段
    final end = (start + window).clamp(0, text.length);
    tp.text = TextSpan(text: text.substring(start, end), style: style);
    tp.layout(maxWidth: page.width);
    if (tp.height <= page.height) {
      if (end >= text.length) break;
    }
    // 2、第一行超出底部的行首
    final metrics = tp.computeLineMetrics();
    var cut = 0.0;
    for (final m in metrics) {
      // 行高含行距，按累计行高判断这一行的底部
      if (cut + m.height > page.height) break;
      cut += m.height;
    }
    var next = cut <= 0 ? 1 : tp.getPositionForOffset(Offset(0, cut + 0.5)).offset;
    if (next <= 0) next = 1;
    if (start + next >= text.length) break;
    start += next;
  }
  tp.dispose();
  return starts;
}

/** pageText：一页的文字（去掉末尾换行，否则排版时会多出一个空行） */
String pageText(String text, List<int> starts, int i) {
  final end = i + 1 < starts.length ? starts[i + 1] : text.length;
  var t = text.substring(starts[i], end);
  while (t.endsWith('\n')) {
    t = t.substring(0, t.length - 1);
  }
  return t;
}
