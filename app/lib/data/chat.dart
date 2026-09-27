/**
 * 聊天记录模型：把会话事件按序号归并为气泡、工具卡片、审批卡片、改动卡片、系统提示与文件消息。
 */
library;

import 'models.dart';

/** ChatItem：聊天中的一项 */
sealed class ChatItem {
  ChatItem(this.seq, this.at);

  /** 产生此项的第一个事件序号 */
  final int seq;

  /** 事件时间（毫秒） */
  final int at;
}

/** UserItem：我发出的消息 */
class UserItem extends ChatItem {
  UserItem(super.seq, super.at, {required this.text, this.attachments = const [], this.queued = false, this.delegate = '', this.fileName = ''});

  final String text;
  final List<String> attachments;
  bool queued;
  final String delegate;
  final String fileName;
}

/** AgentItem：Agent 的回复文本 */
class AgentItem extends ChatItem {
  AgentItem(super.seq, super.at, {required this.id, required this.text, this.agent = '', this.streaming = true});

  final String id;
  String text;
  final String agent;
  bool streaming;
}

/** ThinkingItem：思考过程，默认折叠 */
class ThinkingItem extends ChatItem {
  ThinkingItem(super.seq, super.at, {required this.id, this.text = ''});

  final String id;
  String text;
  bool done = false;
}

/** ToolItem：工具调用卡片 */
class ToolItem extends ChatItem {
  ToolItem(super.seq, super.at, {required this.id, required this.name, required this.kind, required this.summary, this.input = const {}, this.agent = ''});

  final String id;
  final String name;
  final String kind;
  final String summary;
  final Map<String, dynamic> input;
  final String agent;
  String output = '';
  bool isError = false;
  bool done = false;
}

/** 审批状态 */
abstract final class ApprovalStatus {
  static const pending = 'pending';
  static const allowed = 'allowed';
  static const denied = 'denied';
  static const expired = 'expired';
}

/** ApprovalItem：审批卡片 */
class ApprovalItem extends ChatItem {
  ApprovalItem(super.seq, super.at, {required this.id, required this.tool, required this.kind, required this.summary, this.input = const {}, this.expiresAt = 0});

  final String id;
  final String tool;
  final String kind;
  final String summary;
  final Map<String, dynamic> input;
  final int expiresAt;
  String status = ApprovalStatus.pending;
  bool always = false;
}

/** DiffItem：本轮改动卡片 */
class DiffItem extends ChatItem {
  DiffItem(super.seq, super.at, {required this.files, required this.git});

  final List<FileChange> files;
  final bool git;
}

/** SystemItem：灰色居中的系统提示，出错时为红色并可重试 */
class SystemItem extends ChatItem {
  SystemItem(super.seq, super.at, {required this.text, this.error = false, this.retryable = false});

  final String text;
  final bool error;
  final bool retryable;
}

/** FileItem：文件消息（文件传输助手） */
class FileItem extends ChatItem {
  FileItem(super.seq, super.at, {required this.up, required this.name, required this.size, this.relPath = '', this.path = '', this.outboxId = '', this.mime = '', this.sha256 = ''});

  final bool up;
  final String name;
  final int size;
  final String relPath;

  /** path：文件在电脑上的完整路径（手机发出的为收件目录中的位置，电脑发来的为发件目录中的位置） */
  final String path;
  final String outboxId;
  final String mime;
  final String sha256;
}

/** Usage：累计用量 */
class Usage {
  int inputTokens = 0;
  int outputTokens = 0;
  double costUsd = 0;
  int turns = 0;
}

/**
 * ChatLog：一个会话的聊天记录，按序号幂等地合并事件
 */
class ChatLog {
  ChatLog(this.sessionId);

  final String sessionId;
  final List<ChatItem> items = [];
  final Map<String, ChatItem> _byKey = {};
  final Usage usage = Usage();
  int lastSeq = 0;
  int firstSeq = 0;
  String state = SessionState.idle;
  String model = '';

  /**
   * apply：合并一条事件，返回是否产生了变化
   *
   * 处理流程：
   * 1、丢弃已处理过的序号
   * 2、按事件类型新增或更新聊天项
   * 3、记录首尾序号
   */
  bool apply(PdEvent e) {
    // 1、去重
    if (e.seq <= lastSeq && e.seq != 0) return false;
    // 2、归并
    _merge(e, append: true);
    // 3、序号
    if (e.seq > 0) {
      lastSeq = e.seq;
      if (firstSeq == 0) firstSeq = e.seq;
    }
    return true;
  }

  /**
   * prepend：上滑加载更早的事件（按升序传入），插入到最前面
   */
  void prepend(List<PdEvent> older) {
    final fresh = older.where((e) => firstSeq == 0 || e.seq < firstSeq).toList();
    if (fresh.isEmpty) return;
    final rebuilt = ChatLog(sessionId);
    for (final e in fresh) {
      rebuilt._merge(e, append: true);
    }
    items.insertAll(0, rebuilt.items);
    rebuilt._byKey.forEach((k, v) => _byKey.putIfAbsent(k, () => v));
    firstSeq = fresh.first.seq;
    if (lastSeq == 0) lastSeq = fresh.last.seq;
  }

