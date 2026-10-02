/**
 * 界面测试环境：内存数据库、假电脑接口（会话、事件、工作区、文件、待发文件）、假事件通道、真实中文与图标字体、截图输出。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketdesk/core/app_state.dart';
import 'package:pocketdesk/core/auth_gate.dart';
import 'package:pocketdesk/core/connection.dart';
import 'package:pocketdesk/core/pairing_service.dart';
import 'package:pocketdesk/core/settings.dart';
import 'package:pocketdesk/core/vault.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/main.dart';
import 'package:pocketdesk/net/api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/services_test.dart' show FakeAuth, FakeDiscovery, FakeSignals;
import '../data/local_db_test.dart' show openTestDb;

/** 固定的「现在」，让截图中的时间稳定 */
final uiNow = DateTime.now();
int ago(Duration d) => uiNow.subtract(d).millisecondsSinceEpoch;

/**
 * UiServer：假电脑接口
 */
class UiServer {
  final sessions = <Map<String, dynamic>>[
    {'id': 'cc', 'kind': 'claude', 'title': '重构支付模块', 'workspaceId': 'w1', 'cwd': '.', 'model': 'sonnet', 'state': 'running', 'preview': '正在运行测试…', 'updatedAt': ago(const Duration(minutes: 3)), 'lastSeq': 9},
    {'id': 'cx', 'kind': 'codex', 'title': '修复登录页 bug', 'workspaceId': 'w1', 'cwd': 'web', 'model': 'gpt-5', 'state': 'awaiting', 'preview': '待确认：是否删除 tmp/ 目录', 'updatedAt': ago(const Duration(minutes: 20))},
    {'id': 'pi', 'kind': 'pi', 'title': '数据清洗脚本', 'workspaceId': 'w1', 'cwd': '.', 'state': 'error', 'preview': '出错：进程异常退出', 'updatedAt': ago(const Duration(hours: 2))},
    {'id': 'ds', 'kind': 'dsh', 'title': '周报生成', 'workspaceId': 'w1', 'cwd': '.', 'state': 'idle', 'preview': '你：帮我总结这周的提交记录，并按模块分组列出主要改动和风险点', 'updatedAt': ago(const Duration(days: 1)), 'pinned': true},
    {'id': 't1', 'kind': 'terminal', 'title': 'MacBook Pro', 'workspaceId': 'w1', 'cwd': '.', 'state': 'idle', 'preview': '~/projects/site \$ npm run build', 'updatedAt': ago(const Duration(days: 2))},
    {'id': 'assistant', 'kind': 'assistant', 'title': '文件传输助手', 'state': 'idle', 'preview': '[图片] 截图.png', 'updatedAt': ago(const Duration(days: 3))},
  ];

  final events = <String, List<Map<String, dynamic>>>{
    'cc': [
      {'seq': 1, 'type': 'msg.user', 'data': {'text': '重构一下支付模块，把重复的校验逻辑提出来'}},
      {'seq': 2, 'type': 'msg.done', 'data': {'id': 'a1', 'text': '好的，我先看看当前的文件结构和已有的**校验逻辑**。'}},
      {'seq': 3, 'type': 'tool.start', 'data': {'id': 't1', 'name': 'Read', 'kind': 'read', 'summary': '读取 payments/validator.js', 'input': {'file_path': 'payments/validator.js'}}},
      {'seq': 4, 'type': 'tool.end', 'data': {'id': 't1', 'output': 'export function validate() {}'}},
      {'seq': 5, 'type': 'thinking', 'data': {'id': 'th', 'text': '需要找出重复的手机号与金额校验', 'done': true}},
      {'seq': 6, 'type': 'msg.done', 'data': {'id': 'a2', 'text': '找到了 3 处重复的手机号和金额校验，我把它们提到 `shared/validators.js` 里：\n\n```js\nexport const isPhone = (s) => /^1\\d{10}\$/.test(s);\n```\n\n| 文件 | 改动 |\n| --- | --- |\n| checkout.js | 引用共享校验 |'}},
      {'seq': 7, 'type': 'diff.summary', 'data': {'files': [{'path': 'shared/validators.js', 'added': 42, 'removed': 0, 'status': 'A'}, {'path': 'payments/validator.js', 'added': 5, 'removed': 20, 'status': 'M'}, {'path': 'payments/checkout.js', 'added': 3, 'removed': 3, 'status': 'M'}], 'git': true}},
      {'seq': 8, 'type': 'approval.request', 'data': {'id': 'ap1', 'tool': 'Bash', 'kind': 'command', 'summary': 'rm -rf payments/legacy/', 'input': {'command': 'rm -rf payments/legacy/'}, 'expiresAt': 0}},
      {'seq': 9, 'type': 'error', 'data': {'message': '网络请求超时', 'retryable': true}},
      {'seq': 10, 'type': 'msg.user', 'data': {'text': '顺便把测试也补上', 'queued': true}},
    ],
    'assistant': [
      {'seq': 1, 'type': 'file', 'data': {'direction': 'up', 'name': '截图.png', 'size': 1258291, 'relPath': '20261001/截图.png', 'path': '/Users/me/PocketDesk/Inbox/20261001/截图.png'}},
      {'seq': 2, 'type': 'file', 'data': {'direction': 'down', 'name': '周报.pdf', 'size': 348160, 'outboxId': 'o9'}},
      {'seq': 3, 'type': 'msg.user', 'data': {'text': '这是今天的会议纪要链接'}},
      {'seq': 4, 'type': 'file', 'data': {'direction': 'up', 'name': '旧图.png', 'size': 2048, 'relPath': '20260901/旧图.png'}},
    ],
  };

