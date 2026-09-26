/**
 * 连接与传输队列测试：多地址探测选择、上传与无名数据、自动接收并确认、暂停继续、取消、离线退避后恢复、仅 Wi-Fi 与低电量暂停、重启恢复。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/transfer_manager.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/transfer/task.dart';

import '../data/local_db_test.dart' show openTestDb;
import '../support/fake_host.dart';

void main() {
  late FakeHost host;
  late LocalDb db;
  late Directory tmp;
  late HostConnection conn;
  var opts = const QueueOptions();

  HostConnection connect(List<String> addrs) => HostConnection(
        host: PairedHost(id: 'h', name: '电脑', addresses: addrs, port: host.base.port, fingerprint: ''),
        token: 'tk',
        cursors: () => {},
        clients: (_) => HttpClient(),
        scheme: 'http',
      );

  TransferManager manager() => TransferManager(
        db: db,
        hostId: 'h',
        conn: conn,
        saver: DirSaver(() async => Directory('${tmp.path}/saved')),
        tempDir: () async => Directory('${tmp.path}/temp')..createSync(recursive: true),
        options: () => opts,
      );

  Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(max);
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('条件未满足');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    host = FakeHost();
    await host.start();
    db = await openTestDb();
    tmp = await Directory.systemTemp.createTemp('pdtm');
    opts = const QueueOptions();
    conn = connect(['127.0.0.3', '127.0.0.1']);
    expect(await conn.connect(), isTrue);
  });
  tearDown(() async {
    conn.dispose();
    await host.close();
    await db.db.close();
    await tmp.delete(recursive: true);
  });

  test('探测跳过不可达地址并建立事件通道', () async {
    expect(conn.address, '127.0.0.1');
    expect(conn.kindLabel, '局域网');
    expect(conn.status!.name, '测试电脑');
    await until(() => conn.online);
    expect(host.received.first['type'], 'hello');
    final dead = connect(['127.0.0.3']);
    expect(await dead.connect(), isFalse);
    expect(dead.lastError, '电脑不在线');
    expect(dead.addAddress('127.0.0.1'), isTrue);
    expect(dead.addAddress('127.0.0.1'), isFalse);
    expect(await dead.connect(), isTrue);
    dead.dispose();
  });

  test('上传文件与无名数据', () async {
    final m = manager();
    final f = File('${tmp.path}/a.txt')..writeAsBytesSync(randomBytes(3000));
    final t1 = await m.upload(f.path, name: '报告.txt');
    final t2 = await m.upload(f.path, mime: 'text/plain');
    await m.wait(t1);
    await m.wait(t2);
    expect(t1.status, TaskStatus.done);
    expect(t2.status, TaskStatus.done);
    expect(host.completed['报告.txt'], randomBytes(3000));
    expect(host.completed.containsKey('noname.bin'), isTrue);
    expect(TransferManager.displayName(t2), endsWith('.txt'));
    expect(m.done.length, 2);
    await m.clearDone();
    expect(m.tasks, isEmpty);
    expect(await db.transfers('h'), isEmpty);
    m.dispose();
  });

  test('自动接收电脑发来的文件并确认，重复轮询不重复下载', () async {
    host.outbox['o1'] = (name: '结果.pdf', data: randomBytes(20000, 3));
    final m = manager();
    m.onConnected();
    await until(() => m.tasks.isNotEmpty);
    await m.wait(m.tasks.single);
    final t = m.tasks.single;
    expect(t.status, TaskStatus.done);
    expect(File(t.result).readAsBytesSync(), randomBytes(20000, 3));
    expect(t.result, contains('${Platform.pathSeparator}${t.dateFolder}${Platform.pathSeparator}'));
    expect(host.acked, ['o1']);
    await m.pollOutbox();
    expect(m.tasks.length, 1);
    m.dispose();
  });

  test('关闭自动接收时只返回待收列表', () async {
    host.outbox['o2'] = (name: 'x.bin', data: randomBytes(10));
    opts = const QueueOptions(autoReceive: false);
    final m = manager();
    expect(await m.pollOutbox(), ['o2']);
    expect(m.tasks, isEmpty);
    m.dispose();
  });

  test('排队中暂停、继续与取消', () async {
    opts = const QueueOptions(wifiOnly: true);
    final m = manager();
    m.setNet(const NetState(wifi: false));
    expect(m.blockedReason, '等待 Wi-Fi');
    final f = File('${tmp.path}/b.bin')..writeAsBytesSync(randomBytes(5000));
    final t = await m.upload(f.path, name: 'b.bin');
    expect(t.status, TaskStatus.waiting);
    m.pause(t);
    expect(t.status, TaskStatus.paused);
    m.resume(t);
    expect(t.status, TaskStatus.waiting);
    m.setNet(const NetState());
    await m.wait(t);
    expect(t.status, TaskStatus.done);
    final t2 = await m.upload(f.path, name: 'c.bin');
    await m.cancel(t2);
    expect(m.tasks.contains(t2), isFalse);
    expect((await m.wait(t2)).status, TaskStatus.canceled);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await db.transfers('h')).map((r) => r['id']), [t.id]);
    m.dispose();
  });

  test('低电量暂停，恢复后继续', () async {
    final m = manager();
    m.setNet(const NetState(lowBattery: true));
    expect(m.blockedReason, '电量低，已暂停');
    final f = File('${tmp.path}/d.bin')..writeAsBytesSync(randomBytes(100));
    final t = await m.upload(f.path, name: 'd.bin');
    expect(t.status, TaskStatus.waiting);
    m.setNet(const NetState());
    await m.wait(t);
    expect(t.status, TaskStatus.done);
    m.dispose();
  });

  test('电脑离线时等待并在恢复后完成', () async {
    host.outbox['o3'] = (name: 'y.bin', data: randomBytes(5000, 9));
    final m = manager();
    host.apiDown = true;
    final t = await m.download('outbox:o3', 'y.bin', 5000);
    await until(() => t.status == TaskStatus.waiting);
    expect(t.error, '等待电脑在线');
    host.apiDown = false;
    m.onConnected();
    await m.wait(t);
    expect(t.status, TaskStatus.done);
    m.dispose();
  });

  test('重启后恢复未完成任务', () async {
    opts = const QueueOptions(wifiOnly: true);
    final m1 = manager();
    m1.setNet(const NetState(wifi: false));
    final f = File('${tmp.path}/e.bin')..writeAsBytesSync(randomBytes(700));
    await m1.upload(f.path, name: 'e.bin');
    m1.dispose();
    opts = const QueueOptions();
    final m2 = manager();
    await m2.load();
    expect(m2.tasks.single.name, 'e.bin');
    await m2.wait(m2.tasks.single);
    expect(m2.tasks.single.status, TaskStatus.done);
    m2.dispose();
  });
}
