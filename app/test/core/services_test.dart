/**
 * 核心服务测试：配对流程、生物识别免验证时间、日志脱敏与导出、全局状态（配对后连接、网络变化、局域网发现新地址、解除配对）。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/app_log.dart';
import 'package:pocketdesk/core/app_state.dart';
import 'package:pocketdesk/core/auth_gate.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/device_signals.dart';
import 'package:pocketdesk/core/discovery.dart';
import 'package:pocketdesk/core/pairing.dart';
import 'package:pocketdesk/core/pairing_service.dart';
import 'package:pocketdesk/core/settings.dart';
import 'package:pocketdesk/core/transfer_manager.dart';
import 'package:pocketdesk/core/vault.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local_db_test.dart' show openTestDb;
import '../support/fake_host.dart';

/** FakeAuth：可控的系统验证 */
class FakeAuth implements Authenticator {
  bool supported = true;
  bool pass = true;
  int calls = 0;

  @override
  Future<bool> available() async => supported;

  @override
  Future<bool> authenticate(String reason) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return pass;
  }
}

/** FakeSignals：可控的网络与电量 */
class FakeSignals implements DeviceSignals {
  final ctrl = StreamController<({NetState state, bool networkChanged})>.broadcast();

  @override
  Future<NetState> current() async => const NetState();

  @override
  Stream<({NetState state, bool networkChanged})> changes() => ctrl.stream;
}

/** FakeDiscovery：手动推送发现结果 */
class FakeDiscovery extends Discovery {
  final ctrl = StreamController<Found>.broadcast();

  @override
  Stream<Found> get found => ctrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  late FakeHost host;
  late LocalDb db;
  late MemoryVault vault;

  PairingService service() => PairingService(db: db, vault: vault, deviceName: '我的手机', platform: 'android', clients: (a, s) => HttpClient(), scheme: 'http');

  setUp(() async {
    host = FakeHost();
    await host.start();
    db = await openTestDb();
    vault = MemoryVault();
  });
  tearDown(() async {
    await host.close();
    await db.db.close();
  });

  group('配对', () {
    PairTicket ticket({String? fp, String code = 'K7M29QXA', List<String>? addrs}) =>
        PairTicket(name: '书房', addresses: addrs ?? ['127.0.0.3', '127.0.0.1'], port: host.base.port, fingerprint: fp ?? host.fingerprint, code: code);

    test('扫码配对：跳过不可达地址，保存电脑与令牌', () async {
      final h = await service().pairTicket(ticket());
      expect(h.id, host.fingerprint);
      expect(h.name, '测试电脑');
      expect(h.addresses.first, '127.0.0.1');
      expect(h.addresses, contains('127.0.0.3'));
      expect(h.deviceId, 'dev1');
      expect(await vault.token(h.id), 'tok0');
      expect((await db.hosts()).single.id, h.id);
      // 重新配对覆盖同一台电脑
      await service().pairTicket(ticket());
      expect((await db.hosts()).length, 1);
      expect(await vault.token(h.id), 'tok1');
    });

    test('指纹不一致、配对码错误、全部不可达', () async {
      await expectLater(service().pairTicket(ticket(fp: 'cd' * 32)), throwsA(isA<PairError>().having((e) => e.message, 'm', contains('不一致'))));
      await expectLater(service().pairTicket(ticket(code: 'WRONG')), throwsA(isA<PairError>().having((e) => e.message, 'm', '配对码错误或已过期')));
      await expectLater(service().pairTicket(ticket(addrs: ['127.0.0.3'])), throwsA(isA<PairError>().having((e) => e.message, 'm', contains('连接不到'))));
      await expectLater(service().pairTicket(ticket(addrs: [])), throwsA(isA<PairError>()));
      // 指纹不一致时不保存任何电脑与令牌（HTTPS 下握手即拒绝，由真实电脑端联调覆盖）
      expect(await db.hosts(), isEmpty);
      expect(await vault.token('cd' * 32), isNull);
    });

    test('手动输入配对码：指纹前缀须一致', () async {
      final h = await service().pairManual(ip: '127.0.0.1', port: host.base.port, fpPrefix: host.fingerprint.substring(0, 16), code: 'k7m2-9qxa');
      expect(h.fingerprint, host.fingerprint);
      await expectLater(service().pairManual(ip: '127.0.0.1', port: host.base.port, fpPrefix: 'cd' * 8, code: 'K7M29QXA'), throwsA(isA<PairError>()));
      await expectLater(service().pairManual(ip: '127.0.0.1', port: host.base.port, fpPrefix: 'ab', code: 'K7M29QXA'), throwsA(isA<PairError>()));
    });
  });

