/**
 * 聊天页：与 Agent 或文件传输助手对话。消息在底部、上滑加载更早记录、不在底部时显示新消息浮标；支持斜杠指令、附件、语音、快捷短语、审批、长按菜单与多选。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../core/transfer_manager.dart';
import '../../data/chat.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../../transfer/naming.dart' as naming;
import '../../transfer/task.dart';
import '../chat/commands.dart';
import '../chat/input_bar.dart';
import '../chat/items.dart';
import '../chat/select_text_page.dart';
import '../format.dart';
import '../pick.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import '../file_kinds.dart';
import '../viewers/fetch.dart';
import '../viewers/open_file.dart';
import 'agent_pickers.dart';
import 'diff_page.dart';
import 'dir_picker.dart';
import 'session_actions.dart';
import 'session_settings_page.dart';
import 'settings_pages.dart' show TransferSettingsPage;
import 'terminal_page.dart';
import 'transfer_page.dart' show openLocal;

/**
 * ChatPage：聊天页
 */
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.sessionId, this.draft = '', this.focusApproval = ''});

  final String sessionId;

  /** 打开后直接弹出这条待审批（从通知进入时），空为不弹 */
  final String focusApproval;

  /** 打开时预填到输入框的文字（如从文件页发来的路径） */
  final String draft;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

/** _Entry：列表中的一行（聊天项，以及是否在它前面显示时间） */
typedef _Entry = ({ChatItem item, bool time, bool avatar});

class _ChatPageState extends State<ChatPage> {
  HostScope? _scope;
  ChatLog? _log;

  /** 在手机上删除的消息（按起始序号） */
  Set<int> _hidden = {};
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _rand = Random();
  List<Workspace> _workspaces = [];
  List<String> _phrases = [];
  int _seen = 0;
  int _newCount = 0;
  bool _atBottom = true;
  bool _loadingEarlier = false;
  String _quote = '';
  final List<TransferTask> _pending = [];
  bool _selecting = false;
  final Set<ChatItem> _selected = {};
  Timer? _draftTimer;
  bool _sending = false;

  /** 随下一条消息使用的 skill */
  List<SkillInfo> _skills = [];

  /** 所选模型供应商的名称（顶栏显示） */
  String _providerName = '';
  String _providerFor = '';

  String get _id => widget.sessionId;
  SessionInfo? get _session => _scope?.sessions.byId(_id);

  @override
  void initState() {
    super.initState();
    _scope = context.read<AppState>().scope;
    final scope = _scope;
    if (scope == null) return;
    scope.sessions.open(_id);
    scope.sessions.addListener(_onStore);
    scope.transfers.addListener(_onTransfers);
    _scroll.addListener(_onScroll);
    _input.addListener(_onInput);
    unawaited(_load());
  }

