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
  final Map<String, List<PdEvent>> _pendingCache = {};
  Timer? _flush;
  String? viewing;
  bool loaded = false;
  String query = '';

  /**
   * init：读取手机上删除的会话、未读数与缓存游标
   */
  Future<void> init() async {
    _hidden = await db.hiddenSessions(hostId);
    _unread = await db.unreadCounts(hostId);
    _cursors.addAll(await db.lastSeqs(hostId));
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
    }
    notifyListeners();
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

  /**
   * log：取会话的聊天记录，首次打开时先读缓存再向电脑补拉缺失部分
   *
   * 处理流程：
   * 1、已加载直接返回
   * 2、读取本地缓存
   * 3、从最后序号起分页补拉，写入缓存
   */
  Future<ChatLog> log(String id) async {
    // 1、已加载
    final existing = _logs[id];
    if (existing != null) return existing;
    final log = ChatLog(id);
    _logs[id] = log;
    // 2、缓存
    for (final e in await db.cachedEvents(hostId, id)) {
      log.apply(e);
    }
    // 3、补拉
    await catchUp(id);
    return log;
  }

  /** catchUp：补拉某会话 lastSeq 之后的事件 */
  Future<void> catchUp(String id) async {
    final log = _logs[id];
    if (log == null) return;
    try {
      while (true) {
        final evs = await api().events(id, after: log.lastSeq, limit: 500);
        for (final e in evs) {
          log.apply(e);
        }
        _cursors[id] = log.lastSeq;
        await db.cacheEvents(hostId, id, evs);
        if (evs.length < 500) break;
      }
      // 缓存为空的新会话只保留最近一段，更早的上滑时再加载
      notifyListeners();
    } on ApiException {
      // 离线时先展示缓存
      notifyListeners();
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
   * 1、全局事件：会话新建、更新、终端摘要变化
   * 2、会话事件：合并进已打开的聊天记录，更新列表摘要与状态
   * 3、不在该会话界面时累加未读
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
      }
      return;
    }
    // 2、会话事件
    final log = _logs[e.session];
    if (log != null && e.seq <= log.lastSeq) return;
    log?.apply(e);
    if (e.seq > (_cursors[e.session] ?? 0)) _cursors[e.session] = e.seq;
    final known = byId(e.session) != null;
    _patch(e.session, (s) => _summarize(s, e));
    if (!known) unawaited(refresh().catchError((Object _) {}));
    // 3、未读
    if (viewing != e.session && _countsUnread(e)) {
      _unread[e.session] = unread(e.session) + 1;
      unawaited(db.setUnread(hostId, e.session, _unread[e.session]!).catchError(_logDb));
    }
    // 4、缓存
    (_pendingCache[e.session] ??= []).add(e);
    _flush ??= Timer(const Duration(milliseconds: 500), _flushCache);
    notifyListeners();
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
        'msg.done' || 'approval.request' || 'error' => true,
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