  group('生物识别', () {
    test('验证后在免验证时间内不再弹出，过期后重新验证', () async {
      var now = DateTime(2026, 1, 1, 10);
      var grace = 5;
      final auth = FakeAuth();
      final gate = AuthGate(auth: auth, enabled: () => true, graceMinutes: () => grace, clock: () => now);
      final both = await Future.wait([gate.ensure('打开'), gate.ensure('打开')]);
      expect(both, [true, true]);
      expect(auth.calls, 1);
      now = now.add(const Duration(minutes: 4));
      expect(await gate.ensure('终端'), isTrue);
      expect(auth.calls, 1);
      now = now.add(const Duration(minutes: 2));
      auth.pass = false;
      expect(await gate.ensure('终端'), isFalse);
      expect(auth.calls, 2);
      auth.pass = true;
      grace = 0;
      await gate.ensure('x');
      await gate.ensure('x');
      expect(auth.calls, 4);
    });

    test('关闭或设备不支持时放行，锁定后重新验证', () async {
      final auth = FakeAuth()..supported = false;
      var on = false;
      final gate = AuthGate(auth: auth, enabled: () => on, graceMinutes: () => 5);
      expect(await gate.ensure('x'), isTrue);
      on = true;
      expect(await gate.ensure('x'), isTrue);
      expect(auth.calls, 0);
      auth.supported = true;
      expect(await gate.ensure('x'), isTrue);
      expect(gate.fresh, isTrue);
      gate.lock();
      expect(gate.fresh, isFalse);
    });
  });

  group('日志', () {
    test('脱敏', () {
      expect(sanitizeLog('Authorization: Bearer abc.DEF-123'), 'Authorization: Bearer ***');
      expect(sanitizeLog('{"token":"xyz","code": "K7M2"}'), '{"token":"***","code": "***"}');
      expect(sanitizeLog('打开 /Users/alice/proj 与 /home/bob/x'), '打开 /Users/~/proj 与 /home/~/x');
    });

    test('按天写入、保留 7 天并导出', () async {
      final dir = await Directory.systemTemp.createTemp('pdlog');
      var now = DateTime(2026, 3, 1, 8);
      final log = AppLog(dir, clock: () => now);
      await log.write('I', 'a', '第一天 token=abc');
      now = DateTime(2026, 3, 9, 8);
      await log.write('E', 'b', '第九天');
      await log.prune();
      final names = dir.listSync().map((f) => f.uri.pathSegments.last).toList();
      expect(names, ['app-20260309.log']);
      final out = await log.export(dir, header: '手机 token=1');
      final text = await out.readAsString();
      expect(text, contains('手机 token=***'));
      expect(text, contains('E [b] 第九天'));
      expect(text, isNot(contains('第一天')));
      await dir.delete(recursive: true);
    });
  });

  test('设备状态换算', () {
    final s = netStateFrom([ConnectivityResult.mobile], 10, BatteryState.discharging, true);
    expect([s.wifi, s.online, s.lowBattery, s.powerSave], [false, true, true, true]);
    final c = netStateFrom([ConnectivityResult.none], 10, BatteryState.charging, false);
    expect([c.wifi, c.online, c.lowBattery], [false, false, false]);
    expect(netStateFrom([ConnectivityResult.wifi], -1, BatteryState.unknown, false).lowBattery, isFalse);
  });

