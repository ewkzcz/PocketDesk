/**
 * 会话仓库：会话列表、未读、置顶、手机端删除、聊天记录的缓存与补拉，实时事件分发到对应会话。
 */
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/chat.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../net/api.dart';
import 'app_log.dart';
import 'safe_notifier.dart';

/** SessionsStore：一台电脑的会话数据 */
class SessionsStore extends ChangeNotifier with SafeNotifier {
  SessionsStore({required this.db, required this.hostId, required this.api});

  final LocalDb db;
  final String hostId;

  /** 取当前接口客户端（连接切换地址后会变化） */
  final PdApi Function() api;

  List<SessionInfo> _all = [];
  Set<String> _hidden = {};
  Map<String, int> _unread = {};
  final Map<String, ChatLog> _logs = {};
  final Map<String, int> _cursors = {};

  /** 各会话已计入摘要与未读的最大序号 */
  final Map<String, int> _seen = {};

  /** 正在补拉的会话，以及补拉期间又发现缺口、需要再拉一次的会话 */
  final Set<String> _catching = {};
  final Set<String> _catchAgain = {};
  final Map<String, List<PdEvent>> _pendingCache = {};
  Timer? _flush;
  String? viewing;

  /** onRead：会话标为已读时回调（清除系统通知） */
  void Function(String id)? onRead;
  bool loaded = false;
  String query = '';

  /**
   * init：读取手机上删除的会话、未读数与缓存游标
   */
  Future<void> init() async {
    _hidden = await db.hiddenSessions(hostId);
    _unread = await db.unreadCounts(hostId);
    _cursors.addAll(await db.lastSeqs(hostId));
    _seen.addAll(_cursors);
  }

  /** sessions：可见会话（置顶优先、按更新时间倒序，支持搜索） */
  List<SessionInfo> get sessions {
    final q = query.trim().toLowerCase();
    final list = _all.where((s) => !_hidden.contains(s.id)).where((s) {
      if (q.isEmpty) return true;
      if (s.title.toLowerCase().contains(q) || s.preview.toLowerCase().contains(q)) return true;
      final log = _logs[s.id];
      if (log == null) return false;
      return log.items.any((it) => switch (it) {
            final UserItem u => u.text.toLowerCase().contains(q),
            final AgentItem a => a.text.toLowerCase().contains(q),
            _ => false,
          });
    }).toList();
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return list;
  }

  /** byId：取会话 */
  SessionInfo? byId(String id) => _all.where((s) => s.id == id).firstOrNull;

  /** unread：未读数 */
  int unread(String id) => _unread[id] ?? 0;

  /** totalUnread：全部未读（底部 Tab 角标） */
  int get totalUnread => sessions.fold(0, (s, x) => s + unread(x.id));

  /** cursors：各会话最后收到的序号，连接时发给电脑补发 */
  Map<String, int> cursors() => Map.of(_cursors)..removeWhere((k, _) => _hidden.contains(k));

  /**
   * refresh：从电脑拉取会话列表
   */
  Future<void> refresh() async {
    final list = await api().sessions();
    _all = list;
    loaded = true;
    for (final s in list) {
      unawaited(db.saveSessionCache(hostId, s).catchError(_logDb));
      // 已打开的会话落后太多时（电脑端不再补发），重新取最近一段
      final log = _logs[s.id];
      if (log != null && s.lastSeq - log.lastSeq > _gapLimit) unawaited(_resync(s.id, s.lastSeq));
    }
    notifyListeners();
  }

  /** _resync：用最近 200 条替换已打开会话的聊天记录 */
  Future<void> _resync(String id, int remote) async {
    try {
      final recent = await api().events(id, before: remote + 1, limit: 200);
      _logs[id]?.reset(recent);
      if (recent.isNotEmpty) _cursors[id] = recent.last.seq;
      await db.clearEvents(hostId, id);
      await db.cacheEvents(hostId, id, recent);
      notifyListeners();
    } catch (e) {
      _logDb(e);
    }
  }