  @override
  void dispose() {
    final scope = _scope;
    if (scope != null) {
      scope.sessions.close(_id);
      scope.sessions.removeListener(_onStore);
      scope.transfers.removeListener(_onTransfers);
      _draftTimer?.cancel();
      unawaited(scope.sessions.db.saveDraft(scope.host.id, _id, _input.text));
    }
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /**
   * _load：读取草稿、聊天记录、工作区与快捷短语
   */
  Future<void> _load() async {
    final scope = _scope!;
    final db = scope.sessions.db;
    _input.text = widget.draft.isNotEmpty ? widget.draft : await db.draft(scope.host.id, _id);
    if (scope.sessions.byId(_id) == null) {
      try {
        await scope.sessions.refresh();
      } catch (_) {
        // 离线时使用缓存
      }
    }
    final log = await scope.sessions.log(_id);
    _hidden = await db.hiddenItems(scope.host.id, _id);
    if (!mounted) return;
    setState(() {
      _log = log;
      _seen = log.items.length;
    });
    _phrases = await db.phrases();
    // 从通知进入时直接弹出待审批
    if (widget.focusApproval.isNotEmpty) unawaited(_focusApproval());
    try {
      _workspaces = await scope.conn.api.workspaces();
      if (mounted) setState(() {});
    } catch (_) {
      // 离线时顶栏显示相对路径
    }
  }

  /**
   * _focusApproval：从通知进入时弹出那条待审批，直接在弹窗里允许或拒绝
   *
   * 处理流程：
   * 1、等聊天记录里出现这条审批（刚连上时可能还在补拉）
   * 2、仍待处理就弹出审批卡片，已处理则提示
   */
  Future<void> _focusApproval() async {
    // 1、等待
    ApprovalItem? a;
    for (var i = 0; i < 40 && mounted; i++) {
      a = _log?.items.whereType<ApprovalItem>().where((x) => widget.focusApproval == '*' ? x.status == ApprovalStatus.pending : x.id == widget.focusApproval).lastOrNull;
      if (a != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!mounted || a == null) return;
    // 2、弹出
    if (a.status != ApprovalStatus.pending) {
      toast(context, '这条审批已处理');
      return;
    }
    final item = a;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.pd.page,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
          child: ApprovalCard(
            item: item,
            onDecide: (x) {
              Navigator.of(ctx).pop();
              unawaited(_decide(item, x));
            },
          ),
        ),
      ),
    );
  }

  /** _onStore：新消息到达；不在底部时累计浮标数 */
  void _onStore() {
    final log = _log;
    if (log == null || !mounted) return;
    final n = log.items.length;
    if (n > _seen && !_atBottom) _newCount += n - _seen;
    _seen = n;
    setState(() {});
  }

  void _onTransfers() {
    if (_pending.isNotEmpty && mounted) setState(() {});
  }

  /** _onScroll：记录是否在底部，接近顶部时加载更早的消息 */
  void _onScroll() {
    final p = _scroll.position;
    final bottom = p.pixels < 80;
    if (bottom != _atBottom) {
      setState(() {
        _atBottom = bottom;
        if (bottom) _newCount = 0;
      });
    }
    if (p.pixels > p.maxScrollExtent - 400) unawaited(_loadEarlier());
  }

  /** _loadEarlier：上滑加载更早的消息 */
  Future<void> _loadEarlier() async {
    final log = _log;
    if (_loadingEarlier || log == null || !log.hasMoreBefore) return;
    setState(() => _loadingEarlier = true);
    try {
      await _scope!.sessions.loadEarlier(_id);
      _seen = log.items.length;
    } catch (_) {
      // 离线时保持已有记录
    } finally {
      if (mounted) setState(() => _loadingEarlier = false);
    }
  }

  /** _onInput：草稿延迟保存 */
  void _onInput() {
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(seconds: 1), () => _scope?.sessions.db.saveDraft(_scope!.host.id, _id, _input.text));
    setState(() {});
  }

  /** _toBottom：滚到最新 */
  void _toBottom() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: PdMotion.normal, curve: PdMotion.curve);
    setState(() => _newCount = 0);
  }

  PdApi get _api => _scope!.conn.api;

  /** 上一次发送失败的内容与编号，重发同一内容时沿用 */
  String _retryKey = '';
  String _retryId = '';

  /** _clientId：消息去重 ID */
  String _clientId() => '${DateTime.now().microsecondsSinceEpoch}${_rand.nextInt(1 << 30)}';

  /** _ws：当前会话的工作区 */
  Workspace? get _ws => _workspaces.where((w) => w.id == _session?.workspaceId).firstOrNull;

  /**
   * _send：发送输入框内容
   *
   * 处理流程：
   * 1、斜杠指令直接执行
   * 2、等待附件上传完成，取得附件路径
   * 3、拼上引用，发送给电脑；失败时恢复输入与附件，重发同一内容沿用同一编号
   */
  Future<void> _send() async {
    final s = _session;
    if (s == null || _sending) return;
    var text = _input.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    // 1、指令
    if (s.isAgent && text.startsWith('/') && _pending.isEmpty) {
      final name = text.split(RegExp(r'\s')).first.toLowerCase();
      if (slashCommands.any((c) => c.name == name) && name != '/compact') {
        _input.clear();
        await _runCommand(name, text.substring(name.length).trim());
        return;
      }
    }
    setState(() => _sending = true);
    try {
      // 2、附件
      final attachments = <String>[];
      for (final t in List.of(_pending)) {
        final done = await _scope!.transfers.wait(t);
        if (done.status != TaskStatus.done) {
          if (mounted) toast(context, '附件「${TransferManager.displayName(t)}」上传失败');
          return;
        }
        attachments.add('.pocketdesk/inbox/${done.dateFolder}/${done.result}');
      }
      // 3、发送
      if (_quote.isNotEmpty) text = '${_quote.split('\n').map((l) => '> $l').join('\n')}\n\n$text';
      final saved = _input.text;
      _input.clear();
      final quote = _quote;
      final pending = List.of(_pending);
      setState(() {
        _pending.clear();
        _quote = '';
      });
      // 同一内容重试时沿用同一编号：上次其实已送达（只是响应丢了）时电脑端不会重复执行
      final key = '$text|${attachments.join('|')}';
      if (key != _retryKey) {
        _retryKey = key;
        _retryId = _clientId();
      }
      try {
        if (s.isAssistant) {
          await _api.assistantText(text, clientId: _retryId);
        } else {
          await _api.sendMessage(_id, text, attachments: attachments, clientId: _retryId, skills: _skills);
          if (mounted) setState(() => _skills = []);
        }
        _retryKey = '';
        _toBottom();
      } on ApiException catch (e) {
        _input.text = saved;
        setState(() {
          _quote = quote;
          _pending.addAll(pending);
        });
        if (mounted) toast(context, e.offline ? '网络不稳定，消息可能未发送，可直接重发（不会重复）' : e.message);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /**
   * _runCommand：执行斜杠指令
   */
  Future<void> _runCommand(String name, String arg) async {
    final s = _session!;
    try {
      switch (name) {
        case '/stop':
          await _api.interrupt(_id);
        case '/diff':
          await _openDiff(null, const []);
        case '/model':
          await switchModel(context, s);
        case '/provider':
          await switchProvider(context, s);
        case '/skills':
          await _pickSkills();
        case '/cd':
          await _changeDir();
        case '/new':
          final n = await _api.createSession(s.kind, s.workspaceId, s.cwd, model: s.model);
          _scope!.sessions.upsert(n);
          if (mounted) await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: n.id)));
        case '/resume':
          await _resume();
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  /** _pickSkills：选择随下一条消息使用的 skill */
  Future<void> _pickSkills() async {
    final s = _session;
    if (s == null) return;
    if (!supportsProvider(s)) {
      toast(context, '这个 Agent 暂不支持 skill');
      return;
    }
    final picked = await Navigator.of(context).push<List<SkillInfo>>(MaterialPageRoute(builder: (_) => SkillsPage(session: s, picked: _skills)));
    if (picked != null && mounted) setState(() => _skills = picked);
  }

  /** _modelMenu：模型与供应商 */
  Future<void> _modelMenu(SessionInfo s) async {
    if (!supportsProvider(s)) return switchModel(context, s);
    final i = await actionSheet(context, const [SheetAction('切换模型', icon: LucideIcons.cpu300), SheetAction('模型供应商', icon: LucideIcons.server300)]);
    if (!mounted) return;
    if (i == 0) {
      await switchModel(context, s);
    } else if (i == 1) {
      await switchProvider(context, s);
    }
  }

  /** _changeDir：切换工作目录（限工作区内） */
  Future<void> _changeDir() async {
    final ws = _ws;
    if (ws == null) {
      toast(context, '电脑不在线');
      return;
    }
    final dir = await pickDir(context, ws: ws, start: _session!.cwd, title: '切换工作目录');
    if (dir == null) return;
    _scope!.sessions.upsert(await _api.patchSession(_id, cwd: dir));
    if (mounted) toast(context, '工作目录已切换');
  }

  /** _resume：从电脑上已有的会话中选一个接着聊 */
  Future<void> _resume() async {
    final s = _session!;
    final list = await _api.history(s.kind, s.workspaceId, s.cwd);
    if (!mounted) return;
    if (list.isEmpty) {
      toast(context, '这个目录下没有可以接着聊的会话');
      return;
    }
    final i = await actionSheet(context, [for (final h in list.take(30)) SheetAction(h.title.isEmpty ? '（无标题）' : h.title, subtitle: formatListTime(h.updatedAt))], title: '接着电脑上的会话聊');
    if (i == null) return;
    final n = await _api.createSession(s.kind, s.workspaceId, s.cwd, agentSessionId: list[i].id);
    _scope!.sessions.upsert(n);
    if (mounted) await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: n.id)));
  }

  /** _openDiff：查看改动 */
  Future<void> _openDiff(FileChange? file, List<FileChange> files) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiffPage(sessionId: _id, initial: file, files: files, ws: _ws)));
  }

  /** _attach：添加附件（文件传输助手直接发送，Agent 会话先上传到工作目录） */
  Future<void> _attach(List<Picked> files) async {
    final s = _session;
    if (s == null || files.isEmpty) return;
    // 文件传输助手里的文件直接发给电脑，发送前先确认
    if (s.isAssistant && !await confirmSend(context, [for (final f in files) f.name])) return;
    if (!mounted) return;
    final m = _scope!.transfers;
    for (final f in files) {
      final t = await m.upload(f.path, name: f.name, mime: f.mime, target: s.isAssistant ? 'assistant' : 'session:$_id');
      if (!s.isAssistant) _pending.add(t);
    }
    if (mounted) {
      setState(() {});
      if (s.isAssistant) toast(context, '正在发送到电脑');
    }
  }

  /** _pasteImage：发送剪贴板里的图片 */
  Future<void> _pasteImage() async {
    String? path;
    try {
      path = await context.read<AppState>().phone.device.clipboardImage();
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    if (path == null) {
      toast(context, '剪贴板里没有图片');
      return;
    }
    await _attach([(path: path, name: path.split('/').last, mime: naming.mimeForName(path))]);
  }

  /** _imageInserted：输入法插入的图片存到缓存后发送 */
  Future<void> _imageInserted(KeyboardInsertedContent c) async {
    final data = c.data;
    if (data == null || data.isEmpty) return;
    final ext = c.mimeType.split('/').last.replaceAll('jpeg', 'jpg');
    final dir = Directory('${context.read<AppState>().paths.temp.path}/paste');
    await dir.create(recursive: true);
    final f = File('${dir.path}/粘贴图片-${DateTime.now().millisecondsSinceEpoch}.$ext');
    await f.writeAsBytes(data);
    await _attach([(path: f.path, name: f.path.split('/').last, mime: c.mimeType)]);
  }

  /**
   * _panel：扩展面板操作
   */
  Future<void> _panel(String key) async {
    final s = _session;
    if (s == null) return;
    final cache = context.read<AppState>().paths.temp;
    try {
      switch (key) {
        case 'album':
          await _attach(await pickImages());
        case 'camera':
          await _attach(await takePhoto());
        case 'file':
          await _attach(await pickFiles(cache));
        case 'wsfile':
          final ws = _ws;
          if (ws == null) {
            toast(context, '电脑不在线');
            return;
          }
          final p = await pickWorkspaceFile(context, ws: ws, start: s.cwd);
          if (p != null) _insert('`$p` ');
        case 'phrases':
          await _phrasesSheet();
        case 'model':
          await _modelMenu(s);
        case 'skills':
          await _pickSkills();
        case 'stop':
          await _api.interrupt(_id);
        case 'terminal':
          if (!await context.read<AuthGate>().ensure('验证身份以打开终端') || !mounted) return;
          final t = await _api.createSession('terminal', s.workspaceId, s.cwd, cols: 80, rows: 24);
          _scope!.sessions.upsert(t);
          if (mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TerminalPage(sessionId: t.id)));
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } on PlatformException {
      if (mounted) toast(context, '没有权限，请在系统设置中允许');
    }
  }

  /** _insert：在光标处插入文字 */
  void _insert(String text) {
    final sel = _input.selection;
    final t = _input.text;
    final at = sel.isValid ? sel.start : t.length;
    _input.text = t.substring(0, at) + text + t.substring(sel.isValid ? sel.end : t.length);
    _input.selection = TextSelection.collapsed(offset: at + text.length);
    _focus.requestFocus();
  }

  /** _phrasesSheet：快捷短语（点一下直接发送，可添加、删除） */
  Future<void> _phrasesSheet() async {
    final db = _scope!.sessions.db;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _PhrasesSheet(phrases: _phrases, current: _input.text.trim(), onAdd: (p) async {
        await db.addPhrase(p);
        _phrases = await db.phrases();
        return _phrases;
      }, onRemove: (p) async {
        await db.removePhrase(p);
        _phrases = await db.phrases();
        return _phrases;
      }),
    );
    if (picked == null || !mounted) return;
    _input.text = picked;
    await _send();
  }

  /** _decide：审批 */
  Future<void> _decide(ApprovalItem a, String action) async {
    try {
      await _api.decide(a.id, action);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  /** _textOf：可复制的文字 */
  static String _textOf(ChatItem it) => switch (it) {
        final UserItem u => u.text,
        final AgentItem a => a.text,
        final SystemItem s => s.text,
        final ThinkingItem t => t.text,
        final ToolItem t => [t.summary, if (t.input.isNotEmpty) _toolInput(t.input), if (t.output.isNotEmpty) t.output].join('\n\n'),
        _ => '',
      };

  /** _toolInput：工具参数的文字 */
  static String _toolInput(Map<String, dynamic> input) {
    final cmd = input['command'];
    return cmd is String && input.length <= 2 ? cmd : const JsonEncoder.withIndent('  ').convert(input);
  }

  /**
   * _itemMenu：长按菜单（复制、选择文字、复制全部对话、引用回复、多选、转发、存为 md、删除）
   */
  Future<void> _itemMenu(ChatItem it) async {
    final text = _textOf(it);
    if (text.isEmpty) return;
    unawaited(HapticFeedback.selectionClick());
    final i = await actionSheet(context, const [
      SheetAction('复制', icon: LucideIcons.copy300),
      SheetAction('选择文字', icon: LucideIcons.textCursorInput300),
      SheetAction('复制全部对话', icon: LucideIcons.copyPlus300),
      SheetAction('引用回复', icon: LucideIcons.messageSquareQuote300),
      SheetAction('多选', icon: LucideIcons.listChecks300),
      SheetAction('转发到其他会话', icon: LucideIcons.forward300),
      SheetAction('存为 md 文件', icon: LucideIcons.fileDown300),
      SheetAction('删除', icon: LucideIcons.trash2300, danger: true),
    ]);
    if (!mounted) return;
    switch (i) {
      case 0:
        await _copy([it]);
      case 1:
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SelectTextPage(text: text, markdown: it is AgentItem || it is UserItem)));
      case 2:
        await _copy((_log?.items ?? const <ChatItem>[]).where((e) => !_hidden.contains(e.seq)));
      case 3:
        setState(() => _quote = text.length > 200 ? '${text.substring(0, 200)}…' : text);
        _focus.requestFocus();
      case 4:
        setState(() {
          _selecting = true;
          _selected
            ..clear()
            ..add(it);
        });
      case 5:
        await _forward([it]);
      case 6:
        await _saveMd([it]);
      case 7:
        _remove([it]);
    }
  }

  /** _localFile：文件消息在手机上的文件（图片用缩略图缓存，电脑发来且已接收的用接收结果），没有时返回空 */
  Future<File?> _localFile(FileItem f) async {
    if (viewKindOf(f.name) == ViewKind.image) return await (_thumbs[f.seq] ??= _thumb(f));
    if (f.up) return null;
    final t = _scope!.transfers.tasks.where((t) => t.source == 'outbox:${f.outboxId}').firstOrNull;
    final file = t != null && t.status == TaskStatus.done ? File(t.result) : null;
    return file != null && await file.exists() ? file : null;
  }

  /**
   * _fileMenu：长按文件或图片的菜单（打开、复制图片、分享、复制文件名、删除）
   *
   * 复制图片、分享需要文件已在手机上：图片会先取一份缩略图缓存，电脑发来的文件需要先接收。
   */
  Future<void> _fileMenu(FileItem f) async {
    unawaited(HapticFeedback.selectionClick());
    final image = viewKindOf(f.name) == ViewKind.image;
    final acts = <(SheetAction, Future<void> Function())>[
      (const SheetAction('打开', icon: LucideIcons.externalLink300), () => _fileTap(f)),
      if (image)
        (const SheetAction('复制图片', icon: LucideIcons.copy300), () async {
          final file = await _localFile(f);
          if (!mounted) return;
          if (file == null) return toast(context, '图片还没有取到手机上，稍后再试');
          final ok = await context.read<AppState>().phone.device.copyImage(file.path, mime: naming.mimeForName(f.name));
          if (mounted) toast(context, ok ? '已复制图片' : '复制失败');
        }),
      (const SheetAction('分享', icon: LucideIcons.share2300), () async {
        final file = await _localFile(f);
        if (!mounted) return;
        if (file == null) return toast(context, f.up ? '先点开文件预览后再分享' : '文件还没接收，先点一下接收');
        await shareFile(file.path, title: f.name);
      }),
      (const SheetAction('复制文件名', icon: LucideIcons.fileText300), () async {
        await Clipboard.setData(ClipboardData(text: f.name));
        if (mounted) toast(context, '已复制');
      }),
      (const SheetAction('删除', icon: LucideIcons.trash2300, danger: true), () async => _remove([f])),
    ];
    final i = await actionSheet(context, [for (final a in acts) a.$1], title: f.name);
    if (i != null && mounted) await acts[i].$2();
  }

  /** _joined：多条消息合并为文字 */
  String _joined(Iterable<ChatItem> items) {
    final order = _log?.items ?? const [];
    final sorted = items.toList()..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    return sorted.map(_textOf).where((t) => t.isNotEmpty).join('\n\n');
  }

  Future<void> _copy(Iterable<ChatItem> items) async {
    await Clipboard.setData(ClipboardData(text: _joined(items)));
    if (mounted) toast(context, '已复制');
  }

  /** _forward：转发到其他会话 */
  Future<void> _forward(Iterable<ChatItem> items) async {
    final text = _joined(items);
    final targets = _scope!.sessions.sessions.where((s) => s.id != _id && (s.isAgent || s.isAssistant)).toList();
    if (targets.isEmpty) {
      toast(context, '没有其他会话');
      return;
    }
    final i = await actionSheet(context, [for (final s in targets) SheetAction(sessionTitle(s))], title: '转发到');
    if (i == null) return;
    try {
      final t = targets[i];
      if (t.isAssistant) {
        await _api.assistantText(text, clientId: _clientId());
      } else {
        await _api.sendMessage(t.id, text, clientId: _clientId());
      }
      if (mounted) toast(context, '已转发');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  /** _saveMd：存为 md 文件并分享 */
  Future<void> _saveMd(Iterable<ChatItem> items) async {
    final dir = context.read<AppState>().paths.temp;
    await dir.create(recursive: true);
    final now = DateTime.now();
    final name = '消息-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch % 100000}.md';
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsString(_joined(items));
    await shareFile(f.path, title: name);
  }

  /** _remove：只从手机上隐藏消息 */
  void _remove(Iterable<ChatItem> items) {
    final seqs = items.map((e) => e.seq).toList();
    setState(() {
      _hidden.addAll(seqs);
      _selecting = false;
      _selected.clear();
    });
    unawaited(_scope!.sessions.db.hideItems(_scope!.host.id, _id, seqs));
  }

  /**
   * _fileTap：点击文件消息
   *
   * 处理流程：
   * 1、发到电脑的文件：从电脑上读取，用 App 内阅读器预览
   * 2、电脑发来的：已收到时打开手机上的文件，否则开始接收
   */
  Future<void> _fileTap(FileItem f) async {
    final m = _scope!.transfers;
    // 1、发到电脑的
    if (f.up) {
      await _previewOnComputer(f);
      return;
    }
    final t = m.tasks.where((t) => t.source == 'outbox:${f.outboxId}').firstOrNull;
    if (t != null && t.status == TaskStatus.done) {
      await openLocal(context, t.result);
    } else if (t != null) {
      toast(context, '正在接收，可在「传输」中查看进度');
    } else if (f.outboxId.isNotEmpty) {
      await m.download('outbox:${f.outboxId}', f.name, f.size, sha: f.sha256);
      if (mounted) toast(context, '开始接收');
    }
  }

  /**
   * _previewOnComputer：通过「此电脑」读取文件并在 App 内预览
   *
   * 处理流程：
   * 1、较早的消息没有完整路径时，用当前收件目录拼出位置
   * 2、换算为「此电脑」中的相对路径后按类型打开
   */
  Future<void> _previewOnComputer(FileItem f) async {
    if (f.path.isEmpty && f.relPath.isEmpty) {
      toast(context, '已发送到电脑');
      return;
    }
    try {
      // 1、完整路径
      var abs = f.path;
      if (abs.isEmpty) {
        final inbox = (await _api.dirs()).inbox;
        final sep = inbox.contains('\\') ? '\\' : '/';
        abs = '$inbox$sep${f.relPath.replaceAll('/', sep)}';
      }
      // 2、打开
      final list = await _api.workspaces();
      final pc = list.where((w) => w.system).firstOrNull;
      final rel = pc?.relOf(abs) ?? '';
      if (!mounted) return;
      if (pc == null || rel.isEmpty) {
        toast(context, '已保存到电脑：$abs');
        return;
      }
      await openWorkspaceFile(context, ws: pc, entry: FileEntry(name: f.name, path: rel, isDir: false, size: f.size, modTime: 0), siblings: const []);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  /** _savedTo：发到电脑的文件所在文件夹，取最后两级（如 Inbox/20260927） */
  static String _savedTo(FileItem f) {
    final parts = f.path.replaceAll('\\', '/').split('/')..removeLast();
    return parts.length >= 2 ? parts.sublist(parts.length - 2).join('/') : parts.join('/');
  }

  /** 图片消息的缩略图，按消息序号缓存，避免每次重绘都重新读取 */
  final Map<int, Future<File?>> _thumbs = {};

  /** _fileBubble：图片显示缩略图，其他文件显示卡片 */
  Widget _fileBubble(FileItem f) {
    final card = FileBubble(item: f, status: _fileStatus(f), onTap: () => _fileTap(f));
    if (viewKindOf(f.name) != ViewKind.image) return card;
    final bubble = ImageBubble(image: _thumbs[f.seq] ??= _thumb(f), fallback: card, onTap: () => _fileTap(f));
    return f.up ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [bubble]) : bubble;
  }

  /**
   * _thumb：图片在手机上的文件
   *
   * 处理流程：
   * 1、电脑发来的：已接收的直接用手机上的文件
   * 2、发到电脑的：通过「此电脑」取一份到缓存
   */
  Future<File?> _thumb(FileItem f) async {
    final scope = _scope!;
    final app = context.read<AppState>();
    // 1、电脑发来的
    if (!f.up) {
      final t = scope.transfers.tasks.where((t) => t.source == 'outbox:${f.outboxId}').firstOrNull;
      if (t == null || t.status != TaskStatus.done) {
        _thumbs.removeWhere((k, _) => k == f.seq);
        return null;
      }
      final file = File(t.result);
      return await file.exists() ? file : null;
    }
    // 2、发到电脑的
    try {
      var abs = f.path;
      if (abs.isEmpty && f.relPath.isNotEmpty) {
        final inbox = (await _api.dirs()).inbox;
        final sep = inbox.contains('\\') ? '\\' : '/';
        abs = '$inbox$sep${f.relPath.replaceAll('/', sep)}';
      }
      final list = _workspaces.isNotEmpty ? _workspaces : await _api.workspaces();
      final pc = list.where((w) => w.system).firstOrNull;
      final rel = pc?.relOf(abs) ?? '';
      if (pc == null || rel.isEmpty) return null;
      return (await fetchWsFile(scope, pc.id, rel, cacheFileFor(app, pc.id, rel, sub: 'thumb'))).file;
    } catch (_) {
      _thumbs.removeWhere((k, _) => k == f.seq);
      return null;
    }
  }

  /** _fileStatus：文件消息的状态文字 */
  String _fileStatus(FileItem f) {
    if (f.up) {
      if (f.path.isNotEmpty) return '已存到电脑 ${_savedTo(f)}';
      final i = f.relPath.lastIndexOf('/');
      return i > 0 ? '已存到电脑 ${f.relPath.substring(0, i)}' : '已发送';
    }
    final t = _scope!.transfers.tasks.where((t) => t.source == 'outbox:${f.outboxId}').firstOrNull;
    if (t == null) return '点击接收';
    return switch (t.status) {
      TaskStatus.done => '已保存到手机',
      TaskStatus.running => '接收中 ${(t.progress * 100).round()}%',
      TaskStatus.failed => '接收失败',
      _ => '等待接收',
    };
  }

  /** _entries：生成列表行（时间间隔超过 5 分钟显示时间，连续的 Agent 内容只显示一次头像） */
  List<_Entry> _entries(ChatLog log) {
    final out = <_Entry>[];
    var lastAt = 0;
    var lastAgent = false;
    for (final it in log.items) {
      if (_hidden.contains(it.seq)) continue;
      final time = it.at > 0 && it.at - lastAt > 5 * 60 * 1000;
      if (it.at > 0) lastAt = it.at;
      final agentSide = it is AgentItem || it is ThinkingItem || it is ToolItem || it is ApprovalItem || it is DiffItem || (it is FileItem && !it.up);
      out.add((item: it, time: time, avatar: agentSide && (!lastAgent || time)));
      lastAgent = agentSide;
    }
    return out;
  }

  /** _itemWidget：一项聊天内容 */
  Widget _itemWidget(_Entry e, SessionInfo s) {
    final it = e.item;
    final kind = s.kind;
    Widget agent(Widget child) => AgentRow(kind: kind, showAvatar: e.avatar, child: child);
    final w = switch (it) {
      final UserItem u => UserBubble(item: u),
      final AgentItem a => agent(AgentBubble(item: a)),
      final ThinkingItem t => agent(ThinkingBlock(item: t)),
      final ToolItem t => agent(ToolCard(item: t)),
      final ApprovalItem a => agent(ApprovalCard(item: a, onDecide: (x) => _decide(a, x))),
      final DiffItem d => agent(DiffCard(item: d, onOpen: (f) => _openDiff(f, d.files))),
      final SystemItem m => SystemNote(item: m, onRetry: () => _api.retry(_id).catchError((Object _) {})),
      final FileItem f => f.up ? _fileBubble(f) : agent(_fileBubble(f)),
    };
    final selectable = it is UserItem || it is AgentItem || it is ToolItem || it is ThinkingItem;
    Widget row = GestureDetector(
      onLongPress: !_selecting ? (selectable ? () => _itemMenu(it) : (it is FileItem ? () => _fileMenu(it) : null)) : null,
      onTap: _selecting && selectable
          ? () => setState(() {
                if (!_selected.remove(it)) _selected.add(it);
              })
          : null,
      child: w,
    );
    if (_selecting && selectable) {
      row = Row(children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Icon(_selected.contains(it) ? LucideIcons.circleCheck300 : LucideIcons.circle300, size: 22, color: _selected.contains(it) ? context.pd.accent : context.pd.text4),
        ),
        Expanded(child: row),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [if (e.time) TimeDivider(it.at), row]),
    );
  }

  /** _panelItems：扩展面板内容 */
  List<PanelItem> _panelItems(SessionInfo s) => [
        const PanelItem('album', '相册', LucideIcons.image300),
        const PanelItem('camera', '拍摄', LucideIcons.camera300),
        const PanelItem('file', '文件', LucideIcons.file300),
        if (s.isAgent) const PanelItem('wsfile', '工作区文件', LucideIcons.folderOpen300),
        const PanelItem('phrases', '快捷短语', LucideIcons.messageSquareText300),
        if (s.isAgent) PanelItem('model', supportsProvider(s) ? '模型与供应商' : '切换模型', LucideIcons.cpu300),
        if (supportsProvider(s)) const PanelItem('skills', 'Skills', LucideIcons.sparkles300),
        if (s.isAgent) const PanelItem('stop', '打断', LucideIcons.circleStop300),
        if (s.isAgent && (_scope?.conn.status?.features.terminal ?? false)) const PanelItem('terminal', '终端', LucideIcons.squareTerminal300),
      ];

  /** _subtitle：顶栏小字（工作目录与模型） */
  String _subtitle(SessionInfo s) {
    if (s.isAssistant) return _scope?.host.name ?? '';
    final ws = _ws?.name ?? '';
    final dir = s.cwd == '.' || s.cwd.isEmpty ? ws : (ws.isEmpty ? s.cwd : '$ws/${s.cwd}');
    if (_providerFor != s.provider) {
      _providerFor = s.provider;
      _providerName = '';
      if (s.provider.isNotEmpty) {
        unawaited(providerName(_api, s).then((n) {
          if (mounted && _providerFor == s.provider) setState(() => _providerName = n);
        }));
      }
    }
    return [dir, _providerName, s.model, if (s.autoApprove) '免审批', if (s.muted) '已关闭提醒'].where((x) => x.isNotEmpty).join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = _scope;
    final s = _session;
    final log = _log;
    if (scope == null || s == null || log == null) {
      return Scaffold(appBar: const PdBar(title: ''), body: Center(child: CircularProgressIndicator(color: c.accent)));
    }
    final entries = _entries(log);
    final cmds = s.isAgent ? matchCommands(_input.text) : const <SlashCommand>[];
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (did, _) {
        if (!did) setState(() => _selecting = false);
      },
      child: Scaffold(
        appBar: _selecting
            ? PdBar(
                title: '已选择 ${_selected.length} 条',
                leading: PdIconButton(icon: LucideIcons.x300, tooltip: '取消', onTap: () => setState(() => _selecting = false)),
              )
            : PdBar(
                title: sessionTitle(s),
                subtitle: _subtitle(s),
                actions: [
                  if (s.isAssistant)
                    PdIconButton(
                      icon: LucideIcons.folderCog300,
                      tooltip: '收发目录',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TransferSettingsPage())),
                    ),
                  PdIconButton(
                    icon: LucideIcons.ellipsis300,
                    tooltip: '会话设置',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SessionSettingsPage(sessionId: _id, ws: _ws))),
                  ),
                ],
              ),
        body: Column(children: [
          if (!scope.conn.online) _OfflineStrip(onRetry: () => scope.conn.connect()),
          Expanded(
            child: GestureDetector(
              onTap: () => _focus.unfocus(),
              child: Stack(children: [
                ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  itemCount: entries.length + 1,
                  itemBuilder: (context, i) {
                    if (i == entries.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Center(
                          child: _loadingEarlier
                              ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c.text3))
                              : Text(log.hasMoreBefore ? '上滑加载更早的消息' : (entries.isEmpty ? '发一条消息开始吧' : ''), style: TextStyle(fontSize: PdFont.tiny, color: c.text4)),
                        ),
                      );
                    }
                    final e = entries[entries.length - 1 - i];
                    return KeyedSubtree(key: ObjectKey(e.item), child: _itemWidget(e, s));
                  },
                ),
                if (_newCount > 0 && !_atBottom)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: GestureDetector(
                      onTap: _toBottom,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(
                          color: c.card,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [BoxShadow(color: PdDarkUi.shadow, blurRadius: 8)],
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(LucideIcons.arrowDown300, size: 14, color: c.accent),
                          const SizedBox(width: 4),
                          Text('$_newCount 条新消息', style: TextStyle(fontSize: PdFont.time, color: c.accent)),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          if (_selecting)
            _SelectBar(
              enabled: _selected.isNotEmpty,
              onCopy: () => _copy(_selected),
              onForward: () => _forward(_selected),
              onSave: () => _saveMd(_selected),
              onDelete: () => _remove(_selected),
            )
          else ...[
            if (s.busy) _BusyStrip(awaiting: s.state == SessionState.awaiting, onStop: () => _api.interrupt(_id).catchError((Object _) {})),
            if (cmds.isNotEmpty)
              CommandPopup(items: cmds, onPick: (cmd) {
                _input.text = '${cmd.name} ';
                _input.selection = TextSelection.collapsed(offset: _input.text.length);
                if (cmd.name != '/compact') unawaited(_send());
              })
            else if (_skills.isNotEmpty)
              SizedBox(
                height: 42,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 12, 6), children: [
                  for (final k in _skills) ...[
                    QuickChip(
                      label: k.name,
                      icon: LucideIcons.sparkles300,
                      trailing: LucideIcons.x300,
                      accent: true,
                      onTap: () => setState(() => _skills = [for (final x in _skills) if (x.path != k.path) x]),
                    ),
                    const SizedBox(width: 8),
                  ],
                  QuickChip(label: '修改', icon: LucideIcons.pencil300, onTap: _pickSkills),
                ]),
              )
            else if (s.isAgent && _input.text.isEmpty)
              SizedBox(
                height: 42,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 6, 12, 6), children: [
                  QuickChip(label: '/diff 查看改动', onTap: () => _runCommand('/diff', '')),
                  const SizedBox(width: 8),
                  QuickChip(label: '/model 切换模型', onTap: () => _runCommand('/model', '')),
                  if (supportsProvider(s)) ...[
                    const SizedBox(width: 8),
                    QuickChip(label: '/skills 选用 skill', onTap: () => _runCommand('/skills', '')),
                  ],
                ]),
              ),
            ChatInputBar(
              controller: _input,
              focus: _focus,
              onSend: _send,
              panel: _panelItems(s),
              onPanel: _panel,
              showSlash: s.isAgent,
              quote: _quote,
              onClearQuote: () => setState(() => _quote = ''),
              onPasteImage: _pasteImage,
              onImageInserted: _imageInserted,
              attachments: [
                for (final t in _pending)
                  (
                    name: TransferManager.displayName(t),
                    status: t.status == TaskStatus.done ? '' : (t.status == TaskStatus.failed ? '失败' : '${(t.progress * 100).round()}%'),
                    remove: () {
                      setState(() => _pending.remove(t));
                      unawaited(_scope!.transfers.cancel(t));
                    },
                  ),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

/** _OfflineStrip：离线提示 */
class _OfflineStrip extends StatelessWidget {
  const _OfflineStrip({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Material(
      color: c.warnBg,
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 8),
          child: Row(children: [
            Icon(LucideIcons.wifiOff300, size: 16, color: c.warnText),
            const SizedBox(width: 8),
            Expanded(child: Text('电脑不在线，重连后自动补齐消息', style: TextStyle(fontSize: PdFont.time, color: c.warnText))),
            Text('重试', style: TextStyle(fontSize: PdFont.time, color: c.accent)),
          ]),
        ),
      ),
    );
  }
}

/** _BusyStrip：执行中提示与打断按钮 */
class _BusyStrip extends StatelessWidget {
  const _BusyStrip({required this.awaiting, required this.onStop});

  final bool awaiting;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(children: [
        if (awaiting)
          Icon(LucideIcons.shieldAlert300, size: 14, color: c.danger)
        else
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.accent)),
        const SizedBox(width: 8),
        Expanded(child: Text(awaiting ? '等待你确认' : '正在执行…', style: TextStyle(fontSize: PdFont.time, color: awaiting ? c.danger : c.text3))),
        TextButton.icon(
          onPressed: onStop,
          style: TextButton.styleFrom(foregroundColor: c.text2, minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 8)),
          icon: const Icon(LucideIcons.circleStop300, size: 16),
          label: const Text('打断', style: TextStyle(fontSize: PdFont.time)),
        ),
      ]),
    );
  }
}

