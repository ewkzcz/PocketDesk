/**
 * 事件通道与证书固定测试：hello 携带游标、ready 后在线、事件转发、断线重连、关闭后不再重连；指纹不一致拒绝连接。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/net/api.dart';
import 'package:pocketdesk/net/events.dart';
import 'package:pocketdesk/net/pinning.dart';

import '../support/fake_host.dart';
import '../support/test_cert.dart';

void main() {
  group('事件通道', () {
    late FakeHost host;
    setUp(() async {
      host = FakeHost();
      await host.start();
    });
    tearDown(() => host.close());

    test('连接、游标、事件转发与断线重连', () async {
      var cursors = {'s1': 5};
      final ch = EventChannel(
        uri: host.base.replace(scheme: 'ws', path: '/ws'),
        token: 'tk',
        cursors: () => cursors,
        factory: pinnedSocketFactory(HttpClient.new),
      );
      final states = <LinkState>[];
      final events = <PdEvent>[];
      ch.states.listen(states.add);
      ch.events.listen(events.add);
      ch.connect();
      await ch.states.firstWhere((s) => s == LinkState.online);
      expect(host.received.first, {'type': 'hello', 'cursors': {'s1': 5}});
      host.push({'session': 's1', 'seq': 6, 'type': 'msg.user', 'data': {'text': '嗨'}});
      host.push({'type': 'ping'});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events.map((e) => e.type), ['ready', 'msg.user']);
      expect(host.received.last, {'type': 'pong'});
      // 断线后 1 秒重连，带上新的游标
      cursors = {'s1': 6};
      await host.dropSockets();
      await ch.states.firstWhere((s) => s == LinkState.offline);
      await ch.states.firstWhere((s) => s == LinkState.online).timeout(const Duration(seconds: 5));
      expect(host.received.where((m) => m['type'] == 'hello').last['cursors'], {'s1': 6});
      expect(states, containsAllInOrder([LinkState.connecting, LinkState.online, LinkState.offline, LinkState.connecting, LinkState.online]));
      await ch.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(host.sockets, isEmpty);
    });

    test('连不上时标记离线，关闭后不再重连', () async {
      final ch = EventChannel(
        uri: Uri.parse('ws://127.0.0.1:1/ws'),
        token: '',
        cursors: () => {},
        factory: (uri, h) => throw const SocketException('down'),
      );
      ch.connect();
      expect(ch.state, LinkState.offline);
      await ch.close();
    });
  });

  group('证书固定', () {
    late HttpServer server;
    setUp(() async {
      final ctx = SecurityContext()
        ..useCertificateChainBytes(utf8.encode(testCertPem))
        ..usePrivateKeyBytes(utf8.encode(testKeyPem));
      server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
      server.listen((req) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'name': '电脑'}))
          ..close();
      });
    });
    tearDown(() => server.close(force: true));

    test('指纹一致放行，不一致拒绝', () async {
      final base = Uri.parse('https://127.0.0.1:${server.port}');
      String? seen;
      final ok = PdApi(base: base, client: IOClient(pinnedHttpClient(testCertFingerprint.toUpperCase(), onSeen: (fp) => seen = fp)));
      expect((await ok.host()).name, '电脑');
      expect(seen, testCertFingerprint);
      final bad = PdApi(base: base, client: IOClient(pinnedHttpClient('0' * 64)));
      await expectLater(bad.host(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'cert')));
      final empty = PdApi(base: base, client: IOClient(pinnedHttpClient('')));
      await expectLater(empty.host(), throwsA(isA<ApiException>()));
    });
  });
}
