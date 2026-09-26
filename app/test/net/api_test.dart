/**
 * 接口封装测试：令牌携带、参数拼接、错误解析、离线与超时、412 冲突携带 ETag。
 */
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketdesk/net/api.dart';

void main() {
  final base = Uri.parse('https://192.168.1.5:8443');

  test('携带令牌并解析会话列表与事件', () async {
    final seen = <http.Request>[];
    final api = PdApi(
      base: base,
      token: 'tk',
      client: MockClient((req) async {
        seen.add(req);
        if (req.url.path == '/api/sessions') {
          return http.Response.bytes(utf8.encode(jsonEncode([{'id': 's1', 'kind': 'claude', 'title': '修复', 'pinned': true, 'updatedAt': 5}])), 200);
        }
        return http.Response.bytes(utf8.encode(jsonEncode([{'session': 's1', 'seq': 3, 'type': 'msg.user', 'data': {'text': '你好'}}])), 200);
      }),
    );
    final list = await api.sessions();
    expect(list.single.title, '修复');
    expect(list.single.pinned, isTrue);
    expect(list.single.cwd, '.');
    final evs = await api.events('s1', after: 2, limit: 10);
    expect(evs.single.data['text'], '你好');
    expect(seen.first.headers['Authorization'], 'Bearer tk');
    expect(seen.last.url.queryParameters, {'after': '2', 'limit': '10'});
    await api.events('s1', before: 50, limit: 200);
    expect(seen.last.url.queryParameters, {'before': '50', 'limit': '200'});
  });

  test('错误体解析为 ApiException，412 携带最新 ETag', () async {
    final api = PdApi(
      base: base,
      client: MockClient((req) async {
        if (req.method == 'PUT') {
          expect(req.headers['If-Match'], '"v1"');
          return http.Response.bytes(utf8.encode(jsonEncode({'code': 'conflict', 'message': '文件已被修改'})), 412, headers: {'etag': '"v2"'});
        }
        return http.Response('oops', 500);
      }),
    );
    await expectLater(
      api.saveFile('w', 'a.md', utf8.encode('x'), ifMatch: '"v1"'),
      throwsA(isA<ApiException>().having((e) => e.status, 'status', 412).having((e) => e.etag, 'etag', '"v2"').having((e) => e.code, 'code', 'conflict')),
    );
    await expectLater(api.workspaces(), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'http_500').having((e) => e.offline, 'offline', isFalse)));
  });

  test('连接失败与超时视为离线', () async {
    final down = PdApi(base: base, client: MockClient((_) => throw const SocketException('down')));
    await expectLater(down.sessions(), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', isTrue)));
    final slow = PdApi(base: base, client: MockClient((_) => Future.delayed(const Duration(seconds: 1), () => http.Response('[]', 200))));
    await expectLater(slow.host(wait: const Duration(milliseconds: 50)), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'timeout')));
  });

  test('修改会话只发送变化的字段', () async {
    late Map<String, dynamic> body;
    final api = PdApi(
      base: base,
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response.bytes(utf8.encode(jsonEncode({'id': 's', 'pinned': true})), 200);
      }),
    );
    final s = await api.patchSession('s', pinned: true);
    expect(body, {'pinned': true});
    expect(s.pinned, isTrue);
  });
}