  final workspaces = <Map<String, dynamic>>[
    {'id': 'computer', 'name': '此电脑', 'rootPath': '/', 'readOnly': false, 'system': true, 'home': 'Users/me'},
    {'id': 'w1', 'name': 'payments', 'rootPath': '/Users/me/payments', 'readOnly': false, 'isDefault': true},
    {'id': 'w2', 'name': 'notes', 'rootPath': '/Users/me/notes', 'readOnly': true},
  ];

  List<Map<String, dynamic>> entries(String path) => path == '.' || path.isEmpty
      ? [
          {'name': '20261001', 'path': '20261001', 'isDir': true, 'size': 0, 'modTime': ago(const Duration(hours: 1)), 'childCount': 12, 'dateFolder': true},
          {'name': '20260930', 'path': '20260930', 'isDir': true, 'size': 0, 'modTime': ago(const Duration(days: 1)), 'childCount': 8, 'dateFolder': true},
          {'name': 'README.md', 'path': 'README.md', 'isDir': false, 'size': 12288, 'modTime': ago(const Duration(hours: 2))},
          {'name': '会议纪要-产品评审与技术方案讨论记录（第三版）.md', 'path': '会议纪要.md', 'isDir': false, 'size': 8192, 'modTime': ago(const Duration(days: 1))},
          {'name': '截图.png', 'path': '截图.png', 'isDir': false, 'size': 1258291, 'modTime': ago(const Duration(days: 2))},
          {'name': 'archive.zip', 'path': 'archive.zip', 'isDir': false, 'size': 47185920, 'modTime': ago(const Duration(days: 8))},
          {'name': 'main.go', 'path': 'main.go', 'isDir': false, 'size': 2048, 'modTime': ago(const Duration(days: 9))},
        ]
      : [
          {'name': 'a.md', 'path': '$path/a.md', 'isDir': false, 'size': 100, 'modTime': ago(const Duration(hours: 1))},
        ];

  final outbox = <Map<String, dynamic>>[
    {'id': 'o1', 'name': '白板照片.jpg', 'size': 2411724, 'sha256': '', 'createdAt': 1},
  ];

  /** Markdown 文档：标题、表格、任务列表、代码、公式与相对路径图片 */
  static final markdownDoc = '# 周报\n\n本周完成 **配对** 与 `传输`。\n\n| 项目 | 状态 |\n|---|---|\n| 扫码配对 | 完成 |\n\n- [x] 真机测试\n- [ ] 上架\n\n```go\nfunc main() {}\n```\n\n行内公式 \$a^2+b^2=c^2\$\n\n\$\$E=mc^2\$\$\n\n![白板](img/board.png)\n\n## 下周计划\n\n${'继续推进真机验证与兼容性测试。' * 40}\n';

  /** 1×1 像素 PNG */
  static final pngBytes = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

  /** 电脑上的收发目录 */
  final dirs = <String, String>{'inboxDir': '/Users/me/PocketDesk/Inbox', 'defaultWorkspace': '/Users/me/payments'};

  /** 读取工作区列表时模拟连不上电脑 */
  bool workspacesDown = false;

  final calls = <String>[];
  final bodies = <String, Object?>{};