  /**
   * reset：用最近一段事件替换全部内容（与电脑相差太多、改为只取最近一段时），保持对象不变以便界面继续引用
   */
  void reset(List<PdEvent> recent) {
    items.clear();
    _byKey.clear();
    usage
      ..inputTokens = 0
      ..outputTokens = 0
      ..costUsd = 0
      ..turns = 0;
    lastSeq = 0;
    firstSeq = 0;
    prepend(recent);
  }

  /** hasMoreBefore：是否还有更早的事件可以加载 */
  bool get hasMoreBefore => firstSeq > 1;

  /** pendingApprovals：未处理的审批数 */
  int get pendingApprovals => items.whereType<ApprovalItem>().where((a) => a.status == ApprovalStatus.pending).length;

  /** _merge：按类型合并 */
  void _merge(PdEvent e, {required bool append}) {
    final d = e.data;
    String str(String k) => Json.str(d[k]);
    void add(String? key, ChatItem it) {
      items.add(it);
      if (key != null) _byKey[key] = it;
    }

    switch (e.type) {
      case 'state':
        state = str('state');
      case 'session.model':
        model = str('model');
      case 'msg.user':
        final f = Json.map(d['file']);
        add(null, UserItem(e.seq, e.createdAt,
            text: str('text'),
            attachments: Json.list(d['attachments']).map((x) => x.toString()).toList(),
            queued: Json.boolean(d['queued']),
            delegate: str('delegate'),
            fileName: Json.str(f['name'])));
      case 'msg.delta':
        final key = 'm:${str('id')}';
        final cur = _byKey[key];
        if (cur is AgentItem) {
          cur.text += str('text');
        } else {
          add(key, AgentItem(e.seq, e.createdAt, id: str('id'), text: str('text'), agent: str('agent')));
        }
      case 'msg.done':
        final key = 'm:${str('id')}';
        final cur = _byKey[key];
        if (cur is AgentItem) {
          cur.text = str('text');
          cur.streaming = false;
        } else {
          add(key, AgentItem(e.seq, e.createdAt, id: str('id'), text: str('text'), agent: str('agent'), streaming: false));
        }
      case 'thinking':
        final key = 't:${str('id')}';
        var cur = _byKey[key];
        if (cur is! ThinkingItem) {
          if (Json.boolean(d['done']) && str('text').isEmpty) break;
          cur = ThinkingItem(e.seq, e.createdAt, id: str('id'));
          add(key, cur);
        }
        final t = cur;
        if (Json.boolean(d['delta'])) {
          t.text += str('text');
        } else if (str('text').isNotEmpty) {
          t.text = str('text');
        }
        if (Json.boolean(d['done'])) t.done = true;
      case 'tool.start':
        add('tool:${str('id')}', ToolItem(e.seq, e.createdAt,
            id: str('id'), name: str('name'), kind: str('kind'), summary: str('summary').isEmpty ? str('name') : str('summary'), input: Json.map(d['input']), agent: str('agent')));
      case 'tool.end':
        final cur = _byKey['tool:${str('id')}'];
        if (cur is ToolItem) {
          cur.output = str('output');
          cur.isError = Json.boolean(d['isError']);
          cur.done = true;
        }
      case 'approval.request':
        add('ap:${str('id')}', ApprovalItem(e.seq, e.createdAt,
            id: str('id'), tool: str('tool'), kind: str('kind'), summary: str('summary'), input: Json.map(d['input']), expiresAt: Json.integer(d['expiresAt'])));
      case 'approval.done':
        final cur = _byKey['ap:${str('id')}'];
        if (cur is ApprovalItem) {
          cur.status = str('status');
          cur.always = Json.boolean(d['always']);
        }
      case 'diff.summary':
        add(null, DiffItem(e.seq, e.createdAt, files: Json.list(d['files']).map((x) => FileChange.fromJson(Json.map(x))).toList(), git: Json.boolean(d['git'])));
      case 'usage':
        usage.inputTokens += Json.integer(d['inputTokens']);
        usage.outputTokens += Json.integer(d['outputTokens']);
        final c = d['costUsd'];
        if (c is num) usage.costUsd += c.toDouble();
        usage.turns++;
      case 'error':
        add(null, SystemItem(e.seq, e.createdAt, text: str('message'), error: true, retryable: Json.boolean(d['retryable'])));
      case 'system':
        final text = str('text');
        if (text == '开始处理排队消息') {
          for (final it in items.whereType<UserItem>()) {
            if (it.queued) {
              it.queued = false;
              break;
            }
          }
        }
        add(null, SystemItem(e.seq, e.createdAt, text: text));
      case 'file':
        add(null, FileItem(e.seq, e.createdAt,
            up: str('direction') == 'up',
            name: str('name'),
            size: Json.integer(d['size']),
            relPath: str('relPath'),
            path: str('path'),
            outboxId: str('outboxId'),
            mime: str('mime'),
            sha256: str('sha256')));
    }
  }
}
