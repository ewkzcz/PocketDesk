/**
 * 事件通道：WebSocket 连接电脑，连接后按各会话游标补拉缺失事件，25 秒心跳，断线按指数退避重连。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../data/models.dart';

/** 连接状态 */
enum LinkState { connecting, online, offline }

/** SocketFactory：创建连接的函数，测试时可替换 */
typedef SocketFactory = WebSocketChannel Function(Uri uri, Map<String, String> headers);

/** defaultSocketFactory：使用证书固定的 HttpClient 建立连接 */
SocketFactory pinnedSocketFactory(HttpClient Function() client) =>
    (uri, headers) => IOWebSocketChannel.connect(uri, headers: headers, customClient: client(), connectTimeout: const Duration(seconds: 10));

/**
 * EventChannel：一台电脑的事件通道
 */
class EventChannel {
  EventChannel({required this.uri, required this.token, required this.factory, required this.cursors});

  final Uri uri;
  final String token;
  final SocketFactory factory;

  /** 各会话已收到的最后序号，重连时发给电脑补发 */
  final Map<String, int> Function() cursors;

  final _events = StreamController<PdEvent>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _watchdog;
  Timer? _retry;
  int _backoff = 1;
  bool _closed = false;
  LinkState _current = LinkState.offline;

  /** events：会话事件与全局事件 */
  Stream<PdEvent> get events => _events.stream;

  /** states：连接状态变化 */
  Stream<LinkState> get states => _state.stream;

  /** state：当前连接状态 */
  LinkState get state => _current;

  /** 心跳间隔与断线判定时长 */
  static const pingEvery = Duration(seconds: 25);
  static const deadAfter = Duration(seconds: 60);

  /**
   * connect：建立连接
   *
   * 处理流程：
   * 1、创建 WebSocket 并发送 hello（带游标）
   * 2、收到消息时刷新存活计时，ping 立即回应，其余转为事件
   * 3、连接出错或关闭时安排重连
   */
  void connect() {
    if (_closed) return;
    _setState(LinkState.connecting);
    try {
      // 1、连接与 hello
      final ch = factory(uri, {'Authorization': 'Bearer $token'});
      _ch = ch;
      ch.sink.add(jsonEncode({'type': 'hello', 'cursors': cursors()}));
      _armWatchdog();
      // 2、消息
      _sub = ch.stream.listen((raw) {
        _armWatchdog();
        final m = raw is String ? jsonDecode(raw) : null;
        if (m is! Map) return;
        final e = PdEvent.fromJson(m.cast<String, dynamic>());
        switch (e.type) {
          case 'ping':
            _sendRaw({'type': 'pong'});
          case 'pong':
            break;
          case 'ready':
            _backoff = 1;
            _setState(LinkState.online);
            _startPing();
            _events.add(e);
          default:
            _events.add(e);
        }
      }, onError: (_) => _drop(), onDone: _drop, cancelOnError: true);
    } catch (_) {
      _drop();
    }
  }

  /** _sendRaw：发送文本帧 */
  void _sendRaw(Map<String, dynamic> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {
      // 连接已断开，由重连逻辑处理
    }
  }

  /** _startPing：定时心跳 */
  void _startPing() {
    _ping?.cancel();
    _ping = Timer.periodic(pingEvery, (_) => _sendRaw({'type': 'ping'}));
  }

  /** _armWatchdog：60 秒没有任何消息判定断线 */
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(deadAfter, _drop);
  }

  /**
   * _drop：断开并按 1、2、4…30 秒退避重连
   */
  void _drop() {
    _teardown();
    if (_closed) return;
    _setState(LinkState.offline);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), connect);
    _backoff = (_backoff * 2).clamp(1, 30);
  }

  /** reconnectNow：网络切换后立即重连 */
  void reconnectNow() {
    if (_closed) return;
    _retry?.cancel();
    _backoff = 1;
    _teardown();
    connect();
  }

  /** _teardown：释放当前连接 */
  void _teardown() {
    _ping?.cancel();
    _watchdog?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {
      // 忽略关闭错误
    }
    _ch = null;
  }

  /** _setState：更新并广播连接状态 */
  void _setState(LinkState s) {
    if (_current == s) return;
    _current = s;
    if (!_state.isClosed) _state.add(s);
  }

  /** close：永久关闭 */
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _teardown();
    _setState(LinkState.offline);
    await _events.close();
    await _state.close();
  }
}