  /** 发消息记录，failSends 大于 0 时模拟网络中断 */
  final sent = <Map<String, dynamic>>[];
  int failSends = 0;

  http.Response _json(Object? v, [int code = 200, Map<String, String> headers = const {}]) =>
      http.Response.bytes(utf8.encode(jsonEncode(v)), code, headers: {'content-type': 'application/json', ...headers});

  HostStatus get status => HostStatus.fromJson({
        'name': 'MacBook Pro',
        'os': 'darwin',
        'version': '1.0.0',
        'fingerprint': 'ab' * 32,
        'agents': [
          for (final k in ['claude', 'codex', 'pi', 'dsh']) {'kind': k, 'label': k, 'installed': true},
        ],
        'features': {'agents': true, 'terminal': true, 'fileEdit': true},
        'addresses': [],
        'port': 8443,
      });

  /** api：创建假接口客户端 */
  PdApi api(Uri base, String token) => PdApi(base: base, token: token, client: MockClient(_handle));

  Future<http.Response> _handle(http.Request req) async {
    final p = req.url.path;
    calls.add('${req.method} $p');
    if (req.body.isNotEmpty) bodies['${req.method} $p'] = req.headers['content-type']?.contains('json') == true ? jsonDecode(req.body) : req.body;
    if (p.endsWith('/messages') && req.method == 'POST') {
      sent.add((jsonDecode(req.body) as Map).cast<String, dynamic>());
      if (failSends > 0) {
        failSends--;
        throw const SocketException('网络中断');
      }
    }
    final q = req.url.queryParameters;
    if (p == '/api/host') {
      return _json({
        'name': 'MacBook Pro', 'os': 'darwin', 'version': '1.0.0', 'fingerprint': 'ab' * 32, 'port': 8443, //
        'agents': [for (final k in ['claude', 'codex', 'pi', 'dsh']) {'kind': k, 'label': k, 'installed': true}],
        'features': {'agents': true, 'terminal': true, 'fileEdit': true},
        'remote': {'state': 'missing', 'addresses': []},
      });
    }
    if (p == '/api/sessions' && req.method == 'GET') return _json(sessions);
    if (p == '/api/sessions' && req.method == 'POST') {
      final b = (jsonDecode(req.body) as Map).cast<String, dynamic>();
      final s = {'id': 'new1', 'kind': b['kind'], 'title': '', 'workspaceId': b['workspaceId'], 'cwd': '.', 'model': '', 'state': 'idle', 'pinned': false, 'lastSeq': 0, 'preview': '', 'updatedAt': ago(Duration.zero), 'autoApprove': b['autoApprove'] ?? false};
      sessions.add(s);
      return _json(s, 201);
    }
    if (p == '/api/ws' && req.method == 'POST') {
      final b = (jsonDecode(req.body) as Map).cast<String, dynamic>();
      final w = {'id': 'w${workspaces.length + 1}', 'name': (b['path'] as String).split('/').last, 'rootPath': b['path'], 'readOnly': false};
      workspaces.add(w);
      return _json(w, 201);
    }
    if (p == '/api/ws') {
      if (workspacesDown) throw const SocketException('网络中断');
      return _json(workspaces);
    }
    if (p == '/api/dirs' && req.method == 'GET') return _json(dirs);
    if (p == '/api/dirs' && req.method == 'PUT') {
      (jsonDecode(req.body) as Map).forEach((k, v) => dirs[k as String] = v as String);
      return _json(dirs);
    }
    if (p == '/api/outbox') return _json(outbox);
    if (p.endsWith('/list')) return _json({'entries': entries(q['path'] ?? '.'), 'readOnly': p.contains('/w2/')});
    if (p.endsWith('/file') && req.method == 'GET') {
      final path = q['path'] ?? '';
      if (path.endsWith('.md')) return http.Response.bytes(utf8.encode(markdownDoc), 200, headers: {'etag': '"m1"'});
      if (path.endsWith('.png')) return http.Response.bytes(pngBytes, 200, headers: {'etag': '"p1"'});
      return http.Response.bytes(utf8.encode('package main\n\nfunc main() {\n\tprintln("你好")\n}\n'), 200, headers: {'etag': '"e1"'});
    }
    if (p.endsWith('/file') && req.method == 'PUT') return http.Response('', 204, headers: {'etag': '"e2"'});
    final ev = RegExp(r'^/api/sessions/(\w+)/events$').firstMatch(p);
    if (ev != null) {
      final all = (events[ev.group(1)] ?? []).map((e) => {...e, 'session': ev.group(1), 'createdAt': ago(Duration(minutes: 30 - (e['seq'] as int)))}).toList();
      final after = int.tryParse(q['after'] ?? '') ?? 0;
      if (q.containsKey('before')) return _json(<Object>[]);
      return _json(all.where((e) => (e['seq'] as int) > after).toList());
    }
    final sp = RegExp(r'^/api/sessions/(\w+)$').firstMatch(p);
    if (sp != null && req.method == 'PATCH') {
      final s = sessions.firstWhere((s) => s['id'] == sp.group(1));
      s.addAll((jsonDecode(req.body) as Map).cast<String, dynamic>());
      return _json(s);
    }
    if (p.startsWith('/api/agents/') && p.endsWith('/models')) return _json(['sonnet', 'opus']);
    if (p.startsWith('/api/agents/') && p.endsWith('/providers')) {
      return _json({
        'available': true,
        'list': [
          {'id': 'ds', 'name': 'DeepSeek', 'current': true, 'host': 'api.deepseek.com', 'models': ['deepseek-flash']},
          {'id': 'relay', 'name': '中转站', 'current': false, 'host': 'relay.example', 'models': []},
        ],
      });
    }
    if (p.startsWith('/api/agents/') && p.endsWith('/skills') && req.method == 'GET') {
      return _json([
        {'name': 'archify', 'description': '画架构图', 'path': '/Users/me/.claude/skills/archify/SKILL.md', 'scope': 'user', 'enabled': true},
        {'name': 'pdf', 'description': '处理 PDF', 'path': '/Users/me/.claude/skills/pdf/SKILL.md', 'scope': 'user', 'enabled': false},
      ]);
    }
    if (p.startsWith('/api/agents/') && p.endsWith('/skill')) return _json({'text': '---\nname: archify\n---\n# 架构图\n按说明画图'});
    if (p.startsWith('/api/agents/') && p.endsWith('/history')) return _json(<Object>[]);
    if (p.endsWith('/diff')) {
      if (q.containsKey('ref')) return _json({'diff': '--- a/notes.md\n+++ b/notes.md\n@@ -1,1 +1,2 @@\n 标题\n+本轮新增的一行'});
      if (q.containsKey('path')) return _json({'diff': 'diff --git a/x b/x\n@@ -1,3 +1,3 @@\n-const a = 1;\n+const a = 2;\n unchanged line'});
      return _json({'files': events['cc']![6]['data']['files'], 'git': true});
    }
    if (req.method == 'POST') return _json({'ok': true});
    return _json({'code': 'not_found', 'message': '不存在'}, 404);
  }
}

