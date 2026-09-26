/**
 * 配对与地址测试：二维码解析、配对码格式化、Tailscale 地址识别。
 */
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/pairing.dart';

String ticket(Map<String, dynamic> j) => 'PD1:${base64Url.encode(utf8.encode(jsonEncode(j))).replaceAll('=', '')}';

void main() {
  test('解析二维码', () {
    final fp = 'AB' * 32;
    final t = PairTicket.parse(ticket({'v': 1, 'n': '书房电脑', 'a': ['192.168.1.5', '100.100.1.2'], 'p': 9443, 'f': fp, 'c': 'K7M29QXA'}))!;
    expect(t.name, '书房电脑');
    expect(t.addresses, ['192.168.1.5', '100.100.1.2']);
    expect(t.port, 9443);
    expect(t.fingerprint, fp.toLowerCase());
    expect(t.code, 'K7M29QXA');
    final d = PairTicket.parse(' ${ticket({'f': 'a' * 64, 'c': 'X'})} ')!;
    expect(d.port, 8443);
    expect(d.name, '电脑');
    expect(d.addresses, isEmpty);
  });

  test('非法二维码返回空', () {
    expect(PairTicket.parse('https://example.com'), isNull);
    expect(PairTicket.parse('PD1:!!!'), isNull);
    expect(PairTicket.parse(ticket({'f': 'short', 'c': 'X'})), isNull);
    expect(PairTicket.parse(ticket({'f': 'a' * 64})), isNull);
    expect(PairTicket.parse('PD1:${base64Url.encode(utf8.encode('[1]'))}'), isNull);
  });

  test('配对码格式化', () {
    expect(normalizeCode(' k7m2-9qxa '), 'K7M29QXA');
    expect(formatCode('k7m29qxa'), 'K7M2-9QXA');
    expect(formatCode('abc'), 'ABC');
  });

  test('识别 Tailscale 地址', () {
    expect(isTailscale('100.64.0.1'), isTrue);
    expect(isTailscale('100.127.255.1'), isTrue);
    expect(isTailscale('100.128.0.1'), isFalse);
    expect(isTailscale('192.168.1.5'), isFalse);
    expect(isTailscale('fd7a:115c:a1e0::1'), isTrue);
    expect(isTailscale('fe80::1'), isFalse);
    expect(isTailscale('desk.tail1234.ts.net'), isTrue);
  });
}
