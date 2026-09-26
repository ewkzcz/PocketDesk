/**
 * 手机本地数据库：已配对电脑、传输队列与分段、会话与事件缓存、阅读位置、草稿、快捷短语、手机上删除的会话。
 */
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

/** LocalDb：本地数据库封装 */
class LocalDb {
  LocalDb(this.db);

  final Database db;

  /** 每个会话只缓存最近的事件数 */
  static const eventCacheLimit = 2000;

  /** schema：建表语句 */
  static const _schema = [
    'CREATE TABLE IF NOT EXISTS hosts (id TEXT PRIMARY KEY, name TEXT NOT NULL, addresses TEXT NOT NULL, port INTEGER NOT NULL, cert_fingerprint TEXT NOT NULL, device_id TEXT NOT NULL DEFAULT \'\', last_used INTEGER NOT NULL DEFAULT 0)',
    'CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY, host_id TEXT NOT NULL, direction TEXT NOT NULL, source_uri TEXT NOT NULL, dest_name TEXT NOT NULL, size INTEGER NOT NULL, fingerprint TEXT NOT NULL DEFAULT \'\', sha256 TEXT NOT NULL DEFAULT \'\', status TEXT NOT NULL, created_at INTEGER NOT NULL, date_folder TEXT NOT NULL, target TEXT NOT NULL DEFAULT \'\', remote TEXT NOT NULL DEFAULT \'\', result TEXT NOT NULL DEFAULT \'\', error TEXT NOT NULL DEFAULT \'\', done_bytes INTEGER NOT NULL DEFAULT 0, finished_at INTEGER NOT NULL DEFAULT 0, mime TEXT NOT NULL DEFAULT \'\')',
    'CREATE TABLE IF NOT EXISTS transfer_parts (transfer_id TEXT NOT NULL, idx INTEGER NOT NULL, offset_start INTEGER NOT NULL, offset_end INTEGER NOT NULL, tus_url TEXT NOT NULL DEFAULT \'\', confirmed_offset INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL, PRIMARY KEY (transfer_id, idx))',
    'CREATE TABLE IF NOT EXISTS session_cache (session_id TEXT NOT NULL, host_id TEXT NOT NULL, title TEXT NOT NULL, last_seq INTEGER NOT NULL, last_preview TEXT NOT NULL, unread INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (session_id, host_id))',
    'CREATE TABLE IF NOT EXISTS event_cache (host_id TEXT NOT NULL, session_id TEXT NOT NULL, seq INTEGER NOT NULL, type TEXT NOT NULL, data TEXT NOT NULL, created_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (host_id, session_id, seq))',
    'CREATE TABLE IF NOT EXISTS reading_pos (host_id TEXT NOT NULL, ws_id TEXT NOT NULL, rel_path TEXT NOT NULL, pdf_etag TEXT NOT NULL DEFAULT \'\', page INTEGER NOT NULL DEFAULT 1, offset REAL NOT NULL DEFAULT 0, PRIMARY KEY (host_id, ws_id, rel_path))',
    'CREATE TABLE IF NOT EXISTS drafts (host_id TEXT NOT NULL, session_id TEXT NOT NULL, text TEXT NOT NULL, PRIMARY KEY (host_id, session_id))',
    'CREATE TABLE IF NOT EXISTS phrases (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL UNIQUE)',
    'CREATE TABLE IF NOT EXISTS hidden_sessions (host_id TEXT NOT NULL, session_id TEXT NOT NULL, PRIMARY KEY (host_id, session_id))',
  ];

