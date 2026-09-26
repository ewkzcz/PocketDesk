/**
 * 本地数据库测试：事件缓存上限、游标、未读、隐藏会话、草稿、短语、阅读位置、传输任务清理。
 */
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/data/local_db.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/** openTestDb：内存数据库 */
Future<LocalDb> openTestDb() {
  sqfliteFfiInit();
  return LocalDb.open(databaseFactoryFfiNoIsolate, inMemoryDatabasePath);
}

PdEvent ev(String s, int seq, [String type = 'msg.done']) => PdEvent(session: s, seq: seq, type: type, data: {'id': 'm$seq', 'text': 't$seq'}, createdAt: seq);

void main() {
  late LocalDb db;
  setUp(() async => db = await openTestDb());
  tearDown(() => db.db.close());

  test('事件缓存幂等、升序且每个会话最多 2000 条', () async {
    await db.cacheEvents('h', 's1', [for (var i = 1; i <= 1500; i++) ev('s1', i)]);
    await db.cacheEvents('h', 's1', [for (var i = 1400; i <= 2600; i++) ev('s1', i)]);
    await db.cacheEvents('h', 's2', [ev('s2', 3)]);
    final got = await db.cachedEvents('h', 's1');
    expect(got.length, LocalDb.eventCacheLimit);
    expect(got.first.seq, 601);
    expect(got.last.seq, 2600);
    expect(got.last.data['text'], 't2600');
    expect(await db.lastSeqs('h'), {'s1': 2600, 's2': 3});
    expect(await db.lastSeqs('other'), isEmpty);
  });

  test('未读、隐藏、草稿与短语', () async {
    await db.setUnread('h', 's1', 3);
    expect(await db.unreadCounts('h'), {'s1': 3});
    await db.hideSession('h', 's1');
    expect(await db.hiddenSessions('h'), {'s1'});
    await db.saveDraft('h', 's1', '草稿');
    expect(await db.draft('h', 's1'), '草稿');
    await db.saveDraft('h', 's1', '');
    expect(await db.draft('h', 's1'), '');
    await db.addPhrase(' 继续 ');
    await db.addPhrase('继续');
    await db.addPhrase('解释一下');
    expect(await db.phrases(), ['继续', '解释一下']);
    await db.removePhrase('继续');
    expect(await db.phrases(), ['解释一下']);
  });

  test('阅读位置按文件记录', () async {
    await db.savePosition('h', 'w', 'a.md', 'e1', 7);
    expect(await db.position('h', 'w', 'a.md'), 7);
    expect(await db.position('h', 'w', 'b.md'), 1);
  });

  test('已配对电脑保存与删除级联清理', () async {
    await db.saveHost(const PairedHost(id: 'h', name: '书房', addresses: ['192.168.1.2', '100.64.0.1'], port: 8443, fingerprint: 'ab'));
    await db.cacheEvents('h', 's', [ev('s', 1)]);
    final hosts = await db.hosts();
    expect(hosts.single.addresses, ['192.168.1.2', '100.64.0.1']);
    await db.deleteHost('h');
    expect(await db.hosts(), isEmpty);
    expect(await db.cachedEvents('h', 's'), isEmpty);
  });

  test('清理 7 天前的失败任务', () async {
    Map<String, Object?> row(String id, String status, int at) => {
          'id': id, 'host_id': 'h', 'direction': 'up', 'source_uri': '/x', 'dest_name': 'x', 'size': 1, 'status': status, 'created_at': at, 'date_folder': '20260101',
        };
    await db.saveTransfer(row('old', 'failed', 1));
    await db.saveTransfer(row('new', 'failed', 999999));
    await db.saveTransfer(row('done', 'done', 1));
    await db.saveParts('old', [{'idx': 0, 'offset_start': 0, 'offset_end': 1, 'status': 'queued'}]);
    expect(await db.purgeFailed(1000), ['old']);
    expect((await db.transfers('h')).map((r) => r['id']), unorderedEquals(['new', 'done']));
    expect(await db.parts('old'), isEmpty);
  });
}
