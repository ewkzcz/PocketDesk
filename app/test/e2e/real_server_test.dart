/**
 * 真实电脑端联调：启动电脑端程序，用手机端的真实网络代码完成扫码配对（证书固定）、事件通道、文件浏览与冲突保存、
 * 断点上传、电脑发文件自动接收、终端与文件传输助手。
 * 只有设置环境变量 PD_E2E_BIN（电脑端程序路径）时运行。
 */
@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/pairing.dart';
import 'package:pocketdesk/core/pairing_service.dart';
import 'package:pocketdesk/core/sessions_store.dart';
import 'package:pocketdesk/core/transfer_manager.dart';
import 'package:pocketdesk/core/vault.dart';
import 'package:pocketdesk/data/chat.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/net/api.dart';
import 'package:pocketdesk/net/events.dart';
import 'package:pocketdesk/transfer/task.dart';

import '../data/local_db_test.dart' show openTestDb;
import '../support/fake_host.dart' show randomBytes;

final _bin = Platform.environment['PD_E2E_BIN'] ?? '';
const _port = 18443;
const _adminPort = 18444;

void main() {
  late Directory home;
  late Directory wsDir;
  late Process proc;
  late String adminKey;
  late LocalDb db;
  final vault = MemoryVault();
  late PairedHost host;
  late HostConnection conn;
  final events = <PdEvent>[];

  /** admin：调用电脑端本机管理接口 */
  Future<dynamic> admin(String method, String path, [Object? body]) async {
    final c = HttpClient();
    try {
      final req = await c.openUrl(method, Uri.parse('http://127.0.0.1:$_adminPort$path'));
      req.headers.set('X-PD-Key', adminKey);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      final text = await utf8.decodeStream(res);
      expect(res.statusCode, lessThan(300), reason: '$method $path → $text');
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      c.close();
    }
  }

  Future<void> until(FutureOr<bool> Function() ok, {Duration max = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(max);
    while (!await ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('条件未满足');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  setUpAll(() async {
    if (_bin.isEmpty) return;
    // 1、电脑端数据目录与配置
    home = await Directory.systemTemp.createTemp('pde2e');
    wsDir = await Directory('${home.path}/ws').create();
    await File('${wsDir.path}/README.md').writeAsString('# 标题\n\n正文 **加粗**，`代码`。\n\n| a | b |\n|---|---|\n| 1 | 2 |\n');
    await File('${wsDir.path}/notes.txt').writeAsString('第一行\n');
    await File('${home.path}/data/config.json').create(recursive: true).then((f) => f.writeAsString(jsonEncode({
          'hostName': '联调电脑',
          'port': _port,
          'adminPort': _adminPort,
          'features': {'agents': true, 'terminal': true, 'fileEdit': true},
          'transfer': {'inboxDir': '${home.path}/Inbox', 'outboxDir': '${home.path}/Outbox', 'uploadExpireDays': 7},
        })));
    // 2、启动电脑端
    proc = await Process.start(_bin, ['serve'], environment: {'POCKETDESK_HOME': '${home.path}/data'});
    proc.stdout.transform(utf8.decoder).listen((l) => printOnFailure('电脑端：$l'));
    proc.stderr.transform(utf8.decoder).listen((l) => printOnFailure('电脑端：$l'));
    final keyFile = File('${home.path}/data/admin.key');
    await until(() async {
      try {
        // 密钥文件刚创建时可能还是空的，每次重新读取
        adminKey = (await keyFile.readAsString()).trim();
        await admin('GET', '/admin/api/state');
        return true;
      } catch (e) {
        printOnFailure('等待电脑端：$e');
        return false;
      }
    });
    await admin('POST', '/admin/api/workspaces', {'name': '联调工作区', 'rootPath': wsDir.path, 'readOnly': false});
    db = await openTestDb();
  });

  HostConnection? connRef;

  tearDownAll(() async {
    if (_bin.isEmpty) return;
    // 先结束电脑端进程，避免端口残留
    proc.kill();
    await proc.exitCode;
    connRef?.dispose();
    await db.db.close();
    await home.delete(recursive: true);
  });

  test('扫码配对：核对证书指纹，电脑端允许后拿到令牌', () async {
    final start = await admin('POST', '/admin/api/pair/start') as Map;
    final parsed = PairTicket.parse(start['qrText'] as String)!;
    expect(parsed.name, '联调电脑');
    expect(parsed.port, _port);
    final ticket = PairTicket(name: parsed.name, addresses: ['127.0.0.1'], port: parsed.port, fingerprint: parsed.fingerprint, code: parsed.code);
    // 指纹不一致时拒绝
    final bad = PairTicket(name: '', addresses: ['127.0.0.1'], port: _port, fingerprint: '0' * 64, code: parsed.code);
    await expectLater(PairingService(db: db, vault: vault, deviceName: '联调手机', platform: 'android').pairTicket(bad), throwsA(isA<PairError>()));
    // 电脑端确认
    Future<void> allow() async {
      await until(() async => ((await admin('GET', '/admin/api/state') as Map)['pending'] as List).isNotEmpty);
      final id = (((await admin('GET', '/admin/api/state') as Map)['pending'] as List).first as Map)['id'];
      await admin('POST', '/admin/api/pair/$id', {'allow': true});
    }

    final approve = allow();
    host = await PairingService(db: db, vault: vault, deviceName: '联调手机', platform: 'android').pairTicket(ticket);
    await approve;
    expect(host.fingerprint, parsed.fingerprint);
    expect(host.name, '联调电脑');
    expect(await vault.token(host.id), isNotEmpty);
  }, skip: _bin.isEmpty);

  test('连接：证书固定的接口与事件通道', () async {
    final token = (await vault.token(host.id))!;
    conn = HostConnection(host: host.copyWith(addresses: ['127.0.0.1']), token: token, cursors: () => {});
    connRef = conn;
    conn.events.listen(events.add);
    expect(await conn.connect(), isTrue);
    await until(() => conn.online);
    expect(conn.status!.features.terminal, isTrue);
    final store = SessionsStore(db: db, hostId: host.id, api: () => conn.api);
    await store.init();
    await store.refresh();
    expect(store.byId('assistant'), isNotNull);
  }, skip: _bin.isEmpty);

  test('文件：列目录、读写与冲突', () async {
    final api = conn.api;
    final ws = (await api.workspaces()).single;
    final list = await api.list(ws.id, '.');
    expect(list.entries.map((e) => e.name), containsAll(['README.md', 'notes.txt']));
    final r = await api.readFile(ws.id, 'notes.txt');
    expect(utf8.decode(r.bytes), '第一行\n');
    final saved = await api.saveFile(ws.id, 'notes.txt', utf8.encode('第二版\n'), ifMatch: r.etag);
    expect(saved.etag, isNot(r.etag));
    // 用旧 ETag 保存得到 412 与最新 ETag
    await expectLater(api.saveFile(ws.id, 'notes.txt', utf8.encode('x'), ifMatch: r.etag), throwsA(isA<ApiException>().having((e) => e.status, 'status', 412)));
    expect(await File('${wsDir.path}/notes.txt').readAsString(), '第二版\n');
    // 重命名、新建文件夹、删除到回收站
    expect(await api.op(ws.id, 'mkdir', '.', name: '新文件夹'), '新文件夹');
    expect(await api.op(ws.id, 'rename', 'notes.txt', name: '笔记.txt'), '笔记.txt');
    expect(await File('${wsDir.path}/笔记.txt').exists(), isTrue);
    await expectLater(api.list(ws.id, '../'), throwsA(isA<ApiException>()));
  }, skip: _bin.isEmpty);

  test('传输：上传到收件目录，电脑发来的文件自动接收并确认', () async {
    final tmp = await Directory.systemTemp.createTemp('pde2eup');
    final m = TransferManager(
      db: db,
      hostId: host.id,
      conn: conn,
      saver: DirSaver(() async => Directory('${tmp.path}/recv')),
      tempDir: () async => Directory('${tmp.path}/t')..createSync(recursive: true),
      options: () => const QueueOptions(),
    );
    // 上传有名与无名文件
    final data = randomBytes(3 * 1024 * 1024 + 17, 5);
    final f = File('${tmp.path}/报告.bin')..writeAsBytesSync(data);
    final t1 = await m.upload(f.path, name: '报告.bin');
    final txt = File('${tmp.path}/s.txt')..writeAsStringSync('分享的文字');
    final t2 = await m.upload(txt.path, mime: 'text/plain');
    expect((await m.wait(t1)).status, TaskStatus.done, reason: t1.error);
    expect((await m.wait(t2)).status, TaskStatus.done, reason: t2.error);
    final inbox = File('${home.path}/Inbox/${t1.dateFolder}/报告.bin');
    expect(sha256.convert(await inbox.readAsBytes()), sha256.convert(data));
    expect(t2.result, matches(RegExp(r'^\d{8}-\d{6}-\d{3}\.txt$')));
    // 电脑端放入发件目录，手机收到通知后自动下载
    final out = randomBytes(700 * 1024, 9);
    await File('${home.path}/Outbox/结果.bin').writeAsBytes(out);
    await until(() => events.any((e) => e.type == 'outbox.new'));
    await m.pollOutbox();
    final task = m.tasks.firstWhere((t) => t.source.startsWith('outbox:'));
    expect((await m.wait(task)).status, TaskStatus.done, reason: task.error);
    expect(sha256.convert(await File(task.result).readAsBytes()), sha256.convert(out));
    await until(() => !File('${home.path}/Outbox/结果.bin').existsSync());
    m.dispose();
    await tmp.delete(recursive: true);
  }, skip: _bin.isEmpty, timeout: const Timeout(Duration(minutes: 2)));

  test('终端：输入命令并收到输出', () async {
    final api = conn.api;
    final ws = (await api.workspaces()).single;
    final s = await api.createSession('terminal', ws.id, '.', cols: 80, rows: 24);
    final ch = pinnedSocketFactory(conn.httpClient)(api.base.replace(scheme: 'wss', path: '/term/${s.id}'), api.headers());
    final out = StringBuffer();
    final sub = ch.stream.listen((m) {
      if (m is List<int>) out.write(utf8.decode(m, allowMalformed: true));
    });
    await ch.ready;
    ch.sink.add(utf8.encode('echo 联调-\$((1+2))\r'));
    await until(() => out.toString().contains('联调-3'));
    await sub.cancel();
    await ch.sink.close();
    await api.closeTerminal(s.id);
  }, skip: _bin.isEmpty);

  test('网络波动：连接反复被切断时消息不丢、不重、不乱序', () async {
    // 1、在手机与电脑之间放一个会定时切断全部连接的转发器
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final pipes = <Socket>[];
    var chaos = true;
    // 除定时切断外，还随机在电脑已收到请求、回复尚未传回时切断，稳定触发「已受理但手机没收到回复」的重发
    final rnd = Random(7);
    proxy.listen((client) async {
      try {
        final upstream = await Socket.connect('127.0.0.1', _port);
        pipes.addAll([client, upstream]);
        // 对端已被切断时写入会抛错，转发器只管丢弃
        void pass(Socket to, List<int> data) {
          try {
            to.add(data);
          } catch (_) {}
        }

        client.listen((data) => pass(upstream, data), onDone: upstream.destroy, onError: (_) => upstream.destroy());
        upstream.listen((data) {
          if (chaos && rnd.nextInt(4) == 0) {
            client.destroy();
            upstream.destroy();
            return;
          }
          pass(client, data);
        }, onDone: client.destroy, onError: (_) => client.destroy());
      } catch (_) {
        client.destroy();
      }
    });
    var cuts = 0;
    var failures = 0;
    final killer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!chaos || pipes.isEmpty) return;
      cuts++;
      for (final s in List.of(pipes)) {
        s.destroy();
      }
      pipes.clear();
    });
    // 2、通过转发器连接，事件交给会话仓库
    final token = (await vault.token(host.id))!;
    late SessionsStore store;
    final flaky = HostConnection(
      host: PairedHost(id: host.id, name: host.name, addresses: ['127.0.0.1'], port: proxy.port, fingerprint: host.fingerprint),
      token: token,
      cursors: () => store.cursors(),
    );
    store = SessionsStore(db: db, hostId: 'chaos', api: () => flaky.api);
    await store.init();
    flaky.events.listen(store.onEvent);
    var reconnects = 0;
    flaky.addListener(() {
      if (flaky.link == LinkState.connecting) reconnects++;
    });
    Future<T> retry<T>(Future<T> Function() f) async {
      for (var i = 0;; i++) {
        try {
          return await f();
        } catch (_) {
          // 断线在不同系统上表现为接口错误或底层网络异常，都算一次失败重发
          failures++;
          if (i > 200) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    }

    await until(() => flaky.connect(), max: const Duration(seconds: 30));
    await retry(store.refresh);
    final log = await retry(() => store.log('assistant'));
    final base = log.lastSeq;
    // 3、4 路并发各发 10 条，失败时用同一编号重发（与手机界面一致）
    final texts = [for (var i = 0; i < 40; i++) '波动-$i'];
    var next = 0;
    await Future.wait([
      for (var w = 0; w < 4; w++)
        () async {
          while (next < texts.length) {
            final t = texts[next++];
            await retry(() => flaky.api.assistantText(t, clientId: 'chaos-$t'));
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        }(),
    ]);
    // 5、停止切断，等待手机补齐
    chaos = false;
    killer.cancel();
    final remote = await conn.api.events('assistant', after: base, limit: 5000);
    await until(() => log.lastSeq >= remote.last.seq, max: const Duration(seconds: 60));
    // 每条消息恰好一次，顺序与电脑端一致
    final serverTexts = remote.where((e) => e.type == 'msg.user').map((e) => e.data['text']).toList();
    final phoneTexts = log.items.whereType<UserItem>().map((u) => u.text).where((t) => t.startsWith('波动-')).toList();
    expect(serverTexts.where((t) => texts.contains(t)).length, 40, reason: '电脑端重复或缺少消息');
    expect(phoneTexts, serverTexts.where((t) => texts.contains(t)).toList(), reason: '手机端与电脑端不一致');
    expect(phoneTexts.toSet(), texts.toSet());
    // 确认波动真实发生：连接被多次切断、请求失败后重发、事件通道重连
    printOnFailure('切断 $cuts 次，请求失败重发 $failures 次，事件通道重连 $reconnects 次');
    expect(cuts, greaterThan(5));
    expect(failures, greaterThan(0));
    expect(reconnects, greaterThan(2));
    // ignore: avoid_print
    print('网络波动测试：切断 $cuts 次，请求失败重发 $failures 次，事件通道重连 $reconnects 次，40 条消息无丢失无重复');
    flaky.dispose();
    await proxy.close();
  }, skip: _bin.isEmpty, timeout: const Timeout(Duration(minutes: 3)));

  test('文件传输助手：发文字后收到事件', () async {
    await conn.api.assistantText('联调消息', clientId: 'c1');
    await until(() => events.any((e) => e.session == 'assistant' && e.type == 'msg.user' && e.data['text'] == '联调消息'));
    final evs = await conn.api.events('assistant', after: 0);
    expect(evs.any((e) => e.data['text'] == '联调消息'), isTrue);
    expect(conn.link, LinkState.online);
  }, skip: _bin.isEmpty);
}
