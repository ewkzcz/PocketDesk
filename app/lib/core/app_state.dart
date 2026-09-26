/**
 * 全局状态：已配对电脑列表与当前电脑，把连接、会话、传输、网络电量变化与局域网发现串联起来。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/local_db.dart';
import '../data/models.dart';
import '../net/events.dart';
import 'app_log.dart';
import 'connection.dart';
import 'device_signals.dart';
import 'discovery.dart';
import 'sessions_store.dart';
import 'settings.dart';
import 'transfer_manager.dart';
import 'vault.dart';

/** AppPaths：本地目录 */
class AppPaths {
  const AppPaths({required this.temp, required this.received});

  /** 下载中的临时文件 */
  final Directory temp;

  /** 收到的文件（按日期分文件夹） */
  final Directory received;
}

/** ConnectionFactory：创建连接，测试时替换 */
typedef ConnectionFactory = HostConnection Function(PairedHost host, String token, Map<String, int> Function() cursors);

/** DiscoveryFactory：创建局域网发现，测试时替换 */
typedef DiscoveryFactory = Discovery Function();

/**
 * HostScope：当前电脑的连接、会话与传输
 */
class HostScope {
  HostScope(this.host, this.conn, this.sessions, this.transfers);

  final PairedHost host;
  final HostConnection conn;
  final SessionsStore sessions;
  final TransferManager transfers;
  final List<StreamSubscription<dynamic>> subs = [];
  LinkState lastLink = LinkState.offline;

  /** dispose：释放 */
  void dispose() {
    for (final s in subs) {
      s.cancel();
    }
    transfers.dispose();
    sessions.dispose();
    conn.dispose();
  }
}

/**
 * AppState：全局状态
 */
class AppState extends ChangeNotifier {
  AppState({
    required this.settings,
    required this.db,
    required this.vault,
    required this.paths,
    required this.signals,
    ConnectionFactory? connections,
    DiscoveryFactory? discovery,
  })  : _connections = connections ?? ((h, t, c) => HostConnection(host: h, token: t, cursors: c)),
        _discovery = discovery ?? Discovery.new;

  final AppSettings settings;
  final LocalDb db;
  final Vault vault;
  final AppPaths paths;
  final DeviceSignals signals;
  final ConnectionFactory _connections;
  final DiscoveryFactory _discovery;

  List<PairedHost> hosts = [];
  HostScope? scope;
  NetState net = const NetState();
  bool ready = false;
  StreamSubscription<({NetState state, bool networkChanged})>? _signalSub;
  Discovery? _disc;

  /** 当前电脑（未配对时为空） */
  PairedHost? get host => scope?.host;

  /**
   * init：读取已配对电脑并连接上次使用的那台
   */
  Future<void> init() async {
    hosts = await db.hosts();
    net = await signals.current();
    _signalSub = signals.changes().listen(_onSignal);
    final pick = hosts.where((h) => h.id == settings.currentHost).firstOrNull ?? hosts.firstOrNull;
    if (pick != null) await _open(pick);
    ready = true;
    notifyListeners();
  }

  /** _options：传输设置 */
  QueueOptions _options() => QueueOptions(
        concurrency: settings.concurrency,
        wifiOnly: settings.wifiOnly,
        pauseOnLowBattery: settings.pauseOnLowBattery,
        autoReceive: settings.autoReceive,
      );

  /**
   * _open：打开一台电脑
   *
   * 处理流程：
   * 1、读取令牌（没有令牌视为需要重新配对）
   * 2、创建连接、会话仓库与传输队列并恢复本地数据
   * 3、订阅事件与连接状态，开始连接并启动局域网发现
   */
  Future<void> _open(PairedHost h) async {
    scope?.dispose();
    scope = null;
    // 1、令牌
    final token = await vault.token(h.id);
    if (token == null || token.isEmpty) {
      AppLog.w('app', '电脑 ${h.name} 缺少令牌');
      notifyListeners();
      return;
    }
    // 2、创建
    late final SessionsStore sessions;
    final conn = _connections(h, token, () => sessions.cursors());
    sessions = SessionsStore(db: db, hostId: h.id, api: () => conn.api);
    final transfers = TransferManager(
      db: db,
      hostId: h.id,
      conn: conn,
      saver: DirSaver(() async => paths.received),
      tempDir: () async => paths.temp.create(recursive: true),
      options: _options,
    );
    final s = HostScope(h, conn, sessions, transfers);
    scope = s;
    settings.currentHost = h.id;
    await sessions.init();
    transfers.net = net;
    await transfers.load();
    // 3、订阅与连接
    s.subs.add(conn.events.listen((e) => _onEvent(s, e)));
    conn.addListener(() => _onConn(s));
    unawaited(conn.connect());
    unawaited(_discover(s));
    notifyListeners();
  }

