/**
 * 接口封装：与电脑端服务通信的全部 REST 调用，统一错误处理与令牌携带。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/models.dart';

/** ApiException：接口错误，code 与电脑端约定一致 */
class ApiException implements Exception {
  ApiException(this.status, this.code, this.message, {this.etag = ''});

  final int status;
  final String code;
  final String message;
  final String etag;

  /** 是否为网络不可达（没有收到任何响应） */
  bool get offline => status == 0;

  @override
  String toString() => message;
}

/** SaveResult：保存文件结果 */
class SaveResult {
  const SaveResult(this.etag);

  final String etag;
}

/**
 * PdApi：一台电脑的接口客户端
 */
class PdApi {
  PdApi({required this.base, required this.client, this.token = ''});

  /** 电脑地址，如 https://192.168.1.5:8443 */
  final Uri base;

  /** 已做证书固定的 HTTP 客户端 */
  final http.Client client;

  /** 设备令牌 */
  String token;

  /** 默认超时 */
  static const timeout = Duration(seconds: 15);

  /** uri：拼接路径与参数 */
  Uri uri(String path, [Map<String, String>? query]) => base.replace(path: path, queryParameters: (query == null || query.isEmpty) ? null : query);

  /** headers：公共请求头 */
  Map<String, String> headers([Map<String, String>? extra]) => {
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        ...?extra,
      };

