/**
 * Office 测试样本：在内存中生成最小的 docx、xlsx、pptx 包。
 */
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/** zip：把若干文件打包 */
Uint8List zip(Map<String, Object> files) {
  final a = Archive();
  files.forEach((k, v) {
    final b = v is String ? utf8.encode(v) : v as List<int>;
    a.addFile(ArchiveFile(k, b.length, b));
  });
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/** w：Word 命名空间 */
const w = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"';

/** samplePng：1×1 像素图片 */
final samplePng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/** docxBytes：Word 样本 */
Uint8List docxBytes() {
  return zip({
    'word/document.xml': '<w:document $w><w:body>'
        '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>项目周报</w:t></w:r></w:p>'
        '<w:p><w:r><w:rPr><w:b/><w:color w:val="FF0000"/><w:sz w:val="28"/></w:rPr><w:t>重点：</w:t></w:r><w:r><w:rPr><w:i/></w:rPr><w:t xml:space="preserve"> 配对完成</w:t></w:r></w:p>'
        '<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="3"/></w:numPr></w:pPr><w:r><w:t>子项</w:t></w:r></w:p>'
        '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>项目</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>状态</w:t></w:r></w:p></w:tc></w:tr>'
        '<w:tr><w:tc><w:p><w:r><w:t>传输</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>完成</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
        '<w:p><w:r><w:drawing><wp:inline><wp:extent cx="1270000" cy="635000"/><a:graphic><a:graphicData><a:blip r:embed="rId5"/></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>'
        '</w:body></w:document>',
    'word/_rels/document.xml.rels': '<Relationships><Relationship Id="rId5" Target="media/image1.png"/></Relationships>',
    'word/media/image1.png': samplePng,
    'word/styles.xml': '<w:styles $w><w:style w:styleId="Heading1"><w:name w:val="heading 1"/></w:style></w:styles>',
  });
}

/** xlsxBytes：Excel 样本 */
Uint8List xlsxBytes() {
  return zip({
    'xl/workbook.xml': '<workbook xmlns:r="r"><sheets><sheet name="汇总" sheetId="1" r:id="rId1"/><sheet name="明细" sheetId="2" r:id="rId2"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/></Relationships>',
    'xl/sharedStrings.xml': '<sst><si><t>名称</t></si><si><r><t>金</t></r><r><t>额</t></r></si></sst>',
    'xl/styles.xml': '<styleSheet><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>',
    'xl/worksheets/sheet1.xml': '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>'
        '<row r="2"><c r="A2" t="inlineStr"><is><t>午饭</t></is></c><c r="B2"><v>35.100000000000001</v></c><c r="C2" s="1"><v>45931</v></c></row></sheetData></worksheet>',
    'xl/worksheets/sheet2.xml': '<worksheet><sheetData><row r="30"><c r="AB30" t="b"><v>1</v></c></row></sheetData></worksheet>',
  });
}

/** pptxBytes：PPT 样本 */
Uint8List pptxBytes() {
  // 与真实文件一致：页序元素同时带 id 与 r:id
  const p = 'xmlns:p="p" xmlns:a="a" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"';
  return zip({
    'ppt/presentation.xml': '<p:presentation $p><p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/></p:presentation>',
    'ppt/_rels/presentation.xml.rels': '<Relationships><Relationship Id="rId2" Target="slides/slide2.xml"/><Relationship Id="rId3" Target="slides/slide1.xml"/></Relationships>',
    'ppt/slides/slide1.xml': '<p:sld $p><p:cSld><p:spTree>'
        '<p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="609600" y="342900"/><a:ext cx="10972800" cy="1143000"/></a:xfrm></p:spPr>'
        '<p:txBody><a:p><a:pPr algn="ctr"/><a:r><a:rPr sz="4400" b="1"/><a:t>第一页标题</a:t></a:r></a:p></p:txBody></p:sp>'
        '<p:pic><p:blipFill><a:blip r:embed="rId9"/></p:blipFill><p:spPr><a:xfrm><a:off x="6096000" y="3429000"/><a:ext cx="3048000" cy="1714500"/></a:xfrm></p:spPr></p:pic>'
        '</p:spTree></p:cSld></p:sld>',
    'ppt/slides/_rels/slide1.xml.rels': '<Relationships><Relationship Id="rId9" Target="../media/image1.png"/></Relationships>',
    'ppt/media/image1.png': samplePng,
    'ppt/slides/slide2.xml': '<p:sld $p><p:cSld><p:spTree><p:sp><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="6096000" cy="3429000"/></a:xfrm></p:spPr>'
        '<p:txBody><a:p><a:r><a:t>第二页正文</a:t></a:r></a:p><a:p><a:pPr lvl="1"/><a:r><a:t>要点</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>',
  });
}