  /** upsert：新建或更新一个会话 */
  void upsert(SessionInfo s) {
    final i = _all.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      _all[i] = s;
    } else {
      _all.add(s);
      _hidden.remove(s.id);
    }
    notifyListeners();
  }

  /** 缓存落后超过这么多条时，只取最近一段，不从头补拉 */
  static const _gapLimit = 1000;

  /**
   * log：取会话的聊天记录，首次打开时先读缓存再向电脑补拉缺失部分
   *
   * 处理流程：
   * 1、已加载直接返回
   * 2、读取本地缓存
   * 3、没有缓存或缓存落后太多时，只取最近 200 条（更早的上滑时再加载），避免一次拉取全部历史
   * 4、从最后序号起分页补拉，写入缓存
   */
  Future<ChatLog> log(String id) async {
    // 1、已加载
    final existing = _logs[id];
    if (existing != null) return existing;
    var log = ChatLog(id);
    _logs[id] = log;
    // 2、缓存
    for (final e in await db.cachedEvents(hostId, id)) {
      log.apply(e);
    }
    // 3、最近一段
    final remote = byId(id)?.lastSeq ?? 0;
    if (remote - log.lastSeq > _gapLimit || (log.lastSeq == 0 && remote > 200)) {
      try {
        final recent = await api().events(id, before: remote + 1, limit: 200);
        log = ChatLog(id)..prepend(recent);
        _logs[id] = log;
        // 旧缓存与最近一段不连续，丢弃后只缓存最近一段
        await db.clearEvents(hostId, id).catchError(_logDb);
        await db.cacheEvents(hostId, id, recent).catchError(_logDb);
      } on ApiException {
        // 离线时先展示缓存
      }
    }
    // 4、补拉
    await catchUp(id);
    return log;
  }

  /**
   * catchUp：补拉某会话 lastSeq 之后的事件
   *
   * 处理流程：
   * 1、同一会话同时只补拉一次，期间再次请求的在结束后重拉
   * 2、分页拉取并按序号合并，写入缓存
   */
  Future<void> catchUp(String id) async {
    final log = _logs[id];
    if (log == null) return;
    // 1、合并并发请求
    if (!_catching.add(id)) {
      _catchAgain.add(id);
      return;
    }
    try {
      do {
        _catchAgain.remove(id);
        // 2、分页拉取
        while (true) {
          final evs = await api().events(id, after: log.lastSeq, limit: 500);
          for (final e in evs) {
            log.apply(e);
          }
          _cursors[id] = log.lastSeq;
          if (log.lastSeq > (_seen[id] ?? 0)) _seen[id] = log.lastSeq;
          await db.cacheEvents(hostId, id, evs).catchError(_logDb);
          if (evs.length < 500) break;
        }
      } while (_catchAgain.contains(id));
      notifyListeners();
    } on ApiException {
      // 离线时先展示缓存，重连就绪后会再次补拉
      notifyListeners();
    } finally {
      _catching.remove(id);
    }
  }

  /** loadEarlier：上滑加载更早的 200 条 */
  Future<bool> loadEarlier(String id) async {
    final log = _logs[id];
    if (log == null || !log.hasMoreBefore) return false;
    final evs = await api().events(id, before: log.firstSeq, limit: 200);
    if (evs.isEmpty) {
      log.firstSeq = 1;
      return false;
    }
    log.prepend(evs);
    notifyListeners();
    return true;
  }

  /** loaded：已加载的聊天记录（不触发加载） */
  ChatLog? loadedLog(String id) => _logs[id];

  /**
   * onEvent：处理实时事件
   *
   * 处理流程：
   * 1、全局事件：会话新建、更新、终端摘要变化；重连就绪后刷新列表并补齐已打开的会话
   * 2、会话事件：按序号去重；已打开的会话出现序号缺口时向电脑补拉（含本条），不直接拼接；
   *    未打开的会话只在序号连续时写入缓存并推进游标，有缺口时留到打开时补拉
   * 3、更新列表摘要与状态；不在该会话界面时累加未读（按已处理的最大序号去重），删除过的会话收到新消息时重新显示
   * 4、批量写入缓存
   */
  void onEvent(PdEvent e) {
    // 1、全局事件
    if (e.session.isEmpty) {
      switch (e.type) {
        case 'session.created' || 'session.updated':
          upsert(SessionInfo.fromJson(e.data));
        case 'session.preview':
          _patch(Json.str(e.data['session']), (s) => s.copyWith(preview: Json.str(e.data['preview'])));
        case 'ready':
          unawaited(refresh().catchError((Object _) {}));
          for (final id in _logs.keys.toList()) {
            unawaited(catchUp(id));
          }
      }
      return;
    }
    // 2、去重与缺口
    final id = e.session;
    final log = _logs[id];
    var cache = false;
    if (log != null) {
      if (e.seq <= log.lastSeq) return;
      if (log.lastSeq > 0 && e.seq > log.lastSeq + 1) {
        unawaited(catchUp(id));
      } else {
        log.apply(e);
        _cursors[id] = log.lastSeq;
        cache = true;
      }
    } else {
      final cursor = _cursors[id] ?? 0;
      if (cursor == 0 || e.seq == cursor + 1) {
        _cursors[id] = e.seq;
        cache = true;
      }
    }
    // 3、摘要与未读（同一序号只处理一次，重连补发不会重复计数）
    if (e.seq <= (_seen[id] ?? 0)) {
      if (cache) _queueCache(e);
      return;
    }
    _seen[id] = e.seq;
    final known = byId(id) != null;
    _patch(id, (s) => _summarize(s, e));
    if (!known) unawaited(refresh().catchError((Object _) {}));
    if (_countsUnread(e) && _hidden.remove(id)) {
      unawaited(db.unhideSession(hostId, id).catchError(_logDb));
    }
    if (viewing != id && _countsUnread(e)) {
      _unread[id] = unread(id) + 1;
      unawaited(db.setUnread(hostId, id, _unread[id]!).catchError(_logDb));
    }
    // 4、缓存
    if (cache) _queueCache(e);
    notifyListeners();
  }

  /** _queueCache：事件加入待写缓存，500 毫秒后批量写入 */
  void _queueCache(PdEvent e) {
    (_pendingCache[e.session] ??= []).add(e);
    _flush ??= Timer(const Duration(milliseconds: 500), _flushCache);
  }

  /** _logDb：本地缓存写入失败只记录日志，不影响界面 */
  static void _logDb(Object e) => AppLog.w('db', '缓存写入失败：$e');

  /** _flushCache：批量写缓存，避免流式片段逐条写库 */
  Future<void> _flushCache() async {
    _flush = null;
    final pending = Map.of(_pendingCache);
    _pendingCache.clear();
    for (final entry in pending.entries) {
      await db.cacheEvents(hostId, entry.key, entry.value).catchError(_logDb);
    }
  }

  /** _countsUnread：哪些事件算作新消息 */
  static bool _countsUnread(PdEvent e) => switch (e.type) {
        'msg.done' || 'msg.host' || 'approval.request' || 'error' => true,
        'file' => Json.str(e.data['direction']) == 'down',
        _ => false,
      };

  /** _summarize：根据事件更新列表中的状态与摘要（与电脑端规则一致） */
  static SessionInfo _summarize(SessionInfo s, PdEvent e) {
    final d = e.data;
    final at = e.createdAt > 0 ? e.createdAt : DateTime.now().millisecondsSinceEpoch;
    String one(String t, int n) {
      final flat = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      return flat.length > n ? '${flat.substring(0, n)}…' : flat;
    }

    return switch (e.type) {
      'state' => s.copyWith(state: Json.str(d['state']), updatedAt: at, lastSeq: e.seq),
      'msg.user' => s.copyWith(preview: '你：${one(Json.str(d['text']), 60)}', updatedAt: at, lastSeq: e.seq),
      'msg.host' => s.copyWith(preview: '电脑：${one(Json.str(d['text']), 60)}', updatedAt: at, lastSeq: e.seq),
      'msg.done' => s.copyWith(preview: one(Json.str(d['text']), 60), updatedAt: at, lastSeq: e.seq),
      'approval.request' => s.copyWith(preview: '待确认：${one(Json.str(d['summary']), 50)}', updatedAt: at, lastSeq: e.seq),
      'error' => s.copyWith(preview: '出错：${one(Json.str(d['message']), 50)}', updatedAt: at, lastSeq: e.seq),
      'diff.summary' => s.copyWith(preview: '已完成：改动了 ${Json.list(d['files']).length} 个文件', updatedAt: at, lastSeq: e.seq),
      'file' => s.copyWith(preview: _filePreview(Json.str(d['name']), Json.str(d['mime'])), updatedAt: at, lastSeq: e.seq),
      'session.model' => s.copyWith(model: Json.str(d['model']), lastSeq: e.seq),
      _ => s.copyWith(lastSeq: e.seq),
    };
  }

  /** _filePreview：文件消息摘要 */
  static String _filePreview(String name, String mime) {
    final lower = name.toLowerCase();
    final img = mime.startsWith('image/') || ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic'].any(lower.endsWith);
    return img ? '[图片] $name' : '[文件] $name';
  }

  /** _patch：修改列表中的会话 */
  void _patch(String id, SessionInfo Function(SessionInfo) fn) {
    final i = _all.indexWhere((x) => x.id == id);
    if (i >= 0) _all[i] = fn(_all[i]);
  }

  /** markRead：标为已读 */
  Future<void> markRead(String id) async {
    onRead?.call(id);
    if (unread(id) == 0) return;
    _unread[id] = 0;
    notifyListeners();
    await db.setUnread(hostId, id, 0);
  }

  /** markUnread：标为未读（左滑菜单） */
  Future<void> markUnread(String id) async {
    _unread[id] = 1;
    notifyListeners();
    await db.setUnread(hostId, id, 1);
  }

  /** togglePin：置顶或取消置顶 */
  Future<void> togglePin(String id) async {
    final s = byId(id);
    if (s == null) return;
    _patch(id, (x) => x.copyWith(pinned: !s.pinned));
    notifyListeners();
    try {
      upsert(await api().patchSession(id, pinned: !s.pinned));
    } on ApiException {
      _patch(id, (x) => x.copyWith(pinned: s.pinned));
      notifyListeners();
      rethrow;
    }
  }

  /** hide：只在手机上删除记录，电脑上的会话保留 */
  Future<void> hide(String id) async {
    _hidden.add(id);
    _logs.remove(id);
    _cursors.remove(id);
    _unread.remove(id);
    notifyListeners();
    await db.hideSession(hostId, id);
  }

  /** open / close：进入或离开聊天界面，进入时清空未读 */
  void open(String id) {
    viewing = id;
    unawaited(markRead(id));
  }

  /** close：离开聊天界面 */
  void close(String id) {
    if (viewing == id) viewing = null;
  }

  @override
  void dispose() {
    _flush?.cancel();
    unawaited(_flushCache());
    super.dispose();
  }
}
