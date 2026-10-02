/**
 * PPT 解析：模板继承（版式与母版的占位符位置、母版文字样式、主题颜色与字体）、背景、装饰形状、
 * 组合形状坐标、连接线箭头、项目符号、表格、图片裁剪、字体分类与出错页兜底。
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/ui/viewers/office/office.dart';
import 'package:pocketdesk/ui/viewers/office/pptx.dart';
import 'package:pocketdesk/ui/viewers/office/slide_view.dart';

import '../support/office_fixtures.dart';

const _ns = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';

String _rels(Map<String, String> m) => '<Relationships>${m.entries.map((e) {
      final type = e.value.contains('slideLayout')
          ? 'slideLayout'
          : e.value.contains('slideMaster')
              ? 'slideMaster'
              : e.value.contains('theme')
                  ? 'theme'
                  : e.value.contains('media')
                      ? 'image'
                      : 'slide';
      return '<Relationship Id="${e.key}" Type="http://x/$type" Target="${e.value}"/>';
    }).join()}</Relationships>';

/** _deck：带主题、母版、版式的演示文稿 */
Map<String, Object> _deck() => {
      'ppt/presentation.xml': '<p:presentation $_ns><p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst>'
          '<p:sldSz cx="9144000" cy="5143500"/><p:defaultTextStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:defaultTextStyle></p:presentation>',
      'ppt/_rels/presentation.xml.rels': _rels({'rId1': 'slides/slide1.xml', 'rId2': 'slides/slide2.xml'}),
      'ppt/theme/theme1.xml': '<a:theme $_ns><a:themeElements><a:clrScheme name="t">'
          '<a:dk1><a:sysClr val="windowText" lastClr="111111"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>'
          '<a:dk2><a:srgbClr val="222244"/></a:dk2><a:lt2><a:srgbClr val="EEEEEE"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>'
          '</a:clrScheme><a:fontScheme name="f"><a:majorFont><a:latin typeface="Georgia"/><a:ea typeface="宋体"/></a:majorFont>'
          '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface="微软雅黑"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>',
      'ppt/slideMasters/slideMaster1.xml': '<p:sldMaster $_ns><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg2"/></a:solidFill></p:bgPr></p:bg><p:spTree>'
          '<p:sp><p:nvSpPr><p:cNvPr id="2" name="t"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="1000000"/></a:xfrm></p:spPr></p:sp>'
          '<p:sp><p:nvSpPr><p:cNvPr id="3" name="logo"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="8229600" y="4572000"/><a:ext cx="457200" cy="457200"/></a:xfrm>'
          '<a:prstGeom prst="ellipse"/><a:solidFill><a:schemeClr val="accent1"><a:lumMod val="50000"/></a:schemeClr></a:solidFill></p:spPr></p:sp>'
          '</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1"/>'
          '<p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="4000" b="1"><a:solidFill><a:schemeClr val="tx2"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/></a:defRPr></a:lvl1pPr></p:titleStyle>'
          '<p:bodyStyle><a:lvl1pPr marL="342900" indent="-342900"><a:buChar char="•"/><a:defRPr sz="2400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr>'
          '<a:lvl2pPr><a:buAutoNum type="arabicPeriod"/><a:defRPr sz="2000"/></a:lvl2pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>',
      'ppt/slideMasters/_rels/slideMaster1.xml.rels': _rels({'rId1': '../theme/theme1.xml'}),
      'ppt/slideLayouts/slideLayout1.xml': '<p:sldLayout $_ns><p:cSld><p:spTree>'
          '<p:sp><p:nvSpPr><p:cNvPr id="2" name="t"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="457200" y="228600"/><a:ext cx="8229600" cy="857250"/></a:xfrm></p:spPr></p:sp>'
          '<p:sp><p:nvSpPr><p:cNvPr id="3" name="b"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="457200" y="1200150"/><a:ext cx="8229600" cy="3394710"/></a:xfrm></p:spPr></p:sp>'
          '</p:spTree></p:cSld></p:sldLayout>',
      'ppt/slideLayouts/_rels/slideLayout1.xml.rels': _rels({'rId1': '../slideMasters/slideMaster1.xml'}),
      'ppt/slides/slide1.xml': '<p:sld $_ns><p:cSld><p:spTree>'
          '<p:sp><p:nvSpPr><p:cNvPr id="2" name="t"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:t>标题</a:t></a:r></a:p></p:txBody></p:sp>'
          '<p:sp><p:nvSpPr><p:cNvPr id="3" name="b"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr anchor="ctr"/>'
          '<a:p><a:r><a:t>要点一</a:t></a:r></a:p><a:p><a:pPr lvl="1"/><a:r><a:t>子项</a:t></a:r></a:p><a:p><a:pPr lvl="1"/><a:r><a:t>子项二</a:t></a:r></a:p></p:txBody></p:sp>'
          '<p:grpSp><p:grpSpPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="914400" cy="914400"/><a:chOff x="0" y="0"/><a:chExt cx="1828800" cy="1828800"/></a:xfrm></p:grpSpPr>'
          '<p:sp><p:nvSpPr><p:cNvPr id="5" name="g"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm><a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val 25000"/></a:avLst></a:prstGeom>'
          '<a:solidFill><a:srgbClr val="FF0000"/></a:solidFill><a:ln w="25400"><a:solidFill><a:srgbClr val="00FF00"/></a:solidFill><a:prstDash val="dash"/></a:ln></p:spPr></p:sp></p:grpSp>'
          '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="6" name="c"/><p:cNvCxnSpPr/><p:nvPr/></p:nvCxnSpPr><p:spPr><a:xfrm flipH="1"><a:off x="0" y="0"/><a:ext cx="914400" cy="0"/></a:xfrm><a:prstGeom prst="straightConnector1"/>'
          '<a:ln w="12700"><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill><a:tailEnd type="triangle"/></a:ln></p:spPr></p:cxnSp>'
          '<p:pic><p:nvPicPr><p:cNvPr id="7" name="i"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId9"/><a:srcRect l="10000" r="20000"/></p:blipFill>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm></p:spPr></p:pic>'
          '<p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="8" name="tb"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="4000000"/><a:ext cx="4572000" cy="600000"/></p:xfrm>'
          '<a:graphic><a:graphicData><a:tbl><a:tblGrid><a:gridCol w="3048000"/><a:gridCol w="1524000"/></a:tblGrid>'
          '<a:tr h="300000"><a:tc gridSpan="2"><a:txBody><a:bodyPr/><a:p><a:r><a:t>表头</a:t></a:r></a:p></a:txBody><a:tcPr><a:solidFill><a:srgbClr val="DDEEFF"/></a:solidFill></a:tcPr></a:tc><a:tc hMerge="1"><a:txBody><a:bodyPr/><a:p/></a:txBody><a:tcPr/></a:tc></a:tr>'
          '<a:tr h="300000"><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>甲</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc><a:tc><a:txBody><a:bodyPr/><a:p><a:r><a:t>乙</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc></a:tr>'
          '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>'
          '</p:spTree></p:cSld></p:sld>',
      'ppt/slides/_rels/slide1.xml.rels': _rels({'rId1': '../slideLayouts/slideLayout1.xml', 'rId9': '../media/image1.png'}),
      'ppt/media/image1.png': samplePng,
      // 第二页的版式文件损坏，解析出错时只显示这一页的文字
      'ppt/slides/slide2.xml': '<p:sld $_ns><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="x"/><p:cNvSpPr/><p:nvPr><p:ph idx="9"/></p:nvPr></p:nvSpPr>'
          '<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="100" cy="100"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>只剩文字</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
      'ppt/slides/_rels/slide2.xml.rels': _rels({'rId1': '../slideLayouts/slideLayout2.xml'}),
      'ppt/slideLayouts/slideLayout2.xml': '<p:sldLayout $_ns><p:cSld',
    };

