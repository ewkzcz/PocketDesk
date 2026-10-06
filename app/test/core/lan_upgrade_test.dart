/**
 * 局域网升级测试：先走 Tailscale，局域网变得可用后自动切过去；局域网一直不通时保持 Tailscale。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/net/api.dart';

import '../support/fake_host.dart';

void main() {
  late FakeHost host;
  late HostConnection conn;
  var lanUp = false;

  setUp(() async {
    host = FakeHost();
    await host.start();
    lanUp = false;
    // 局域网地址在 lanUp 为真之前连不上；Tailscale 地址始终通
    conn = HostConnection(
      host: PairedHost(id: 'h', name: '电脑', addresses: ['192.168.242.190', '100.64.0.9'], port: host.base.port, fingerprint: ''),
      token: 'tk',
      cursors: () => {},
      clients: (_) => HttpClient(),
      scheme: 'http',
      apis: (base, token) {
        final up = base.host == '100.64.0.9' || lanUp;
        return PdApi(base: up ? host.base : Uri.parse('http://127.0.0.1:1'), client: IOClient(HttpClient()), token: token);
      },
    )..lanUpgradeEvery = const Duration(milliseconds: 100);
  });
  tearDown(() async {
    conn.dispose();
    await host.close();
  });

  Future<void> until(bool Function() ok) async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) throw TimeoutException('条件未满足');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('局域网不通时保持 Tailscale，通了之后自动切到局域网', () async {
    expect(await conn.connect(), isTrue);
    expect(conn.address, '100.64.0.9');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(conn.address, '100.64.0.9');
    lanUp = true;
    await until(() => conn.address == '192.168.242.190');
    expect(conn.kindLabel, '局域网');
  });

  test('手动选定地址时不自动切换', () async {
    conn.manualAddress = '100.64.0.9';
    expect(await conn.connect(), isTrue);
    lanUp = true;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(conn.address, '100.64.0.9');
  });
}