/** FakeSocket：只回复 ready 的事件通道 */
class FakeSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeSocket() {
    _in.stream.listen((m) {
      final j = jsonDecode(m as String) as Map;
      if (j['type'] == 'hello') _out.add(jsonEncode({'type': 'ready'}));
    });
  }

  final _out = StreamController<dynamic>();
  final _in = StreamController<dynamic>();

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  WebSocketSink get sink => _Sink(_in, _out);

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _Sink implements WebSocketSink {
  _Sink(this._c, this._out);

  final StreamController<dynamic> _c;
  final StreamController<dynamic> _out;

  @override
  void add(dynamic data) {
    if (!_c.isClosed) _c.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    await _c.close();
    await _out.close();
  }

  @override
  Future<void> get done => _c.done;
}

bool _fontsLoaded = false;

/** loadFonts：加载中文与图标字体，截图才能看到真实文字 */
Future<void> loadFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  final cjk = File('/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc');
  if (await cjk.exists()) {
    final bytes = await cjk.readAsBytes();
    for (final family in ['Roboto', 'monospace', 'SF Mono', 'Menlo']) {
      await (FontLoader(family)..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  }
  for (final w in [300, 400]) {
    final data = rootBundle.load('packages/lucide_icons_flutter/assets/build_font/LucideVariable-w$w.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide$w')..addFont(data)).load();
  }
}

/**
 * UiEnv：一次界面测试的环境
 */
class UiEnv {
  UiEnv._(this.server, this.db, this.settings, this.app, this.gate, this.auth);

  final UiServer server;
  final LocalDb db;
  final AppSettings settings;
  final AppState app;
  final AuthGate gate;
  final FakeAuth auth;

