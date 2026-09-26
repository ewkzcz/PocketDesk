/**
 * 终端页：连接电脑上的终端会话，重连后回放画面；键盘上方快捷键栏（Ctrl、Alt 为粘滞键）、底部命令输入行、双指缩放字号、复制粘贴、快捷启动。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../core/app_log.dart';
import '../../core/app_state.dart';
import '../../net/api.dart';
import '../../net/events.dart';
import '../terminal_theme.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'session_actions.dart';

/** 快捷键 */
enum _Key { esc, tab, ctrl, alt, up, down, left, right, home, end, pgUp, pgDn, pipe, tilde, slash }

const _keyLabels = {
  _Key.esc: 'Esc', _Key.tab: 'Tab', _Key.ctrl: 'Ctrl', _Key.alt: 'Alt', _Key.up: '↑', _Key.down: '↓', _Key.left: '←', _Key.right: '→', //
  _Key.home: 'Home', _Key.end: 'End', _Key.pgUp: 'PgUp', _Key.pgDn: 'PgDn', _Key.pipe: '|', _Key.tilde: '~', _Key.slash: '/',
};

/** 终端连接状态 */
enum _Link { connecting, online, offline, exited }

/**
 * TerminalPage：终端
 */
class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key, required this.sessionId, this.socketFactory});

  final String sessionId;

  /** 测试时替换 WebSocket 创建方式 */
  final SocketFactory? socketFactory;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  Terminal _term = Terminal(maxLines: 10000);
  final _ctrl = TerminalController();
  final _input = TextEditingController();
  final _termFocus = FocusNode();
  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _ping;
  Timer? _retry;
  int _backoff = 1;
  _Link _link = _Link.connecting;
  bool _ctrlOn = false;
  bool _altOn = false;
  double _font = 13;
  bool _disposed = false;
  final Map<int, Offset> _pointers = {};
  double? _pinchStart;
  double _fontStart = 13;
  late ByteConversionSink _decoder;
  (int, int) _size = (80, 24);

  HostScope? get _scope => context.read<AppState>().scope;

  @override
  void initState() {
    super.initState();
    _connect();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    _retry?.cancel();
    _input.dispose();
    _termFocus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  /** _setupTerminal：新建终端实例（重连时电脑会回放整屏，需要从空白开始） */
  void _setupTerminal() {
    _term = Terminal(maxLines: 10000);
    _term.onOutput = _onOutput;
    _term.onResize = (w, h, _, _) {
      _size = (w, h);
      _sendJson({'type': 'resize', 'cols': w, 'rows': h});
    };
    // 输出按 UTF-8 流式解码，避免多字节字符被分包截断
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_StringSink((s) => _term.write(s)));
  }

  /**
   * _connect：连接终端通道
   *
   * 处理流程：
   * 1、建立 WebSocket，先收到回放的历史输出，再接实时输出
   * 2、二进制帧为终端输出；文本帧为 ping、exit 等控制消息
   * 3、断开后按 1、2、4…30 秒重连
   */
  void _connect() {
    final scope = _scope;
    if (scope == null || _disposed) return;
    setState(() => _link = _Link.connecting);
    try {
      // 1、连接
      final base = scope.conn.api.base;
      final uri = base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/term/${widget.sessionId}');
      final factory = widget.socketFactory ?? pinnedSocketFactory(scope.conn.httpClient);
      final ch = factory(uri, {'Authorization': 'Bearer ${scope.conn.api.token}'});
      _ch = ch;
      _setupTerminal();
      unawaited(ch.ready.then((_) {
        if (_disposed) return;
        _backoff = 1;
        setState(() => _link = _Link.online);
        _sendJson({'type': 'resize', 'cols': _size.$1, 'rows': _size.$2});
      }, onError: (Object _) {}));
      // 2、消息
      _sub = ch.stream.listen((m) {
        if (m is List<int>) {
          _decoder.add(m);
          return;
        }
        final j = jsonDecode(m as String);
        if (j is! Map) return;
        switch (j['type']) {
          case 'ping':
            _sendJson({'type': 'pong'});
          case 'exit':
            setState(() => _link = _Link.exited);
        }
      }, onError: (_) => _drop(), onDone: _drop, cancelOnError: true);
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) => _sendJson({'type': 'ping'}));
    } on ApiException {
      _drop();
    } catch (e) {
      AppLog.w('term', '连接失败：$e');
      _drop();
    }
  }

  /** _drop：断开后安排重连（终端已结束时不再重连） */
  void _drop() {
    _teardown();
    if (_disposed || _link == _Link.exited) return;
    setState(() => _link = _Link.offline);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = math.min(_backoff * 2, 30);
  }

  void _teardown() {
    _ping?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {
      // 忽略
    }
    _ch = null;
  }

  void _sendJson(Map<String, Object> m) {
    try {
      _ch?.sink.add(jsonEncode(m));
    } catch (_) {
      // 连接已断开
    }
  }

  /** _sendBytes：把输入发给电脑 */
  void _sendBytes(String s) {
    if (_ch == null || _link != _Link.online) return;
    try {
      _ch!.sink.add(utf8.encode(s));
    } catch (_) {
      // 连接已断开
    }
  }

  /** _onOutput：终端产生的输入（键盘），应用粘滞的 Ctrl、Alt */
  void _onOutput(String data) {
    var s = data;
    if ((_ctrlOn || _altOn) && s.length == 1) {
      if (_ctrlOn) {
        final code = s.toUpperCase().codeUnitAt(0);
        if (code >= 0x40 && code <= 0x5F) s = String.fromCharCode(code & 0x1F);
      }
      if (_altOn) s = '\x1b$s';
      setState(() {
        _ctrlOn = false;
        _altOn = false;
      });
    }
    _sendBytes(s);
  }

  /** _key：快捷键栏 */
  void _key(_Key k) {
    unawaited(HapticFeedback.selectionClick());
    switch (k) {
      case _Key.ctrl:
        setState(() => _ctrlOn = !_ctrlOn);
        return;
      case _Key.alt:
        setState(() => _altOn = !_altOn);
        return;
      case _Key.pipe || _Key.tilde || _Key.slash:
        _onOutput(_keyLabels[k]!);
        return;
      default:
        final key = switch (k) {
          _Key.esc => TerminalKey.escape,
          _Key.tab => TerminalKey.tab,
          _Key.up => TerminalKey.arrowUp,
          _Key.down => TerminalKey.arrowDown,
          _Key.left => TerminalKey.arrowLeft,
          _Key.right => TerminalKey.arrowRight,
          _Key.home => TerminalKey.home,
          _Key.end => TerminalKey.end,
          _Key.pgUp => TerminalKey.pageUp,
          _ => TerminalKey.pageDown,
        };
        final ctrl = _ctrlOn;
        final alt = _altOn;
        setState(() {
          _ctrlOn = false;
          _altOn = false;
        });
        _term.keyInput(key, ctrl: ctrl, alt: alt);
    }
  }

  /** _submitLine：底部输入行，发送命令并回车 */
  void _submitLine() {
    final t = _input.text;
    _sendBytes('$t\r');
    _input.clear();
  }

  /** _menu：更多操作 */
  Future<void> _menu() async {
    final sel = _ctrl.selection;
    final i = await actionSheet(context, [
      const SheetAction('粘贴', icon: LucideIcons.clipboardPaste300),
      SheetAction(sel == null ? '复制（先长按选择文字）' : '复制所选', icon: LucideIcons.copy300),
      const SheetAction('快捷启动', icon: LucideIcons.rocket300),
      const SheetAction('结束终端', icon: LucideIcons.power300, danger: true),
    ]);
    if (!mounted) return;
    switch (i) {
      case 0:
        final d = await Clipboard.getData(Clipboard.kTextPlain);
        if (d?.text != null) _term.paste(d!.text!);
      case 1:
        if (sel == null) return;
        await Clipboard.setData(ClipboardData(text: _term.buffer.getText(sel)));
        _ctrl.clearSelection();
        if (mounted) toast(context, '已复制');
      case 2:
        await _quickStart();
      case 3:
        final ok = await confirm(context, title: '结束终端', message: '终端中正在运行的程序会被结束。', ok: '结束', danger: true);
        if (!ok) return;
        try {
          await _scope!.conn.api.closeTerminal(widget.sessionId);
          await _scope!.sessions.hide(widget.sessionId);
          if (mounted) Navigator.of(context).pop();
        } on ApiException catch (e) {
          if (mounted) toast(context, e.message);
        }
    }
  }

  /** _quickStart：在当前终端启动 Agent 的原生界面或自定义命令 */
  Future<void> _quickStart() async {
    const cmds = ['claude', 'codex', 'pi', 'dsh'];
    final i = await actionSheet(context, [for (final c in cmds) SheetAction(c), const SheetAction('自定义命令…')], title: '快捷启动');
    if (i == null || !mounted) return;
    var cmd = i < cmds.length ? cmds[i] : await inputDialog(context, title: '自定义命令', hint: '例如 npm run dev');
    cmd = cmd?.trim();
    if (cmd == null || cmd.isEmpty) return;
    _sendBytes('$cmd\r');
  }

  /** 双指缩放调整字号 */
  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      _pinchStart = _distance();
      _fontStart = _font;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _pinchStart;
    if (_pointers.length == 2 && start != null && start > 0) {
      final f = (_fontStart * _distance() / start).clamp(8.0, 24.0);
      if ((f - _font).abs() >= 0.5) setState(() => _font = f.roundToDouble());
    }
  }

  void _onPointerUp(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _pinchStart = null;
  }

  double _distance() {
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final s = _scope?.sessions.byId(widget.sessionId);
    final host = _scope?.host.name ?? '';
    final status = switch (_link) {
      _Link.connecting => '连接中…',
      _Link.online => '',
      _Link.offline => '已断开，正在重连…',
      _Link.exited => '终端已结束',
    };
    return Scaffold(
      backgroundColor: c.termBg,
      appBar: PdBar(
        title: s == null ? '终端' : sessionTitle(s),
        subtitle: status.isEmpty ? host : '$host · $status',
        dark: true,
        actions: [PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', color: Colors.white, onTap: _menu)],
      ),
      body: Column(children: [
        Expanded(
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerUp,
            child: Stack(children: [
              TerminalView(
                _term,
                controller: _ctrl,
                focusNode: _termFocus,
                theme: pdTerminalTheme,
                textStyle: TerminalStyle(fontSize: _font, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback),
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                keyboardAppearance: Brightness.dark,
                readOnly: _link == _Link.exited,
              ),
              if (_link == _Link.exited)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    color: c.termBar,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Row(children: [
                      const Expanded(child: Text('终端已结束', style: TextStyle(color: pdTerminalMuted, fontSize: 13))),
                      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        Container(
          color: c.termBar,
          child: SafeArea(
            top: false,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                  children: [
                    for (final k in _Key.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Semantics(
                          button: true,
                          label: _keyLabels[k],
                          child: GestureDetector(
                            onTap: () => _key(k),
                            child: Container(
                              constraints: const BoxConstraints(minWidth: 38),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: (k == _Key.ctrl && _ctrlOn) || (k == _Key.alt && _altOn) ? c.accent : c.termKey,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(_keyLabels[k]!, style: TextStyle(fontSize: 12, color: c.termText)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
                child: Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _input,
                        onSubmitted: (_) => _submitLine(),
                        textInputAction: TextInputAction.send,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardAppearance: Brightness.dark,
                        style: TextStyle(fontSize: 13, color: pdTerminalTheme.green, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback),
                        decoration: InputDecoration(
                          hintText: '输入命令，回车执行',
                          hintStyle: const TextStyle(fontSize: 13, color: pdTerminalMuted),
                          fillColor: c.termBg,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.termKey)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Semantics(
                    button: true,
                    label: '执行',
                    child: GestureDetector(
                      onTap: _submitLine,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                        child: const Icon(LucideIcons.cornerDownLeft300, size: 18, color: Colors.white),
                      ),
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

/** _StringSink：把解码后的文字交给终端 */
class _StringSink implements Sink<String> {
  _StringSink(this.onData);

  final void Function(String) onData;

  @override
  void add(String data) => onData(data);

  @override
  void close() {}
}