  /** _onEvent：分发实时事件 */
  void _onEvent(HostScope s, PdEvent e) {
    s.sessions.onEvent(e);
    switch (e.type) {
      case 'outbox.new':
        unawaited(s.transfers.pollOutbox());
      case 'host.status':
        unawaited(s.conn.refreshStatus());
    }
  }

  /** _onConn：连接状态变化，上线后刷新会话并恢复传输 */
  void _onConn(HostScope s) {
    if (scope != s) return;
    final link = s.conn.link;
    if (link != s.lastLink) {
      s.lastLink = link;
      if (link == LinkState.online) {
        AppLog.i('conn', '已连接 ${s.conn.kindLabel}');
        unawaited(s.sessions.refresh().catchError((Object _) {}));
        s.transfers.onConnected();
      }
    }
    s.transfers.pump();
    notifyListeners();
  }

  /** _onSignal：网络或电量变化 */
  void _onSignal(({NetState state, bool networkChanged}) x) {
    net = x.state;
    final s = scope;
    if (s != null) {
      s.transfers.setNet(x.state);
      if (x.networkChanged && x.state.online) unawaited(s.conn.networkChanged());
    }
    notifyListeners();
  }

  /**
   * _discover：局域网发现，电脑 IP 变化后自动加入新地址
   */
  Future<void> _discover(HostScope s) async {
    await _disc?.stop();
    final d = _discovery();
    _disc = d;
    final prefix = s.host.fingerprint.length >= 16 ? s.host.fingerprint.substring(0, 16) : s.host.fingerprint;
    s.subs.add(d.found.listen((f) async {
      if (scope != s || f.fpPrefix.toLowerCase() != prefix || f.port != s.host.port) return;
      if (s.conn.addAddress(f.ip)) {
        await db.saveHost(s.conn.host);
        if (!s.conn.online) unawaited(s.conn.networkChanged());
      }
    }));
    await d.start();
  }

  /** onResume：回到前台后立即检查连接 */
  void onResume() {
    final s = scope;
    if (s == null) return;
    unawaited(s.conn.networkChanged());
    unawaited(s.transfers.pollOutbox());
  }

  /** settingsChanged：传输设置变化后重新调度 */
  void settingsChanged() => scope?.transfers.setNet(net);

  /** addHost：配对成功后切换到新电脑 */
  Future<void> addHost(PairedHost h) async {
    hosts = await db.hosts();
    await _open(h);
  }

  /** switchHost：切换当前电脑 */
  Future<void> switchHost(String id) async {
    final h = hosts.where((x) => x.id == id).firstOrNull;
    if (h == null || h.id == host?.id) return;
    await _open(h);
  }

  /**
   * removeHost：解除配对，删除本地数据与令牌
   */
  Future<void> removeHost(String id) async {
    if (host?.id == id) {
      scope?.dispose();
      scope = null;
      await _disc?.stop();
      _disc = null;
    }
    await vault.deleteToken(id);
    await db.deleteHost(id);
    hosts = await db.hosts();
    if (scope == null && hosts.isNotEmpty) {
      await _open(hosts.first);
    } else if (hosts.isEmpty) {
      settings.currentHost = '';
    }
    notifyListeners();
  }

  /** shareFiles：系统分享进来的文件发到文件传输助手 */
  Future<int> shareFiles(List<({String path, String mime})> files, {String text = ''}) async {
    final s = scope;
    if (s == null) return 0;
    var n = 0;
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      await s.transfers.upload(f.path, name: name, mime: f.mime, target: 'assistant');
      n++;
    }
    if (text.trim().isNotEmpty) {
      try {
        await s.conn.api.assistantText(text.trim());
        n++;
      } catch (e) {
        // 离线时存为无名文本文件进入传输队列，由电脑端按时间戳命名
        AppLog.w('share', '分享文字改为文件发送：$e');
        await paths.temp.create(recursive: true);
        final f = File('${paths.temp.path}${Platform.pathSeparator}share-${DateTime.now().microsecondsSinceEpoch}.txt');
        await f.writeAsString(text.trim());
        await s.transfers.upload(f.path, mime: 'text/plain', target: 'assistant');
        n++;
      }
    }
    return n;
  }

  @override
  void dispose() {
    _signalSub?.cancel();
    unawaited(_disc?.stop());
    scope?.dispose();
    super.dispose();
  }
}