  /**
   * create：创建并连接（在 runAsync 中调用）
   */
  static Future<UiEnv> create({ThemeMode theme = ThemeMode.light, bool paired = true, bool biometric = false, void Function(UiServer s)? setup}) async {
    SharedPreferences.setMockInitialValues({'theme': theme.name, 'biometric': biometric, 'host': paired ? 'h1' : '', 'autoReceive': false});
    final settings = AppSettings(await SharedPreferences.getInstance());
    final db = await openTestDb();
    final vault = MemoryVault();
    final server = UiServer();
    setup?.call(server);
    if (paired) {
      await db.saveHost(const PairedHost(id: 'h1', name: 'MacBook Pro', addresses: ['192.168.1.5'], port: 8443, fingerprint: 'abababababababababababababababababababababababababababababababab'));
      await vault.saveToken('h1', 'tk');
    }
    final tmp = await Directory.systemTemp.createTemp('pdui');
    final app = AppState(
      settings: settings,
      db: db,
      vault: vault,
      paths: AppPaths(temp: Directory('${tmp.path}/t'), received: Directory('${tmp.path}/r')),
      signals: FakeSignals(),
      connections: (h, t, c) => HostConnection(host: h, token: t, cursors: c, apis: server.api, sockets: (_, _) => FakeSocket(), clients: (_) => HttpClient()),
      discovery: FakeDiscovery.new,
    );
    await app.init();
    final scope = app.scope;
    if (scope != null) {
      for (var i = 0; i < 100 && !scope.conn.online; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await scope.sessions.refresh();
    }
    final auth = FakeAuth();
    final gate = AuthGate(auth: auth, enabled: () => settings.biometric, graceMinutes: () => settings.graceMinutes);
    return UiEnv._(server, db, settings, app, gate, auth);
  }

  /** widget：根组件 */
  Widget widget() => RepaintBoundary(
        key: shotKey,
        child: PocketDeskApp(settings: settings, app: app, gate: gate, pairing: PairingService(db: db, vault: MemoryVault(), deviceName: 't', platform: 'android')),
      );

  /** dispose：释放 */
  Future<void> dispose() async {
    app.dispose();
    // 等待后台的缓存写入结束再关闭数据库
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await db.db.close();
  }
}

/** 截图根节点 */
final shotKey = GlobalKey();

/** 截图输出目录（仓库外），未设置时不输出 */
final _shotDir = Platform.environment['PD_SHOTS'] ?? '';

/**
 * shot：保存当前画面截图（用于人工检查重叠与错位）
 */
Future<void> shot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = File('$_shotDir/$name.png');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/** setSize：设置手机屏幕尺寸与字体缩放 */
void setSize(WidgetTester tester, Size size, {double textScale = 1}) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/** settle：推进动画（不等待无限动画），并让本地数据库等真实异步操作完成 */
Future<void> settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/** pageHost：在完整的 Provider 与主题下单独显示某个页面 */
Widget pageHost(UiEnv env, Widget page) => RepaintBoundary(
      key: shotKey,
      child: PocketDeskAppShell(env: env, home: page),
    );

/** PocketDeskAppShell：与正式入口相同的主题与 Provider，首页可指定 */
class PocketDeskAppShell extends StatelessWidget {
  const PocketDeskAppShell({super.key, required this.env, required this.home});

  final UiEnv env;
  final Widget home;

  @override
  Widget build(BuildContext context) => PocketDeskApp(
        settings: env.settings,
        app: env.app,
        gate: env.gate,
        pairing: PairingService(db: env.db, vault: MemoryVault(), deviceName: 't', platform: 'android'),
        home: home,
      );
}

/** FakeTermSocket：终端通道，连接后输出一段文字并记录手机发来的输入 */
class FakeTermSocket with StreamChannelMixin<dynamic> implements WebSocketChannel {
  FakeTermSocket() {
    _in.stream.listen((m) {
      if (m is List<int>) {
        input.add(utf8.decode(m));
      } else {
        control.add((jsonDecode(m as String) as Map).cast<String, dynamic>());
      }
    });
    scheduleMicrotask(() => _out.add(utf8.encode('\x1b[32m~/projects/site\x1b[0m \x1b[34m\$\x1b[0m npm run build\r\n> vite build\r\n中文输出正常\r\n')));
  }

  final _out = StreamController<dynamic>();
  final _in = StreamController<dynamic>();
  final input = <String>[];
  final control = <Map<String, dynamic>>[];

  @override
  Stream<dynamic> get stream => _out.stream;

  @override
  WebSocketSink get sink => _Sink(_in, _out);

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}
