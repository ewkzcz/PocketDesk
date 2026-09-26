/**
 * 保存回电脑：带 If-Match 保存，电脑上的文件在此期间被修改过时（412）让用户选择覆盖、另存为「原名-1」或放弃，并可先查看差异。
 */
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../pages/diff_page.dart';
import '../widgets.dart';

/** SaveOutcome：保存结果（etag 为新版本，path 为另存为时的新路径） */
typedef SaveOutcome = ({bool saved, String etag, String path});

/** 冲突时的选择 */
enum _Choice { overwrite, saveAs, discard, diff }

/**
 * lineDiff：简单的逐行差异（最长公共子序列），输出带 + / - 前缀的行
 */
String lineDiff(String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  // 过长时只比较首尾不同的中间部分，控制计算量
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final ma = a.sublist(start, endA);
  final mb = b.sublist(start, endB);
  final out = <String>['@@ 第 ${start + 1} 行起 @@'];
  if (ma.length * mb.length > 4000000) {
    out.addAll(ma.map((l) => '-$l'));
    out.addAll(mb.map((l) => '+$l'));
    return out.join('\n');
  }
  final dp = List.generate(ma.length + 1, (_) => List<int>.filled(mb.length + 1, 0));
  for (var i = ma.length - 1; i >= 0; i--) {
    for (var j = mb.length - 1; j >= 0; j--) {
      dp[i][j] = ma[i] == mb[j] ? dp[i + 1][j + 1] + 1 : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  var i = 0;
  var j = 0;
  while (i < ma.length && j < mb.length) {
    if (ma[i] == mb[j]) {
      out.add(' ${ma[i]}');
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      out.add('-${ma[i++]}');
    } else {
      out.add('+${mb[j++]}');
    }
  }
  while (i < ma.length) {
    out.add('-${ma[i++]}');
  }
  while (j < mb.length) {
    out.add('+${mb[j++]}');
  }
  return out.join('\n');
}

/** copyName：另存为的文件名（原名-1.扩展名） */
String copyName(String path, int n) {
  final slash = path.lastIndexOf('/');
  final dir = slash >= 0 ? path.substring(0, slash + 1) : '';
  final name = path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? '$dir${name.substring(0, dot)}-$n${name.substring(dot)}' : '$dir$name-$n';
}

/**
 * saveWithConflict：保存并处理冲突
 *
 * 处理流程：
 * 1、带打开时的 ETag 保存
 * 2、412 冲突时询问：覆盖（用最新 ETag 再存）、另存为（原名-1，重名继续加一）、放弃、查看差异
 */
Future<SaveOutcome> saveWithConflict(BuildContext context, {required Workspace ws, required String path, required List<int> bytes, required String etag}) async {
  final api = context.read<AppState>().scope!.conn.api;
  // 1、保存
  try {
    final r = await api.saveFile(ws.id, path, bytes, ifMatch: etag);
    return (saved: true, etag: r.etag, path: path);
  } on ApiException catch (e) {
    if (e.status != 412) rethrow;
    // 2、冲突
    var latest = e.etag;
    while (true) {
      if (!context.mounted) break;
      final choice = await showDialog<_Choice>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('文件已在电脑上被修改'),
          content: const Text('你打开之后，电脑上的这个文件又被改过。要怎么处理你的修改？'),
          actionsOverflowDirection: VerticalDirection.down,
          actionsOverflowButtonSpacing: 4,
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, _Choice.diff), child: const Text('查看差异')),
            TextButton(onPressed: () => Navigator.pop(ctx, _Choice.discard), child: const Text('放弃我的修改')),
            TextButton(onPressed: () => Navigator.pop(ctx, _Choice.saveAs), child: Text('另存为 ${copyName(path, 1).split('/').last}')),
            TextButton(onPressed: () => Navigator.pop(ctx, _Choice.overwrite), child: const Text('覆盖')),
          ],
        ),
      );
      switch (choice) {
        case _Choice.diff:
          final remote = await api.readFile(ws.id, path);
          latest = remote.etag;
          if (!context.mounted) break;
          await Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: const PdBar(title: '电脑上的版本 → 我的修改'),
              body: DiffText(lineDiff(utf8.decode(remote.bytes, allowMalformed: true), utf8.decode(bytes, allowMalformed: true))),
            ),
          ));
        case _Choice.overwrite:
          if (latest.isEmpty) latest = (await api.readFile(ws.id, path)).etag;
          final r = await api.saveFile(ws.id, path, bytes, ifMatch: latest);
          return (saved: true, etag: r.etag, path: path);
        case _Choice.saveAs:
          for (var n = 1; n < 100; n++) {
            final p = copyName(path, n);
            try {
              final r = await api.saveFile(ws.id, p, bytes, create: true);
              return (saved: true, etag: r.etag, path: p);
            } on ApiException catch (e) {
              // 已存在同名文件（电脑端要求 If-Match）时换下一个序号
              if (e.status != 409 && e.status != 412 && e.status != 428) rethrow;
            }
          }
          return (saved: false, etag: etag, path: path);
        case _Choice.discard || null:
          return (saved: false, etag: etag, path: path);
      }
    }
    return (saved: false, etag: etag, path: path);
  }
}
