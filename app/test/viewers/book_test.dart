/**
 * 电子书排版：编码识别、章节切分、段落整理与分页。
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/ui/viewers/book/book.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('编码：UTF-8、带 BOM、UTF-16、GBK 都能正确解码', () {
    const s = '第一章 风起\n少年站在山巅。';
    expect(decodeText(Uint8List.fromList(utf8.encode(s))), s);
    expect(decodeText(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(s)])), s);
    final le = <int>[0xFF, 0xFE];
    for (final u in s.codeUnits) {
      le.addAll([u & 0xFF, u >> 8]);
    }
    expect(decodeText(Uint8List.fromList(le)), s);
    expect(decodeText(Uint8List.fromList(gbk.encode(s))), s);
  });

  test('章节：识别常见标题，标题前的内容单独成「开始」', () {
    const text = '作者的话\n\n第一章 风起\n正文一\n第二回　云涌\n正文二\n番外 后来\n正文三';
    final cs = splitChapters(text);
    expect(cs.map((c) => c.title), ['开始', '第一章 风起', '第二回　云涌', '番外 后来']);
    expect(text.substring(cs[1].start, cs[1].end), startsWith('第一章 风起\n正文一'));
    expect(cs.last.end, text.length);
    // 正文中提到「第一章」但不是单独成行的不算
    expect(splitChapters('他翻到第一章看了很久。\n然后睡了。').single.title, '正文');
  });

  test('章节：没有标题的长文本按长度在换行处切段，首尾相接', () {
    final text = List.generate(3000, (i) => '这是第 $i 行文字。').join('\n');
    final cs = splitChapters(text);
    expect(cs.length, greaterThan(1));
    expect(cs.first.start, 0);
    expect(cs.last.end, text.length);
    for (var i = 1; i < cs.length; i++) {
      expect(cs[i].start, cs[i - 1].end);
      expect(text[cs[i].start - 1], '\n');
    }
  });

  test('段落：去掉空行，正文每段首行缩进', () {
    expect(tidy('第一章\n\n   第一段\n\t第二段\n'), '第一章\n　　第一段\n　　第二段');
  });

  test('分页：每页都放得下，页与页首尾相接不丢字', () {
    final text = tidy(List.generate(400, (i) => '第 $i 段：少年站在山巅，看着远方的云海翻涌，心中有无数念头。').join('\n'));
    const style = TextStyle(fontSize: 18, height: 1.8);
    const page = Size(340, 600);
    final starts = paginate(text, style, page);
    expect(starts.length, greaterThan(10));
    expect(starts.first, 0);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1] : text.length;
      expect(end, greaterThan(starts[i]));
      tp.text = TextSpan(text: pageText(text, starts, i), style: style);
      tp.layout(maxWidth: page.width);
      expect(tp.height, lessThanOrEqualTo(page.height + 0.5), reason: '第 ${i + 1} 页超出');
    }
    expect(paginate('', style, page), [0]);
  });
}
