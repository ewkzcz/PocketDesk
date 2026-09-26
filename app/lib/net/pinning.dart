/**
 * 证书固定：只信任与配对时一致的电脑证书指纹，任何其他证书一律拒绝。
 */
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

/** certFingerprint：证书 DER 的 SHA-256 十六进制小写 */
String certFingerprint(X509Certificate cert) => sha256.convert(cert.der).toString();

/**
 * pinnedHttpClient：创建只接受指定指纹证书的 HttpClient
 *
 * 处理流程：
 * 1、不加载系统根证书，保证每次握手都进入回调校验
 * 2、回调中比对证书指纹，一致才放行
 * 3、onSeen 可拿到对方证书指纹（首次配对时用于核对二维码）
 */
HttpClient pinnedHttpClient(String fingerprint, {void Function(String fp)? onSeen, Duration timeout = const Duration(seconds: 10)}) {
  // 1、空信任列表
  final ctx = SecurityContext(withTrustedRoots: false);
  final client = HttpClient(context: ctx)
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 8;
  // 2、3、指纹比对
  client.badCertificateCallback = (cert, host, port) {
    final fp = certFingerprint(cert);
    onSeen?.call(fp);
    return fingerprint.isNotEmpty && fp == fingerprint.toLowerCase();
  };
  return client;
}