  /** open：打开数据库并建表；factory 与路径可替换，测试时用内存库 */
  static Future<LocalDb> open(DatabaseFactory factory, String path) async {
    final db = await factory.openDatabase(path, options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        for (final q in _schema) {
          await db.execute(q);
        }
      },
    ));
    return LocalDb(db);
  }

  /* ---------- 已配对电脑 ---------- */

  /** saveHost：保存或更新电脑 */
  Future<void> saveHost(PairedHost h) => db.insert('hosts', {
        'id': h.id,
        'name': h.name,
        'addresses': jsonEncode(h.addresses),
        'port': h.port,
        'cert_fingerprint': h.fingerprint,
        'device_id': h.deviceId,
        'last_used': h.lastUsed,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  /** hosts：全部电脑，最近使用的在前 */
  Future<List<PairedHost>> hosts() async {
    final rows = await db.query('hosts', orderBy: 'last_used DESC');
    return rows
        .map((r) => PairedHost(
              id: r['id']! as String,
              name: r['name']! as String,
              addresses: (jsonDecode(r['addresses']! as String) as List).map((e) => e.toString()).toList(),
              port: r['port']! as int,
              fingerprint: r['cert_fingerprint']! as String,
              deviceId: r['device_id']! as String,
              lastUsed: r['last_used']! as int,
            ))
        .toList();
  }

  /** deleteHost：删除电脑及其缓存 */
  Future<void> deleteHost(String id) async {
    await db.transaction((t) async {
      for (final table in ['hosts', 'session_cache', 'event_cache', 'reading_pos', 'drafts', 'hidden_sessions']) {
        await t.delete(table, where: table == 'hosts' ? 'id=?' : 'host_id=?', whereArgs: [id]);
      }
    });
  }

  /* ---------- 事件缓存 ---------- */

  /**
   * cacheEvents：写入事件缓存，并只保留每个会话最近 2000 条
   */
  Future<void> cacheEvents(String hostId, String sessionId, List<PdEvent> evs) async {
    if (evs.isEmpty) return;
    await db.transaction((t) async {
      final b = t.batch();
      for (final e in evs) {
        b.insert('event_cache', {'host_id': hostId, 'session_id': sessionId, 'seq': e.seq, 'type': e.type, 'data': jsonEncode(e.data), 'created_at': e.createdAt},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await b.commit(noResult: true);
      await t.rawDelete(
          'DELETE FROM event_cache WHERE host_id=? AND session_id=? AND seq <= (SELECT seq FROM event_cache WHERE host_id=? AND session_id=? ORDER BY seq DESC LIMIT 1 OFFSET ?)',
          [hostId, sessionId, hostId, sessionId, eventCacheLimit]);
    });
  }

  /** cachedEvents：读取缓存事件（升序） */
  Future<List<PdEvent>> cachedEvents(String hostId, String sessionId) async {
    final rows = await db.query('event_cache', where: 'host_id=? AND session_id=?', whereArgs: [hostId, sessionId], orderBy: 'seq ASC');
    return rows
        .map((r) => PdEvent(
              session: sessionId,
              seq: r['seq']! as int,
              type: r['type']! as String,
              data: (jsonDecode(r['data']! as String) as Map).cast<String, dynamic>(),
              createdAt: r['created_at']! as int,
            ))
        .toList();
  }

  /** lastSeqs：各会话缓存的最后序号，用于连接时补拉 */
  Future<Map<String, int>> lastSeqs(String hostId) async {
    final rows = await db.rawQuery('SELECT session_id, MAX(seq) AS s FROM event_cache WHERE host_id=? GROUP BY session_id', [hostId]);
    return {for (final r in rows) r['session_id']! as String: (r['s'] as int?) ?? 0};
  }

  /* ---------- 会话摘要与未读 ---------- */

  /** saveSessionCache：会话摘要与未读数 */
  Future<void> saveSessionCache(String hostId, SessionInfo s, {int? unread}) async {
    final old = await db.query('session_cache', where: 'session_id=? AND host_id=?', whereArgs: [s.id, hostId]);
    await db.insert('session_cache', {
      'session_id': s.id,
      'host_id': hostId,
      'title': s.title,
      'last_seq': s.lastSeq,
      'last_preview': s.preview,
      'unread': unread ?? (old.isEmpty ? 0 : old.first['unread']! as int),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /** unreadCounts：各会话未读数 */
  Future<Map<String, int>> unreadCounts(String hostId) async {
    final rows = await db.query('session_cache', columns: ['session_id', 'unread'], where: 'host_id=?', whereArgs: [hostId]);
    return {for (final r in rows) r['session_id']! as String: r['unread']! as int};
  }

  /** setUnread：设置未读数（会话尚未缓存时先建一条占位记录） */
  Future<void> setUnread(String hostId, String sessionId, int n) => db.rawInsert(
      "INSERT INTO session_cache (session_id, host_id, title, last_seq, last_preview, unread) VALUES (?, ?, '', 0, '', ?) "
      'ON CONFLICT(session_id, host_id) DO UPDATE SET unread=excluded.unread',
      [sessionId, hostId, n]);

  /* ---------- 手机上删除的会话 ---------- */

  /** hideSession：只在手机上删除，电脑上的会话保留 */
  Future<void> hideSession(String hostId, String sessionId) async {
    await db.insert('hidden_sessions', {'host_id': hostId, 'session_id': sessionId}, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.delete('event_cache', where: 'host_id=? AND session_id=?', whereArgs: [hostId, sessionId]);
    await db.delete('session_cache', where: 'host_id=? AND session_id=?', whereArgs: [hostId, sessionId]);
  }

  /** hiddenSessions：已在手机上删除的会话 */
  Future<Set<String>> hiddenSessions(String hostId) async {
    final rows = await db.query('hidden_sessions', where: 'host_id=?', whereArgs: [hostId]);
    return rows.map((r) => r['session_id']! as String).toSet();
  }

  /* ---------- 草稿与快捷短语 ---------- */

  /** saveDraft：保存未发送的草稿，空文本即删除 */
  Future<void> saveDraft(String hostId, String sessionId, String text) async {
    if (text.trim().isEmpty) {
      await db.delete('drafts', where: 'host_id=? AND session_id=?', whereArgs: [hostId, sessionId]);
      return;
    }
    await db.insert('drafts', {'host_id': hostId, 'session_id': sessionId, 'text': text}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /** draft：读取草稿 */
  Future<String> draft(String hostId, String sessionId) async {
    final rows = await db.query('drafts', where: 'host_id=? AND session_id=?', whereArgs: [hostId, sessionId]);
    return rows.isEmpty ? '' : rows.first['text']! as String;
  }

  /** phrases：快捷短语 */
  Future<List<String>> phrases() async => (await db.query('phrases', orderBy: 'id')).map((r) => r['text']! as String).toList();

  /** addPhrase：新增快捷短语 */
  Future<void> addPhrase(String text) => db.insert('phrases', {'text': text.trim()}, conflictAlgorithm: ConflictAlgorithm.ignore);

  /** removePhrase：删除快捷短语 */
  Future<void> removePhrase(String text) => db.delete('phrases', where: 'text=?', whereArgs: [text]);

  /* ---------- 阅读位置 ---------- */

  /** savePosition：记住文档阅读位置 */
  Future<void> savePosition(String hostId, String ws, String rel, String etag, int page) => db.insert('reading_pos',
      {'host_id': hostId, 'ws_id': ws, 'rel_path': rel, 'pdf_etag': etag, 'page': page}, conflictAlgorithm: ConflictAlgorithm.replace);

  /** position：读取阅读页码，没有记录时为 1 */
  Future<int> position(String hostId, String ws, String rel) async {
    final rows = await db.query('reading_pos', where: 'host_id=? AND ws_id=? AND rel_path=?', whereArgs: [hostId, ws, rel]);
    return rows.isEmpty ? 1 : rows.first['page']! as int;
  }

  /* ---------- 传输队列 ---------- */

  /** saveTransfer：保存或更新传输任务 */
  Future<void> saveTransfer(Map<String, Object?> row) => db.insert('transfers', row, conflictAlgorithm: ConflictAlgorithm.replace);

  /** transfers：某台电脑的全部传输任务，新的在前 */
  Future<List<Map<String, Object?>>> transfers(String hostId) => db.query('transfers', where: 'host_id=?', whereArgs: [hostId], orderBy: 'created_at DESC');

  /** deleteTransfer：删除任务与分段 */
  Future<void> deleteTransfer(String id) async {
    await db.delete('transfers', where: 'id=?', whereArgs: [id]);
    await db.delete('transfer_parts', where: 'transfer_id=?', whereArgs: [id]);
  }

  /** saveParts：保存分段 */
  Future<void> saveParts(String transferId, List<Map<String, Object?>> parts) async {
    await db.transaction((t) async {
      final b = t.batch();
      for (final p in parts) {
        b.insert('transfer_parts', {...p, 'transfer_id': transferId}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await b.commit(noResult: true);
    });
  }

  /** parts：读取分段 */
  Future<List<Map<String, Object?>>> parts(String transferId) => db.query('transfer_parts', where: 'transfer_id=?', whereArgs: [transferId], orderBy: 'idx');

  /** purgeFailed：清理超过 7 天的失败任务 */
  Future<List<String>> purgeFailed(int beforeMs) async {
    final rows = await db.query('transfers', columns: ['id'], where: "status='failed' AND created_at<?", whereArgs: [beforeMs]);
    final ids = rows.map((r) => r['id']! as String).toList();
    for (final id in ids) {
      await deleteTransfer(id);
    }
    return ids;
  }
}