/** _SelectBar：多选操作栏 */
class _SelectBar extends StatelessWidget {
  const _SelectBar({required this.enabled, required this.onCopy, required this.onForward, required this.onSave, required this.onDelete});

  final bool enabled;
  final VoidCallback onCopy;
  final VoidCallback onForward;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    Widget btn(IconData i, String label, VoidCallback f, {bool danger = false}) => Expanded(
          child: InkWell(
            onTap: enabled ? f : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Icon(i, size: 22, color: !enabled ? c.text4 : (danger ? c.danger : c.text2)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: PdFont.tiny, color: !enabled ? c.text4 : c.text3)),
              ]),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          btn(LucideIcons.copy300, '复制', onCopy),
          btn(LucideIcons.forward300, '转发', onForward),
          btn(LucideIcons.fileDown300, '存为 md', onSave),
          btn(LucideIcons.trash2300, '删除', onDelete, danger: true),
        ]),
      ),
    );
  }
}

/**
 * _PhrasesSheet：快捷短语
 */
class _PhrasesSheet extends StatefulWidget {
  const _PhrasesSheet({required this.phrases, required this.current, required this.onAdd, required this.onRemove});

  final List<String> phrases;
  final String current;
  final Future<List<String>> Function(String) onAdd;
  final Future<List<String>> Function(String) onRemove;

