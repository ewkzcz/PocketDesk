/**
 * 配对流程：扫码或手动输入配对码后，按地址顺序连接电脑、核对证书指纹、提交配对码，成功后保存电脑与设备令牌。
 */
library;

import 'dart:io';

import 'package:http/io_client.dart';

import '../data/local_db.dart';
import '../data/models.dart';
import '../net/api.dart';
import '../net/pinning.dart';
import 'pairing.dart';
import 'vault.dart';

/** PairError：配对失败，message 可直接展示 */
class PairError implements Exception {
  const PairError(this.message);

  final String message;

  @override
  String toString() => message;
}

/** PairClientFactory：创建配对用的 HttpClient；accept 判断对方证书指纹是否可信 */
typedef PairClientFactory = HttpClient Function(bool Function(String fp) accept, void Function(String fp) onSeen);

/**
 * PairingService：执行配对
 */
class PairingService {
  PairingService({required this.db, required this.vault, required this.deviceName, required this.platform, PairClientFactory? clients, this.scheme = 'https'})
      : _clients = clients ?? _defaultClient;

  final LocalDb db;
  final Vault vault;
  final String deviceName;
  final String platform;
  final PairClientFactory _clients;
  final String scheme;

  /** _defaultClient：证书由 accept 判断，不加载系统根证书 */
  static HttpClient _defaultClient(bool Function(String fp) accept, void Function(String fp) onSeen) {
    final c = HttpClient(context: SecurityContext(withTrustedRoots: false))..connectionTimeout = const Duration(seconds: 3);
    c.badCertificateCallback = (cert, host, port) {
      final fp = certFingerprint(cert);
      onSeen(fp);
      return accept(fp);
    };
    return c;
  }

  /**
   * pairTicket：扫码配对，证书指纹必须与二维码完全一致
   */
  Future<PairedHost> pairTicket(PairTicket t) => _pair(
        addresses: t.addresses,
        port: t.port,
        code: t.code,
        accept: (fp) => fp == t.fingerprint,
        name: t.name,
      );

  /**
   * pairManual：手动输入配对码，连接局域网发现的电脑，证书指纹须与广播的前缀一致
   */
  Future<PairedHost> pairManual({required String ip, required int port, required String fpPrefix, required String code, String name = ''}) async {
    final prefix = fpPrefix.toLowerCase();
    if (prefix.length < 16) throw const PairError('没有找到可信的电脑，请改用扫码配对');
    return _pair(addresses: [ip], port: port, code: normalizeCode(code), accept: (fp) => fp.startsWith(prefix), name: name);
  }

  /**
   * _pair：配对主流程
   *
   * 处理流程：
   * 1、按顺序尝试每个地址，读取电脑信息并核对证书指纹
   * 2、提交配对码，等待电脑端确认
   * 3、保存电脑信息（同一台电脑重新配对时覆盖）与令牌
   */
  Future<PairedHost> _pair({required List<String> addresses, required int port, required String code, required bool Function(String fp) accept, required String name}) async {
    if (addresses.isEmpty) throw const PairError('二维码里没有可用的电脑地址');
    PairError? last;
    for (final addr in addresses) {
      var seen = '';
      final api = PdApi(base: Uri(scheme: scheme, host: addr, port: port), client: IOClient(_clients(accept, (fp) => seen = fp)));
      try {
        // 1、握手：未配对时电脑返回 401，但握手成功已说明证书通过了核对
        HostStatus? st;
        try {
          st = await api.host(wait: const Duration(seconds: 4));
        } on ApiException catch (e) {
          if (e.code == 'cert') throw const PairError('电脑证书与二维码不一致，已停止配对');
          if (e.offline) {
            last = const PairError('连接不到电脑，请确认手机和电脑在同一网络');
            continue;
          }
        }
        // HTTPS 下握手时已拿到证书指纹，提交配对码前核对
        if (seen.isNotEmpty && !accept(seen)) throw const PairError('电脑证书与二维码不一致，已停止配对');
        // 2、提交配对码
        final ({String token, String deviceId, String hostName, String fingerprint}) res;
        try {
          res = await api.pair(code, deviceName, platform);
        } on ApiException catch (e) {
          throw PairError(_message(e));
        }
        final fp = (seen.isNotEmpty ? seen : res.fingerprint).toLowerCase();
        if (!accept(fp)) throw const PairError('电脑证书与二维码不一致，已停止配对');
        // 3、配对后读取电脑的全部地址，失败不影响配对结果
        api.token = res.token;
        try {
          st ??= await api.host(wait: const Duration(seconds: 4));
        } on ApiException {
          // 使用二维码中的地址
        }
        final addrs = <String>{addr, ...addresses, ...?st?.addresses.map((a) => a.ip)}.toList();
        final hostName = [res.hostName, st?.name ?? '', name].firstWhere((n) => n.isNotEmpty, orElse: () => '电脑');
        final host = PairedHost(
          id: fp,
          name: hostName,
          addresses: addrs,
          port: port,
          fingerprint: fp,
          deviceId: res.deviceId,
          lastUsed: DateTime.now().millisecondsSinceEpoch,
        );
        await vault.saveToken(host.id, res.token);
        await db.saveHost(host);
        return host;
      } finally {
        api.client.close();
      }
    }
    throw last ?? const PairError('连接不到电脑');
  }

  /** _message：配对错误的提示文字（电脑端返回的提示可直接展示） */
  static String _message(ApiException e) => e.offline ? '和电脑的连接中断，请重试' : e.message;
}
