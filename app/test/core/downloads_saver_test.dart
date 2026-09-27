/**
 * 下载目录保存：Android 11 起经平台通道写入系统下载目录，其他情况退回 App 目录。
 */
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/transfer_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ch = MethodChannel('pocketdesk/downloads');
  late Directory tmp;
  final calls = <MethodCall>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pddl');
    calls.clear();
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
    await tmp.delete(recursive: true);
  });

  void mock(bool supported) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      calls.add(c);
      if (c.method == 'supported') return supported;
      return '/storage/emulated/0/Download/PocketDesk/${(c.arguments as Map)['folder']}/${(c.arguments as Map)['name']}';
    });
  }

  test('系统支持时写入下载目录，文件名先清理非法字符', () async {
    mock(true);
    final s = DownloadsSaver(DirSaver(() async => Directory('${tmp.path}/app')), android: true);
    final f = File('${tmp.path}/t')..writeAsStringSync('x');
    final p = await s.save(f, '20261001', 'a:b.pdf');
    expect(p, '/storage/emulated/0/Download/PocketDesk/20261001/a_b.pdf');
    expect(calls.map((c) => c.method), ['supported', 'save']);
    expect((calls.last.arguments as Map)['mime'], 'application/pdf');
    // 是否支持只问一次
    await s.save(File('${tmp.path}/t2')..writeAsStringSync('y'), '20261001', 'b.txt');
    expect(calls.where((c) => c.method == 'supported').length, 1);
  });

  test('系统版本过低或不是 Android 时退回 App 目录', () async {
    mock(false);
    for (final android in [true, false]) {
      final s = DownloadsSaver(DirSaver(() async => Directory('${tmp.path}/app')), android: android);
      final f = File('${tmp.path}/t')..writeAsStringSync('x');
      final p = await s.save(f, '20261001', 'r.txt');
      expect(p, startsWith('${tmp.path}/app/20261001/r'));
      expect(File(p).readAsStringSync(), 'x');
    }
    expect(calls.where((c) => c.method == 'save'), isEmpty);
  });
}
