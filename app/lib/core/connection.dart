/**
 * 连接管理：按「局域网 → Tailscale」顺序探测电脑的各个地址，选延迟最低的可用地址，网络变化后自动重连。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/io_client.dart';

import '../data/models.dart';
import '../net/api.dart';
import '../net/events.dart';
import '../net/pinning.dart';
import '../transfer/tus.dart';
import 'safe_notifier.dart';

/** isTailscale：是否为 Tailscale 地址（100.64.0.0/10 或 fd7a:115c:a1e0::/48） */
bool isTailscale(String ip) {
  final a = InternetAddress.tryParse(ip);
  if (a == null) return ip.endsWith('.ts.net');
  if (a.type == InternetAddressType.IPv4) {
    final b = a.rawAddress;
    return b[0] == 100 && (b[1] & 0xC0) == 64;
  }
  return ip.toLowerCase().startsWith('fd7a:115c:a1e0');
}

/** Probe：一次探测结果 */
class Probe {
  const Probe(this.address, this.latency, this.status);

  final String address;
  final Duration latency;
  final HostStatus status;
}

/** ClientFactory：按指纹创建证书固定的 HttpClient，测试时可替换 */
typedef ClientFactory = HttpClient Function(String fingerprint);

/** ApiFactory：按地址创建接口客户端，测试时可替换 */
typedef ApiFactory = PdApi Function(Uri base, String token);

/**
 * HostConnection：与一台电脑的连接
 */
class HostConnection extends ChangeNotifier with SafeNotifier {
  HostConnection({
    required this.host,
    required this.token,
    required this.cursors,
    ClientFactory? clients,
    this.sockets,
    this.apis,
    this.scheme = 'https',
  })  : _clients = clients ?? ((fp) => pinnedHttpClient(fp));

  PairedHost host;
  final String token;
  final Map<String, int> Function() cursors;
  final ClientFactory _clients;

  /** 测试时替换 WebSocket 创建方式 */
  final SocketFactory? sockets;

  /** 测试时替换接口客户端 */
  final ApiFactory? apis;
  final String scheme;

  PdApi? _api;
  EventChannel? _events;
  StreamSubscription<LinkState>? _stateSub;
  HostStatus? status;
  String address = '';
  Duration latency = Duration.zero;
  LinkState link = LinkState.offline;
  bool probing = false;
  String lastError = '';
  Timer? _reprobe;
  final _eventsOut = StreamController<PdEvent>.broadcast();
  StreamSubscription<PdEvent>? _eventSub;

  /** api：当前可用的接口客户端（未连接时抛错） */
  PdApi get api {
    final a = _api;
    if (a == null) throw ApiException(0, 'offline', '电脑不在线');
    return a;
  }

  /** hasApi：是否已选定地址 */
  bool get hasApi => _api != null;

  /** events：事件流（跨重连保持同一个流） */
  Stream<PdEvent> get events => _eventsOut.stream;

  /** send：通过实时连接向电脑发消息 */
  void send(Map<String, dynamic> m) => _events?.send(m);

  /** online：事件通道已连通 */
  bool get online => link == LinkState.online;

  /** kindLabel：连接方式 */
  String get kindLabel => address.isEmpty ? '' : (isTailscale(address) ? 'Tailscale' : '局域网');

  /** baseFor：某地址的服务地址 */
  Uri baseFor(String addr) => Uri(scheme: scheme, host: addr, port: host.port);

  /** newApi：为某地址创建接口客户端 */
  PdApi newApi(String addr) => apis?.call(baseFor(addr), token) ?? PdApi(base: baseFor(addr), client: IOClient(_clients(host.fingerprint)), token: token);

  /** tus：当前地址的上传客户端 */
  TusClient tus() => TusClient(base: api.base, token: token, client: _clients(host.fingerprint));

  /** httpClient：下载使用的 HttpClient */
  HttpClient httpClient() => _clients(host.fingerprint);