  group('全局状态', () {
    late Directory tmp;
    late AppSettings settings;
    late FakeSignals signals;
    late FakeDiscovery disc;

    AppState newState() => AppState(
          settings: settings,
          db: db,
          vault: vault,
          paths: AppPaths(temp: Directory('${tmp.path}/t'), received: Directory('${tmp.path}/r')),
          signals: signals,
          connections: (h, t, c) => HostConnection(host: h, token: t, cursors: c, clients: (_) => HttpClient(), scheme: 'http'),
          discovery: () => disc,
        );

    Future<void> until(FutureOr<bool> Function() ok) async {
      final end = DateTime.now().add(const Duration(seconds: 10));
      while (!await ok()) {
        if (DateTime.now().isAfter(end)) throw TimeoutException('条件未满足');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = AppSettings(await SharedPreferences.getInstance());
      tmp = await Directory.systemTemp.createTemp('pdapp');
      signals = FakeSignals();
      disc = FakeDiscovery();
    });
    tearDown(() => tmp.delete(recursive: true));

    test('配对后连接、自动接收、发现新地址、解除配对', () async {
      final app = newState();
      await app.init();
      expect(app.host, isNull);
      host.outbox['o1'] = (name: '结果.txt', data: randomBytes(100));
      final h = await PairingService(db: db, vault: vault, deviceName: 'p', platform: 'android', clients: (a, s) => HttpClient(), scheme: 'http')
          .pairTicket(PairTicket(name: '', addresses: ['127.0.0.3'], port: host.base.port, fingerprint: host.fingerprint, code: 'K7M29QXA').copyWithAddresses(['127.0.0.1']));
      host.hostAddresses = [{'ip': '100.100.7.8', 'kind': 'tailscale'}];
      await app.addHost(h);
      expect(settings.currentHost, h.id);
      final s = app.scope!;
      await until(() => s.conn.online);
      // 连接后记住电脑的 Tailscale 地址，下次不在同一网络也能连
      await until(() => s.conn.host.addresses.contains('100.100.7.8'));
      await until(() async => (await db.hosts()).single.addresses.contains('100.100.7.8'));
      expect(s.conn.host.addresses.first, '127.0.0.1');
      // 手动添加与删除
      expect(await app.addAddress('my-pc.tail1234.ts.net'), isTrue);
      expect(await app.addAddress('my-pc.tail1234.ts.net'), isFalse);
      expect(await app.removeAddress('my-pc.tail1234.ts.net'), isTrue);
      expect((await db.hosts()).single.addresses, isNot(contains('my-pc.tail1234.ts.net')));
      await until(() => host.acked.contains('o1'));
      await until(() => s.transfers.done.isNotEmpty);
      expect(s.transfers.done.single.name, '结果.txt');
      // 局域网发现：同一台电脑的新地址被记录
      disc.ctrl.add(Found(name: 'x', ip: '127.0.0.9', port: host.base.port, fpPrefix: host.fingerprint.substring(0, 16)));
      disc.ctrl.add(Found(name: 'y', ip: '127.0.0.8', port: host.base.port, fpPrefix: 'ff' * 8));
      await until(() => s.conn.host.addresses.contains('127.0.0.9'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await db.hosts()).single.addresses, contains('127.0.0.9'));
      expect(s.conn.host.addresses, isNot(contains('127.0.0.8')));
      // 网络变化转给传输队列
      signals.ctrl.add((state: const NetState(lowBattery: true), networkChanged: false));
      await Future<void>.delayed(Duration.zero);
      expect(s.transfers.blockedReason, '电量低，已暂停');
      // 分享文字（在线直接发送）
      expect(await app.shareFiles(const [], text: '  '), 0);
      // 解除配对
      await app.removeHost(h.id);
      expect(app.host, isNull);
      expect(await vault.token(h.id), isNull);
      expect(settings.currentHost, '');
      app.dispose();
    });

    test('缺少令牌时不连接', () async {
      final h = await service().pairTicket(PairTicket(name: '', addresses: ['127.0.0.1'], port: host.base.port, fingerprint: host.fingerprint, code: 'K7M29QXA'));
      await vault.deleteToken(h.id);
      final app = newState();
      await app.init();
      expect(app.hosts.single.id, h.id);
      expect(app.scope, isNull);
      app.dispose();
    });
  });
}

extension on PairTicket {
  PairTicket copyWithAddresses(List<String> a) => PairTicket(name: name, addresses: a, port: port, fingerprint: fingerprint, code: code);
}
