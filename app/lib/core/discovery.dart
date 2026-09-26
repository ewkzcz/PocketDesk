/**
 * 局域网发现：通过 mDNS 查找 _pocketdesk._tcp 服务，电脑 IP 变化后也能找到。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

/** Found：发现的一台电脑 */
class Found {
  const Found({required this.name, required this.ip, required this.port, required this.fpPrefix});

  final String name;
  final String ip;
  final int port;

  /** 证书指纹前 16 位，用于和已配对电脑比对 */
  final String fpPrefix;
}

/**
 * Discovery：启动一次发现，持续回调找到的电脑，调用 stop 结束
 */
class Discovery {
  nsd.Discovery? _d;
  final _found = StreamController<Found>.broadcast();

  /** found：发现结果 */
  Stream<Found> get found => _found.stream;

  /**
   * start：开始发现
   *
   * 处理流程：
   * 1、启动系统 mDNS 发现并解析 IPv4 地址
   * 2、每发现一个服务就读取 TXT 中的指纹前缀并回调
   */
  Future<void> start() async {
    try {
      // 1、启动
      final d = await nsd.startDiscovery('_pocketdesk._tcp', ipLookupType: nsd.IpLookupType.v4);
      _d = d;
      // 2、回调
      void emit() {
        for (final s in d.services) {
          final ip = s.addresses?.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => s.addresses!.first).address;
          if (ip == null || s.port == null) continue;
          final fp = s.txt?['fp'];
          _found.add(Found(name: s.name ?? '电脑', ip: ip, port: s.port!, fpPrefix: fp == null ? '' : utf8.decode(fp)));
        }
      }

      d.addListener(emit);
      emit();
    } catch (_) {
      // 没有本地网络权限或平台不支持时静默失败，仍可扫码或走 Tailscale
    }
  }

  /** stop：结束发现 */
  Future<void> stop() async {
    final d = _d;
    _d = null;
    if (d != null) {
      try {
        await nsd.stopDiscovery(d);
      } catch (_) {
        // 忽略
      }
    }
    await _found.close();
  }
}