  /**
   * send：发送请求并处理错误
   *
   * 处理流程：
   * 1、发送并等待响应，超时或连接失败转为 offline 错误
   * 2、非 2xx 解析 {"code","message"} 抛出 ApiException
   */
  Future<http.Response> send(String method, String path, {Map<String, String>? query, Object? body, Map<String, String>? extra, Duration? wait}) async {
    final req = http.Request(method, uri(path, query));
    req.headers.addAll(headers(extra));
    if (body is List<int>) {
      req.bodyBytes = body;
    } else if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    // 1、发送
    http.Response res;
    try {
      res = await http.Response.fromStream(await client.send(req).timeout(wait ?? timeout));
    } on TimeoutException {
      throw ApiException(0, 'timeout', '连接电脑超时');
    } on SocketException {
      throw ApiException(0, 'offline', '无法连接电脑');
    } on HandshakeException {
      throw ApiException(0, 'cert', '电脑证书与配对时不一致');
    } on http.ClientException {
      throw ApiException(0, 'offline', '无法连接电脑');
    }
    // 2、错误
    if (res.statusCode >= 300) {
      var code = 'http_${res.statusCode}';
      var msg = '操作失败（${res.statusCode}）';
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is Map) {
          code = Json.str(j['code'], code);
          msg = Json.str(j['message'], msg);
        }
      } on FormatException {
        // 非 JSON 错误体沿用默认提示
      }
      throw ApiException(res.statusCode, code, msg, etag: res.headers['etag'] ?? '');
    }
    return res;
  }

  /** json：发送并解析 JSON */
  Future<dynamic> json(String method, String path, {Map<String, String>? query, Object? body, Duration? wait}) async {
    final res = await send(method, path, query: query, body: body, wait: wait);
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  /* ---------- 配对与电脑 ---------- */

  /** pair：提交配对码，最长等待 2 分钟电脑端确认 */
  Future<({String token, String deviceId, String hostName, String fingerprint})> pair(String code, String name, String platform, {String installId = ''}) async {
    final j = Json.map(await json('POST', '/api/pair', body: {'code': code, 'name': name, 'platform': platform, if (installId.isNotEmpty) 'installId': installId}, wait: const Duration(minutes: 2, seconds: 10)));
    final host = Json.map(j['host']);
    return (token: Json.str(j['token']), deviceId: Json.str(j['deviceId']), hostName: Json.str(host['name']), fingerprint: Json.str(host['fingerprint']));
  }

  /** host：电脑信息 */
  Future<HostStatus> host({Duration? wait}) async => HostStatus.fromJson(Json.map(await json('GET', '/api/host', wait: wait)));

  /* ---------- 工作区 ---------- */

  /** workspaces：工作区列表 */
  Future<List<Workspace>> workspaces() async => Json.list(await json('GET', '/api/ws')).map((e) => Workspace.fromJson(Json.map(e))).toList();

  /** addWorkspace：把电脑上的文件夹添加为工作区 */
  Future<Workspace> addWorkspace(String path, {String name = ''}) async =>
      Workspace.fromJson(Json.map(await json('POST', '/api/ws', body: {'path': path, if (name.isNotEmpty) 'name': name})));

  /** removeWorkspace：移除工作区（只移除登记，不动文件） */
  Future<void> removeWorkspace(String id) async => json('DELETE', '/api/ws/${Uri.encodeComponent(id)}');

  /** setDefaultWorkspace：更换默认工作目录 */
  Future<void> setDefaultWorkspace(String path) async => json('PUT', '/api/ws/default', body: {'path': path});

  /** dirs：电脑上的收件目录与默认工作目录 */
  Future<({String inbox, String defaultWorkspace})> dirs() async {
    final j = Json.map(await json('GET', '/api/dirs'));
    return (inbox: Json.str(j['inboxDir']), defaultWorkspace: Json.str(j['defaultWorkspace']));
  }

  /** setDirs：更换电脑上的收件目录，立即生效 */
  Future<void> setDirs({String? inbox}) async => json('PUT', '/api/dirs', body: {'inboxDir': ?inbox});

  /** list：列目录 */
  Future<({List<FileEntry> entries, bool readOnly})> list(String ws, String path, {String sort = '', bool desc = false, bool hidden = false}) async {
    final j = Json.map(await json('GET', '/api/ws/$ws/list', query: {
      'path': path,
      if (sort.isNotEmpty) 'sort': sort,
      if (desc) 'order': 'desc',
      if (hidden) 'hidden': '1',
    }));
    return (entries: Json.list(j['entries']).map((e) => FileEntry.fromJson(Json.map(e))).toList(), readOnly: Json.boolean(j['readOnly']));
  }

  /** readText：读取文本文件，返回内容与 ETag */
  Future<({List<int> bytes, String etag})> readFile(String ws, String path) async {
    final res = await send('GET', '/api/ws/$ws/file', query: {'path': path}, wait: const Duration(minutes: 2));
    return (bytes: res.bodyBytes, etag: res.headers['etag'] ?? '');
  }

  /** fileUrl：文件下载地址（供下载器与播放器使用） */
  Uri fileUrl(String ws, String path) => uri('/api/ws/$ws/file', {'path': path});

  /** saveFile：带 If-Match 保存，冲突时抛出 412 */
  Future<SaveResult> saveFile(String ws, String path, List<int> bytes, {String ifMatch = '', bool create = false}) async {
    final res = await send('PUT', '/api/ws/$ws/file', query: {'path': path, if (create) 'create': '1'}, body: bytes, extra: {if (ifMatch.isNotEmpty) 'If-Match': ifMatch}, wait: const Duration(minutes: 5));
    return SaveResult(res.headers['etag'] ?? '');
  }

  /** op：文件操作，返回新路径 */
  Future<String> op(String ws, String op, String path, {String name = '', String dest = ''}) async {
    final j = Json.map(await json('POST', '/api/ws/$ws/ops', body: {'op': op, 'path': path, 'name': name, 'dest': dest}));
    return Json.str(j['path']);
  }

  /** search：全工作区文件名搜索 */
  Future<List<FileEntry>> search(String ws, String q) async {
    final j = Json.map(await json('GET', '/api/ws/$ws/search', query: {'q': q}, wait: const Duration(seconds: 30)));
    return Json.list(j['entries']).map((e) => FileEntry.fromJson(Json.map(e))).toList();
  }

  /* ---------- 会话 ---------- */

  /** sessions：会话列表 */
  Future<List<SessionInfo>> sessions() async => Json.list(await json('GET', '/api/sessions')).map((e) => SessionInfo.fromJson(Json.map(e))).toList();

  /** createSession：新建 Agent 或终端会话 */
  Future<SessionInfo> createSession(String kind, String ws, String cwd, {String model = '', String agentSessionId = '', int cols = 0, int rows = 0, String command = '', bool autoApprove = false}) async {
    final j = await json('POST', '/api/sessions', body: {
      'kind': kind,
      'workspaceId': ws,
      'cwd': cwd,
      if (model.isNotEmpty) 'model': model,
      if (agentSessionId.isNotEmpty) 'agentSessionId': agentSessionId,
      if (cols > 0) 'cols': cols,
      if (rows > 0) 'rows': rows,
      if (command.isNotEmpty) 'command': command,
      if (autoApprove) 'autoApprove': true,
    });
    return SessionInfo.fromJson(Json.map(j));
  }

  /** patchSession：改名、置顶、切换模型或目录 */
  Future<SessionInfo> patchSession(String id, {String? title, bool? pinned, String? model, String? cwd}) async {
    final j = await json('PATCH', '/api/sessions/$id', body: {
      'title': ?title,
      'pinned': ?pinned,
      'model': ?model,
      'cwd': ?cwd,
    });
    return SessionInfo.fromJson(Json.map(j));
  }

  /** closeTerminal：结束终端 */
  Future<void> closeTerminal(String id) => send('DELETE', '/api/sessions/$id');

  /** events：按序号补拉或向前加载 */
  Future<List<PdEvent>> events(String id, {int after = 0, int before = 0, int limit = 500}) async {
    final j = await json('GET', '/api/sessions/$id/events', query: {
      if (before > 0) 'before': '$before' else 'after': '$after',
      'limit': '$limit',
    });
    return Json.list(j).map((e) => PdEvent.fromJson(Json.map(e))).toList();
  }

  /** sendMessage：发送消息 */
  Future<void> sendMessage(String id, String text, {List<String> attachments = const [], String clientId = ''}) =>
      send('POST', '/api/sessions/$id/messages', body: {
        'text': text,
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (clientId.isNotEmpty) 'clientId': clientId,
      });

  /** interrupt：打断 */
  Future<void> interrupt(String id) => send('POST', '/api/sessions/$id/interrupt');

  /** retry：重试上一条 */
  Future<void> retry(String id) => send('POST', '/api/sessions/$id/retry');

  /** diffSummary：本会话累计改动 */
  Future<({List<FileChange> files, bool git})> diffSummary(String id) async {
    final j = Json.map(await json('GET', '/api/sessions/$id/diff'));
    return (files: Json.list(j['files']).map((e) => FileChange.fromJson(Json.map(e))).toList(), git: Json.boolean(j['git']));
  }

  /** diffFile：单个文件差异 */
  Future<String> diffFile(String id, String path) async => Json.str(Json.map(await json('GET', '/api/sessions/$id/diff', query: {'path': path}))['diff']);

  /** decide：审批 */
  Future<void> decide(String approvalId, String action) => send('POST', '/api/approvals/$approvalId', body: {'action': action});

  /** models：可选模型 */
  Future<List<String>> models(String kind) async => Json.list(await json('GET', '/api/agents/$kind/models')).map((e) => e.toString()).toList();

  /** history：电脑上已有的会话 */
  Future<List<HistoryItem>> history(String kind, String ws, String cwd) async =>
      Json.list(await json('GET', '/api/agents/$kind/history', query: {'workspaceId': ws, 'cwd': cwd})).map((e) => HistoryItem.fromJson(Json.map(e))).toList();

  /* ---------- 传输 ---------- */

  /** outbox：电脑待发文件 */
  Future<List<OutboxItem>> outbox() async => Json.list(await json('GET', '/api/outbox')).map((e) => OutboxItem.fromJson(Json.map(e))).toList();

  /** outboxUrl：待发文件下载地址 */
  Uri outboxUrl(String id) => uri('/api/outbox/$id/file');

  /** ackOutbox：确认收到 */
  Future<void> ackOutbox(String id) => send('POST', '/api/outbox/$id/ack');

  /** assistantText：文件传输助手发文字 */
  Future<void> assistantText(String text, {String clientId = ''}) => send('POST', '/api/assistant/messages', body: {'text': text, 'clientId': clientId});

  /** exportLogs：电脑端日志压缩包 */
  Future<List<int>> exportLogs() async => (await send('POST', '/api/logs', wait: const Duration(minutes: 1))).bodyBytes;
}
