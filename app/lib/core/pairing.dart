/**
 * 配对：解析电脑上显示的二维码，按地址顺序连接并核对证书指纹，提交配对码换取设备令牌。
 */
library;

import 'dart:convert';

/** PairTicket：二维码中的配对信息 */
class PairTicket {
  const PairTicket({required this.name, required this.addresses, required this.port, required this.fingerprint, required this.code});

  final String name;
  final List<String> addresses;
  final int port;
  final String fingerprint;
  final String code;

  /**
   * parse：解析 PD1: 开头的二维码内容，格式不对返回 null
   *
   * 处理流程：
   * 1、校验前缀并做 base64url 解码
   * 2、读取电脑名、地址、端口、证书指纹、配对码
   */
  static PairTicket? parse(String raw) {
    // 1、前缀
    final s = raw.trim();
    if (!s.startsWith('PD1:')) return null;
    try {
      final body = s.substring(4);
      final padded = body.padRight(body.length + (4 - body.length % 4) % 4, '=');
      final j = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (j is! Map) return null;
      // 2、字段
      final fp = (j['f'] ?? '').toString().toLowerCase();
      final code = (j['c'] ?? '').toString();
      if (fp.length != 64 || code.isEmpty) return null;
      return PairTicket(
        name: (j['n'] ?? '电脑').toString(),
        addresses: (j['a'] is List ? j['a'] as List : const []).map((e) => e.toString()).toList(),
        port: j['p'] is int ? j['p'] as int : 8443,
        fingerprint: fp,
        code: code,
      );
    } on FormatException {
      return null;
    }
  }
}

/** normalizeCode：去掉分隔符和空格并转大写 */
String normalizeCode(String s) => s.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');

/** formatCode：8 位码格式化为 XXXX-XXXX */
String formatCode(String s) {
  final c = normalizeCode(s);
  return c.length == 8 ? '${c.substring(0, 4)}-${c.substring(4)}' : c;
}
