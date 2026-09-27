/**
 * 手机工作空间：电脑发来的请求在工作空间内列目录、新建文件夹、重命名、删除，不能跳出工作空间。
 */
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/phone_space.dart';
import 'package:pocketdesk/core/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory root;
  late PhoneSpace space;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('pd-phone');
    space = PhoneSpace(settings: await AppSettings.load(), fallbackRoot: root);
    await space.refresh();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<Object?> call(String op, Map<String, dynamic> args) => space.handle(op, args, _NoConn());

  test('列目录、新建文件夹、重命名、删除', () async {
    File('${root.path}/笔记.txt').writeAsStringSync('hi');
    await call('mkdir', {'path': '', 'name': '资料'});
    expect(Directory('${root.path}/资料').existsSync(), isTrue);
    final list = (await call('list', {'path': ''}))! as Map;
    final names = [for (final e in list['entries'] as List) (e as Map)['name']];
    expect(names, ['资料', '笔记.txt'], reason: '文件夹排在前面');
    await call('rename', {'path': '笔记.txt', 'name': '日记.txt'});
    expect(File('${root.path}/日记.txt').readAsStringSync(), 'hi');
    await call('delete', {'paths': ['日记.txt', '资料']});
    expect(root.listSync(), isEmpty);
  });

  test('不能跳出工作空间，也不能删除工作空间本身', () async {
    await expectLater(call('list', {'path': '../'}), throwsA(isA<PhoneFsError>()));
    await expectLater(call('mkdir', {'path': '', 'name': '../外面'}), throwsA(isA<PhoneFsError>()));
    await expectLater(call('delete', {'paths': ['']}), throwsA(isA<PhoneFsError>()));
    await expectLater(call('rename', {'path': '', 'name': 'x'}), throwsA(isA<PhoneFsError>()));
    await call('mkdir', {'path': '', 'name': 'a'});
    await expectLater(call('mkdir', {'path': '', 'name': 'a'}), throwsA(isA<PhoneFsError>()), reason: '同名文件夹');
  });

  test('更换目录与恢复默认', () async {
    final other = '${root.path}/新位置';
    final r = (await call('setRoot', {'path': other}))! as Map;
    expect(r['root'], other);
    expect(Directory(other).existsSync(), isTrue);
    await call('mkdir', {'path': '', 'name': '在新位置'});
    expect(Directory('$other/在新位置').existsSync(), isTrue);
    await space.setRoot(space.defaultRoot);
    expect(space.root, root.path);
    final info = (await call('info', {}))! as Map;
    expect(info['permitted'], isTrue);
  });
}

/** _NoConn：这些操作不需要连接电脑 */
class _NoConn implements HostConnection {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}