  @override
  State<_PhrasesSheet> createState() => _PhrasesSheetState();
}

class _PhrasesSheetState extends State<_PhrasesSheet> {
  late List<String> _list = widget.phrases;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
            child: Row(children: [
              Expanded(child: Text('快捷短语', style: TextStyle(fontSize: PdFont.listTitle, fontWeight: FontWeight.w600, color: c.text))),
              TextButton.icon(
                onPressed: () async {
                  final p = await inputDialog(context, title: '添加快捷短语', initial: widget.current, maxLines: 4, ok: '添加');
                  if (p == null || p.trim().isEmpty) return;
                  final l = await widget.onAdd(p.trim());
                  if (mounted) setState(() => _list = l);
                },
                icon: const Icon(LucideIcons.plus300, size: 18),
                label: const Text('添加'),
              ),
            ]),
          ),
          if (_list.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Text('保存常用的提示词，点一下就能发送', textAlign: TextAlign.center, style: TextStyle(color: c.text3, fontSize: 14))),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _list.length,
              separatorBuilder: (_, _) => const InsetDivider(),
              itemBuilder: (_, i) => PdCell(
                title: _list[i],
                arrow: false,
                onTap: () => Navigator.pop(context, _list[i]),
                trailing: PdIconButton(
                  icon: LucideIcons.trash2300,
                  tooltip: '删除',
                  size: 18,
                  color: c.text3,
                  onTap: () async {
                    final l = await widget.onRemove(_list[i]);
                    if (mounted) setState(() => _list = l);
                  },
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
