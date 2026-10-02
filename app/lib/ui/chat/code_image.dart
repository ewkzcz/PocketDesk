/**
 * 保存为图片：把代码画成图片，或把图片字节存成文件后交给系统分享面板保存。
 */
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../share.dart';
import '../tokens.dart';

/** 代码图最多画的行数 */
const _maxLines = 800;

/**
 * codeToPng：把代码画成 PNG，配色跟随当前主题
 */
Future<Uint8List> codeToPng(String code, {required bool dark}) async {
  const k = 2.0;
  var lines = code.replaceAll('\t', '    ').split('\n');
  if (lines.length > _maxLines) lines = [...lines.take(_maxLines), '…'];
  final style = TextStyle(fontSize: 13, height: 1.5, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback, color: dark ? const Color(0xFFD4D4D4) : const Color(0xFF24292F));
  final tp = TextPainter(text: TextSpan(text: lines.join('\n'), style: style), textDirection: TextDirection.ltr)..layout();
  final w = math.min(tp.width, 2400.0) + 32, h = tp.height + 32;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec)..scale(k);
  canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = dark ? const Color(0xFF1F1F1F) : const Color(0xFFF2F2F2));
  tp.paint(canvas, const Offset(16, 16));
  final img = await rec.endRecording().toImage((w * k).ceil(), (h * k).ceil());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/**
 * sharePng：把 PNG 存成临时文件，用系统分享面板保存或发送
 */
Future<void> sharePng(Uint8List bytes, String label) async {
  final dir = await getTemporaryDirectory();
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final f = File('${dir.path}${Platform.pathSeparator}$label-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.png');
  await f.writeAsBytes(bytes, flush: true);
  await shareFile(f.path, title: '$label.png');
}