  /**
   * probeAll：并行探测全部地址
   *
   * 处理流程：
   * 1、每个地址请求 /api/host，3 秒超时
   * 2、局域网地址优先，同类地址中选延迟最低的
   */
  Future<Probe?> probeAll() async {
    // 1、探测
    final results = await Future.wait(host.addresses.map((addr) async {
      final a = newApi(addr);
      final sw = Stopwatch()..start();
      try {
        final st = await a.host(wait: const Duration(seconds: 3));
        return Probe(addr, sw.elapsed, st);
      } on ApiException catch (e) {
        if (e.status == 401) lastError = '这台手机已被电脑端吊销，请重新配对';
        if (e.code == 'cert') lastError = '电脑证书与配对时不一致，已拒绝连接';
        return null;
      } finally {
        a.client.close();
      }
    }));
    // 2、选择
    final ok = results.whereType<Probe>().toList();
    if (ok.isEmpty) return null;
    ok.sort((a, b) {
      final ta = isTailscale(a.address) ? 1 : 0;
      final tb = isTailscale(b.address) ? 1 : 0;
      if (ta != tb) return ta - tb;
      return a.latency.compareTo(b.latency);
    });
    return ok.first;
  }

  /**
   * connect：选择地址并建立事件通道，失败时 15 秒后再试
   */
  Future<bool> connect() async {
    if (disposed) return false;
    if (probing) return hasApi;
    probing = true;
    lastError = '';
    notifyListeners();
    try {
      final p = await probeAll();
      if (disposed) return false;
      if (p == null) {
        if (lastError.isEmpty) lastError = '电脑不在线';
        _scheduleReprobe();
        return false;
      }
      _use(p);
      return true;
    } finally {
      probing = false;
      notifyListeners();
    }
  }

  /** _use：切换到探测到的地址 */
  void _use(Probe p) {
    final changed = p.address != address;
    address = p.address;
    latency = p.latency;
    status = p.status;
    if (changed || _api == null) {
      _api?.client.close();
      _api = newApi(p.address);
      _openEvents();
    }
  }

  /** _openEvents：建立事件通道，把事件转发到统一的事件流 */
  void _openEvents() {
    _stateSub?.cancel();
    _eventSub?.cancel();
    _events?.close();
    final wsUri = baseFor(address).replace(scheme: scheme == 'https' ? 'wss' : 'ws', path: '/ws');
    final ch = EventChannel(uri: wsUri, token: token, cursors: cursors, factory: sockets ?? pinnedSocketFactory(() => _clients(host.fingerprint)));
    _events = ch;
    _stateSub = ch.states.listen((s) {
      link = s;
      notifyListeners();
      if (s == LinkState.offline) _scheduleReprobe();
    });
    _eventSub = ch.events.listen(_eventsOut.add);
    ch.connect();
  }

  /** _scheduleReprobe：离线时定期重新探测（地址可能已变化） */
  void _scheduleReprobe() {
    _reprobe?.cancel();
    _reprobe = Timer(const Duration(seconds: 15), () async {
      if (disposed) return;
      final p = await probeAll();
      if (disposed) return;
      if (p != null && p.address != address) {
        _use(p);
        notifyListeners();
      } else if (p == null) {
        _scheduleReprobe();
      }
    });
  }

  /** networkChanged：网络切换后立即重新探测并重连 */
  Future<void> networkChanged() async {
    if (disposed) return;
    final p = await probeAll();
    if (p != null && !disposed) {
      _use(p);
      _events?.reconnectNow();
      notifyListeners();
    }
  }

  /** refreshStatus：重新读取电脑信息（功能开关、Agent） */
  Future<void> refreshStatus() async {
    if (_api == null || disposed) return;
    try {
      status = await api.host();
      notifyListeners();
    } on ApiException {
      // 离线时保持旧信息
    }
  }

  /** debugOnline：测试时直接标记为已连接（不建立事件通道） */
  @visibleForTesting
  void debugOnline(String addr, HostStatus st, {Duration latency = const Duration(milliseconds: 12)}) {
    address = addr;
    status = st;
    this.latency = latency;
    _api = newApi(addr);
    link = LinkState.online;
    notifyListeners();
  }

  /** addAddress：加入新的候选地址（局域网发现的放最前，其余追加在后），已有时返回 false */
  bool addAddress(String ip, {bool front = true}) {
    final a = ip.trim();
    if (a.isEmpty || host.addresses.contains(a)) return false;
    host = host.copyWith(addresses: front ? [a, ...host.addresses] : [...host.addresses, a]);
    return true;
  }

  /** removeAddress：删除一个候选地址（至少保留一个） */
  bool removeAddress(String ip) {
    if (!host.addresses.contains(ip) || host.addresses.length <= 1) return false;
    host = host.copyWith(addresses: host.addresses.where((a) => a != ip).toList());
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _reprobe?.cancel();
    _stateSub?.cancel();
    _eventSub?.cancel();
    _events?.close();
    _api?.client.close();
    _eventsOut.close();
    super.dispose();
  }
}
