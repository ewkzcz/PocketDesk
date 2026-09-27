/**
 * Office 文档解析：用最小的真实包结构验证 Word、Excel、PPT 的解析结果。
 */
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/ui/viewers/office/office.dart';

import '../support/office_fixtures.dart';

void main() {
  test('Word：标题层级、文字样式、列表、表格与图片', () {
    final doc = docxBytes();
    final blocks = parseDocx(doc);
    final h = (blocks[0] as DocPara).para;
    expect((h.text, h.heading), ('项目周报', 1));
    final p = (blocks[1] as DocPara).para;
    expect(p.runs[0].bold && p.runs[0].size == 14 && p.runs[0].color == 0xFFFF0000, isTrue);
    expect(p.runs[1].italic && p.runs[1].text == ' 配对完成', isTrue);
    final li = (blocks[2] as DocPara).para;
    expect(li.list && li.level == 1, isTrue);
    final t = blocks[3] as DocTable;
    expect(t.rows[1][1].single.text, '完成');
    final img = blocks.whereType<DocImage>().single;
    expect(img.width, 100);
    expect(img.bytes, samplePng);
  });

  test('Excel：多个工作表、共享字符串、数字与日期', () {
    final book = xlsxBytes();
    final sheets = parseXlsx(book);
    expect(sheets.map((s) => s.name), ['汇总', '明细']);
    final s = sheets.first;
    expect([s.cells[0]![0], s.cells[0]![1], s.cells[1]![0], s.cells[1]![1], s.cells[1]![2]], ['名称', '金额', '午饭', '35.1', '2025-10-01']);
    expect((s.rows, s.cols), (2, 3));
    expect(sheets[1].cells[29]![27], 'TRUE');
    expect(columnName(27), 'AB');
    expect(cellPos('AB30'), (29, 27));
  });

  test('PPT：页序、尺寸比例、标题与正文、图片位置', () {
    final deck = pptxBytes();
    final d = parsePptx(deck);
    expect(d.aspect, closeTo(16 / 9, 0.001));
    expect(d.slides.length, 2);
    final title = d.slides[0].shapes.first;
    expect((title.title, title.paras.single.text, title.paras.single.align, title.paras.single.runs.single.size), (true, '第一页标题', 'center', 44.0));
    final pic = d.slides[0].shapes[1];
    expect((pic.x, pic.y, pic.w), (0.5, 0.5, 0.25));
    expect(pic.image, samplePng);
    final body = d.slides[1].shapes.single;
    expect(body.paras.map((p) => (p.text, p.level)), [('第二页正文', 0), ('要点', 1)]);
  });

  test('不是对应格式的文件给出明确错误', () {
    final bad = zip({'x.txt': 'hi'});
    expect(() => parseDocx(bad), throwsFormatException);
    expect(() => parseXlsx(bad), throwsFormatException);
    expect(() => parsePptx(bad), throwsFormatException);
  });
}
