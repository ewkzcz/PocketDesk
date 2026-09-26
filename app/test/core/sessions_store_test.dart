/**
 * 会话仓库测试：排序与搜索、未读累计、缓存后补拉、实时事件更新摘要、置顶失败回滚、手机端删除。
 */
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketdesk/core/sessions_store.dart';
import 'package:pocketdesk/data/chat.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/net/api.dart';

import '../data/local_db_test.dart' show openTestDb;

/** FakeServer：会话接口的内存实现 */
class FakeServer {
  final sessions = <Map<String, dynamic>>[
    {'id': 'a', 'kind': 'claude', 'title': '修复登录', 'updatedAt': 10, 'preview': '好的'},
    {'id': 'b', 'kind': 'codex', 'title': '写测试', 'updatedAt': 20, 'pinned': false},
    {'id': 'c', 'kind': 'terminal', 'title': '终端', 'updatedAt': 5, 'pinned': true},
  ];
  final events = <String, List<Map<String, dynamic>>>{};
  bool failPatch = false;
  final calls = <String>[];

  http.Response _json(Object v, [int code = 200]) => http.Response.bytes(utf8.encode(jsonEncode(v)), code);

  PdApi api() => PdApi(
        base: Uri.parse('https://h:1'),
        client: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}?${req.url.query}');
          final p = req.url.path;
          if (p == '/api/sessions') return _json(sessions);
          final m = RegExp(r'^/api/sessions/(\w+)(/events)?$').firstMatch(p)!;
          if (m.group(2) != null) {
            final all = events[m.group(1)] ?? [];
            final q = req.url.queryParameters;
            final limit = int.parse(q['limit']!);
            if (q.containsKey('before')) {
              final before = int.parse(q['before']!);
              final older = all.where((e) => (e['seq'] as int) < before).toList();
              return _json(older.sublist(older.length > limit ? older.length - limit : 0));
            }
            final after = int.parse(q['after']!);
            return _json(all.where((e) => (e['seq'] as int) > after).take(limit).toList());
          }
          if (failPatch) return _json({'code': 'x', 'message': '失败'}, 500);
          final s = sessions.firstWhere((s) => s['id'] == m.group(1));
          s.addAll((jsonDecode(req.body) as Map).cast<String, dynamic>());
          return _json(s);
        }),
      );
}

Map<String, dynamic> ev(String s, int seq, String type, Map<String, dynamic> d) => {'session': s, 'seq': seq, 'type': type, 'data': d, 'createdAt': seq * 100};

void main() {
  late LocalDb db;
  late FakeServer server;
  late SessionsStore store;
  setUp(() async {
    db = await openTestDb();
    server = FakeServer();
    final api = server.api();
    store = SessionsStore(db: db, hostId: 'h', api: () => api);
    await store.init();
    await store.refresh();
  });
  tearDown(() async {
    store.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.db.close();
  });

  test('置顶优先、按更新时间倒序，搜索标题与摘要', () {
    expect(store.sessions.map((s) => s.id), ['c', 'b', 'a']);
    store.query = '好的';
    expect(store.sessions.map((s) => s.id), ['a']);
    store.query = '测试';
    expect(store.sessions.map((s) => s.id), ['b']);
  });

  test('实时事件更新摘要与未读，正在查看的会话不计未读', () async {
    store.onEvent(PdEvent.fromJson(ev('a', 1, 'msg.done', {'id': 'm', 'text': '改好了\n请看看'})));
    store.onEvent(PdEvent.fromJson(ev('a', 2, 'approval.request', {'id': 'p', 'summary': '运行 npm test'})));
    store.onEvent(PdEvent.fromJson(ev('a', 3, 'msg.delta', {'id': 'm2', 'text': '…'})));
    expect(store.unread('a'), 2);
    expect(store.byId('a')!.preview, '待确认：运行 npm test');
    expect(store.sessions.first.id, 'c');
    expect(store.sessions[1].id, 'a');
    expect(store.totalUnread, 2);
    store.open('b');
    store.onEvent(PdEvent.fromJson(ev('b', 1, 'msg.done', {'id': 'x', 'text': 'ok'})));
    expect(store.unread('b'), 0);
    store.open('a');
    await Future<void>.delayed(Duration.zero);
    expect(store.unread('a'), 0);
    expect(store.cursors(), {'a': 3, 'b': 1});
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect((await db.cachedEvents('h', 'a')).length, 3);
    expect(await db.unreadCounts('h'), containsPair('a', 0));
  });

  test('打开会话先读缓存再补拉，上滑加载更早记录', () async {
    await db.cacheEvents('h', 'a', [for (var i = 301; i <= 400; i++) PdEvent.fromJson(ev('a', i, 'msg.user', {'text': 'q$i'}))]);
    server.events['a'] = [for (var i = 1; i <= 450; i++) ev('a', i, 'msg.user', {'text': 'q$i'})];
    final log = await store.log('a');
    expect(log.items.length, 150);
    expect(log.lastSeq, 450);
    expect(server.calls.where((c) => c.contains('/events')).single, contains('after=400'));
    expect(await store.loadEarlier('a'), isTrue);
    expect(log.items.length, 350);
    expect((log.items.first as UserItem).text, 'q101');
    expect(await store.loadEarlier('a'), isTrue);
    expect(log.firstSeq, 1);
    expect(await store.loadEarlier('a'), isFalse);
    expect(identical(await store.log('a'), log), isTrue);
  });

  test('已打开的会话忽略重复事件', () async {
    server.events['a'] = [ev('a', 1, 'msg.user', {'text': 'x'})];
    final log = await store.log('a');
    store.onEvent(PdEvent.fromJson(ev('a', 1, 'msg.user', {'text': 'x'})));
    expect(log.items.length, 1);
  });

  test('置顶失败回滚', () async {
    await store.togglePin('a');
    expect(store.byId('a')!.pinned, isTrue);
    server.failPatch = true;
    await expectLater(store.togglePin('a'), throwsA(isA<ApiException>()));
    expect(store.byId('a')!.pinned, isTrue);
  });

  test('手机端删除只隐藏，重新出现的新会话可见', () async {
    await store.hide('b');
    expect(store.sessions.map((s) => s.id), isNot(contains('b')));
    expect(await db.hiddenSessions('h'), {'b'});
    store.onEvent(PdEvent.fromJson({'type': 'session.created', 'data': {'id': 'd', 'kind': 'pi', 'title': '新', 'updatedAt': 99}}));
    expect(store.sessions[1].id, 'd');
    // 过程中的流式片段不会让它重新出现，完成的回复会
    store.onEvent(PdEvent.fromJson(ev('b', 1, 'msg.delta', {'id': 'm', 'text': '…'})));
    expect(store.sessions.map((s) => s.id), isNot(contains('b')));
    store.onEvent(PdEvent.fromJson(ev('b', 2, 'msg.done', {'id': 'm', 'text': '好了'})));
    expect(store.sessions.map((s) => s.id), contains('b'));
    expect(store.unread('b'), 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await db.hiddenSessions('h'), isEmpty);
  });
}