void main() {
  test('模板继承：占位符位置、母版文字样式、主题颜色与字体、背景与母版装饰', () {
    final d = parsePptx(zip(_deck()));
    expect(d.slides.length, 2);
    final s = d.slides.first;
    // 背景取自母版 bg2 → lt2
    expect(s.bg?.color, 0xFFEEEEEE);
    // 母版装饰（主题色 accent1 亮度减半）排在最前，占位符不画
    final logo = s.shapes.first;
    expect((logo.geom, logo.fill), ('ellipse', 0xFF203864));
    // 标题：位置取版式，样式取母版：居中、40 磅、加粗、tx2 颜色、主题标题字体
    final title = s.shapes.firstWhere((x) => x.title);
    expect(title.x, 0.05);
    expect(title.y, closeTo(228600 / 5143500, 1e-9));
    final tr = title.paras.single.runs.single;
    expect((title.paras.single.align, tr.size, tr.bold, tr.color, tr.font, tr.eaFont), ('center', 40.0, true, 0xFF222244, 'Georgia', '宋体'));
    // 正文：版式位置、垂直居中、项目符号与自动编号、正文主题字体
    final body = s.shapes.firstWhere((x) => x.paras.length == 3);
    expect(body.anchor, 'ctr');
    expect(body.y, closeTo(1200150 / 5143500, 1e-9));
    expect(body.paras.map((p) => p.bullet), ['•', '1.', '2.']);
    expect((body.paras[0].runs.single.size, body.paras[0].runs.single.color, body.paras[0].marL, body.paras[0].indent), (24.0, 0xFF111111, 27.0, -27.0));
    expect((body.paras[1].runs.single.size, body.paras[1].runs.single.font), (20.0, 'Calibri'));
  });

  test('组合形状坐标、外形与虚线边框、连接线箭头、图片裁剪、表格', () {
    final s = parsePptx(zip(_deck())).slides.first;
    final g = s.shapes.firstWhere((x) => x.geom == 'roundRect');
    // 组内 (914400,0) 尺寸 914400，组缩放 0.5 后位于 (1371600, 914400)，宽 457200
    expect((g.x, g.y, g.w), (1371600 / 9144000, 914400 / 5143500, 457200 / 9144000));
    expect((g.adj.single, g.fill, g.line, g.lineW, g.dash), (0.25, 0xFFFF0000, 0xFF00FF00, 2.0, 'dash'));
    final c = s.shapes.firstWhere((x) => x.connector);
    expect((c.flipH, c.tail, c.line, c.lineW), (true, 'triangle', 0xFF0000FF, 1.0));
    final pic = s.shapes.firstWhere((x) => x.image != null);
    expect((pic.imageKind, pic.crop!.l, pic.crop!.r), ('png', 0.1, 0.2));
    final t = s.shapes.firstWhere((x) => x.table != null).table!;
    expect(t.cols, [2 / 3, 1 / 3]);
    expect((t.cells[0][0].colSpan, t.cells[0][0].fill, t.cells[0][1].hidden, t.cells[1][1].paras.single.text), (2, 0xFFDDEEFF, true, '乙'));
    expect(s.texts, containsAll(['标题', '• 要点一', '  1. 子项', '表头', '甲 | 乙']));
  });

  test('某页解析出错时只保留这页的文字', () {
    final d = parsePptx(zip(_deck()));
    expect(d.slides[1].fallback, ['只剩文字']);
    expect(d.slides[1].texts, ['只剩文字']);
  });

  test('字体按类别换成手机上的字体', () {
    expect(pptFont(const Run('代码', font: 'Consolas', eaFont: '微软雅黑')).family, isNot('serif'));
    expect(pptFont(const Run('code', font: 'Consolas')).family, 'monospace');
    expect(pptFont(const Run('标题', font: 'Arial', eaFont: '宋体')).family, 'serif');
    expect(pptFont(const Run('Title', font: 'Times New Roman', eaFont: '微软雅黑')).family, 'serif');
    final sans = pptFont(const Run('正文', font: 'Arial', eaFont: 'Microsoft YaHei'));
    expect(sans.family, isNull);
    expect(sans.fallback, isEmpty);
  });

  test('图片格式识别', () {
    expect(imageKind(samplePng), 'png');
    expect(imageKind(utf8Bytes('<?xml version="1.0"?><svg xmlns="x"/>')), 'svg');
    expect(imageKind(utf8Bytes('\x01\x00\x00\x00 EMF')), 'unsupported');
  });
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
