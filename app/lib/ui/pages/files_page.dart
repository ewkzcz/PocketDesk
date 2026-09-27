/**
 * 文件页：切换工作区、面包屑路径、排序、当前目录过滤与全工作区搜索；点击按类型查看，长按下载、重命名、移动、删除、复制路径、发给会话。
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../file_kinds.dart';
import '../format.dart';
import '../tokens.dart';
import '../viewers/open_file.dart';
import '../widgets.dart';
import 'chat_page.dart';
import 'dir_picker.dart';
import 'session_actions.dart';

/** 排序方式 */
const _sorts = [('', '默认'), ('name', '名称'), ('time', '时间'), ('size', '大小')];

/**
 * FilesPage：工作区浏览
 */
class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<Workspace> _workspaces = [];
  Workspace? _ws;
  String _path = '';
  List<FileEntry> _entries = [];
  bool _readOnly = false;
  bool _loading = false;
  String _error = '';
  String _sort = '';
  bool _desc = false;
  bool _hidden = false;
  final _filter = TextEditingController();
  bool _global = false;
  List<FileEntry>? _results;
  HostScope? _scope;
  int _req = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = context.watch<AppState>().scope;
    if (scope != _scope) {
      _scope = scope;
      _ws = null;
      _path = '';
      _entries = [];
      _workspaces = [];
      if (scope != null) unawaited(_loadWorkspaces());
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /** _loadWorkspaces：读取工作区列表 */
  Future<void> _loadWorkspaces() async {
    final scope = _scope;
    if (scope == null) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final list = await scope.conn.api.workspaces();
      if (!mounted || scope != _scope) return;
      setState(() {
        _workspaces = list;
        _ws = list.where((w) => w.id == _ws?.id).firstOrNull ?? list.firstOrNull;
      });
      if (_ws != null) {
        await _load();
      } else {
        setState(() => _loading = false);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    }
  }

  /**
   * _load：读取当前目录
   *
   * 处理流程：
   * 1、记录请求序号，丢弃过期的响应
   * 2、按排序与隐藏文件设置请求电脑
   */
  Future<void> _load() async {
    final ws = _ws;
    final scope = _scope;
    if (ws == null || scope == null) return;
    // 1、序号
    final req = ++_req;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // 2、请求
      final r = await scope.conn.api.list(ws.id, _path.isEmpty ? '.' : _path, sort: _sort, desc: _desc, hidden: _hidden);
      if (!mounted || req != _req) return;
      setState(() {
        _entries = r.entries;
        _readOnly = r.readOnly || ws.readOnly;
      });
    } on ApiException catch (e) {
      if (mounted && req == _req) setState(() => _error = e.message);
    } finally {
      if (mounted && req == _req) setState(() => _loading = false);
    }
  }

  /** _cd：进入目录 */
  void _cd(String p) {
    _path = p == '.' ? '' : p;
    _filter.clear();
    _results = null;
    _global = false;
    _load();
  }

  /** _up：返回上一级 */
  void _up() {
    final parts = _path.split('/')..removeLast();
    _cd(parts.join('/'));
  }

  /** _search：全工作区搜索 */
  Future<void> _search(String q) async {
    final ws = _ws;
    if (ws == null || q.trim().isEmpty) return;
    setState(() => _loading = true);
    try {
      final r = await _scope!.conn.api.search(ws.id, q.trim());
      if (mounted) setState(() => _results = r);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /** _pickSort：选择排序方式 */
  Future<void> _pickSort() async {
    final i = await actionSheet(context, [
      for (final s in _sorts) SheetAction(s.$2, icon: _sort == s.$1 ? LucideIcons.check300 : null),
      SheetAction(_desc ? '改为升序' : '改为降序', icon: LucideIcons.arrowUpDown300),
    ], title: '排序方式');
    if (i == null) return;
    setState(() {
      if (i < _sorts.length) {
        _sort = _sorts[i].$1;
      } else {
        _desc = !_desc;
      }
    });
    await _load();
  }

  /** _more：右上角菜单 */
  Future<void> _more() async {
    final i = await actionSheet(context, [
      SheetAction(_hidden ? '不显示隐藏文件' : '显示隐藏文件', icon: _hidden ? LucideIcons.eyeOff300 : LucideIcons.eye300),
      if (!_readOnly && _ws != null) const SheetAction('新建文件夹', icon: LucideIcons.folderPlus300),
      const SheetAction('刷新', icon: LucideIcons.refreshCw300),
    ]);
    if (i == null || !mounted) return;
    if (i == 0) {
      setState(() => _hidden = !_hidden);
      await _load();
    } else if (i == 1 && !_readOnly) {
      final name = await inputDialog(context, title: '新建文件夹', hint: '文件夹名称');
      if (name == null || name.trim().isEmpty) return;
      await _op(() => _scope!.conn.api.op(_ws!.id, 'mkdir', _path.isEmpty ? '.' : _path, name: name.trim()));
    } else {
      await _load();
    }
  }

  /** _op：执行文件操作并刷新 */
  Future<void> _op(Future<Object?> Function() f, {String done = ''}) async {
    try {
      await f();
      if (mounted && done.isNotEmpty) toast(context, done);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
    await _load();
  }

  /**
   * _longPress：长按菜单
   */
  Future<void> _longPress(FileEntry e) async {
    final ws = _ws!;
    final scope = _scope!;
    final canEdit = !_readOnly && (scope.conn.status?.features.fileEdit ?? true);
    final items = <(SheetAction, Future<void> Function())>[
      if (!e.isDir)
        (const SheetAction('下载到手机', icon: LucideIcons.download300), () async {
          await scope.transfers.download('ws:${ws.id}:${e.path}', e.name, e.size);
          if (mounted) toast(context, '已加入传输队列');
        }),
      if (canEdit)
        (const SheetAction('重命名', icon: LucideIcons.pencil300), () async {
          final n = await inputDialog(context, title: '重命名', initial: e.name);
          if (n == null || n.trim().isEmpty || n.trim() == e.name) return;
          await _op(() => scope.conn.api.op(ws.id, 'rename', e.path, name: n.trim()));
        }),
      if (canEdit)
        (const SheetAction('移动', icon: LucideIcons.folderInput300), () async {
          final dest = await pickDir(context, ws: ws, title: '移动到', action: '移动到这里');
          if (dest == null) return;
          await _op(() => scope.conn.api.op(ws.id, 'move', e.path, dest: dest), done: '已移动');
        }),
      (const SheetAction('复制路径', icon: LucideIcons.copy300), () async {
        await Clipboard.setData(ClipboardData(text: e.path));
        if (mounted) toast(context, '已复制');
      }),
      if (!e.isDir)
        (const SheetAction('发给会话', icon: LucideIcons.send300), () => _sendToSession(e)),
      if (canEdit)
        (const SheetAction('删除', icon: LucideIcons.trash2300, danger: true), () async {
          final ok = await confirm(context, title: '删除「${e.name}」', message: '文件会移到电脑的回收站，可以在电脑上恢复。', ok: '删除', danger: true);
          if (ok) await _op(() => scope.conn.api.op(ws.id, 'delete', e.path), done: '已移到回收站');
        }),
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1], title: e.name);
    if (i != null) await items[i].$2();
  }

  /** _sendToSession：把文件路径发到同一工作区的 Agent 会话输入框 */
  Future<void> _sendToSession(FileEntry e) async {
    final sessions = _scope!.sessions.sessions.where((s) => s.isAgent && s.workspaceId == _ws!.id).toList();
    if (sessions.isEmpty) {
      toast(context, '这个工作区还没有 Agent 会话');
      return;
    }
    final i = await actionSheet(context, [for (final s in sessions) SheetAction(sessionTitle(s))], title: '发给哪个会话');
    if (i == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: sessions[i].id, draft: '请查看工作区文件 `${e.path}` ')));
  }

  /** _open：点击文件或文件夹 */
  void _open(FileEntry e, List<FileEntry> siblings) {
    if (e.isDir) {
      _cd(e.path);
      return;
    }
    openWorkspaceFile(context, ws: _ws!, entry: e, siblings: siblings.where((x) => !x.isDir).toList(), readOnly: _readOnly);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = _scope;
    if (scope == null) {
      return const Scaffold(appBar: PdBar(title: '文件'), body: EmptyHint(icon: LucideIcons.folder300, text: '配对电脑后可以浏览电脑上的工作区'));
    }
    final q = _filter.text.trim().toLowerCase();
    final shown = _results ?? (q.isEmpty || _global ? _entries : _entries.where((e) => e.name.toLowerCase().contains(q)).toList());
    final parts = _path.isEmpty ? <String>[] : _path.split('/');
    final sortLabel = _sorts.firstWhere((s) => s.$1 == _sort).$2;
    return PopScope(
      canPop: _path.isEmpty && _results == null,
      onPopInvokedWithResult: (did, _) {
        if (did) return;
        if (_results != null) {
          setState(() {
            _results = null;
            _filter.clear();
          });
        } else {
          _up();
        }
      },
      child: Scaffold(
        appBar: PdBar(
          title: '文件',
          leading: parts.isNotEmpty ? PdIconButton(icon: LucideIcons.chevronLeft300, tooltip: '上一级', onTap: _up) : null,
          actions: [PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', onTap: _ws == null ? null : _more)],
        ),
        body: Column(children: [
          // 工作区切换
          if (_workspaces.length > 1)
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                itemCount: _workspaces.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final w = _workspaces[i];
                  final on = w.id == _ws?.id;
                  return GestureDetector(
                    onTap: () {
                      if (on) return;
                      setState(() => _ws = w);
                      _cd('');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: on ? c.accent : c.card, borderRadius: BorderRadius.circular(16)),
                      child: Text(w.name, style: TextStyle(fontSize: PdFont.summary, color: on ? Colors.white : c.text2)),
                    ),
                  );
                },
              ),
            ),
          // 搜索
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SearchField(
              controller: _filter,
              hint: _global ? '搜索整个工作区' : '查找当前目录（长按搜全部）',
              onChanged: (_) => setState(() {
                if (_filter.text.isEmpty) _results = null;
              }),
              onSubmitted: (v) {
                if (_global) _search(v);
              },
              onLongPress: () {
                setState(() {
                  _global = !_global;
                  _results = null;
                });
                toast(context, _global ? '已切换为全工作区搜索' : '已切换为当前目录查找');
              },
            ),
          ),
          if (_global) _GlobalSubmit(onSubmit: () => _search(_filter.text)),
          // 面包屑与排序
          Padding(
            padding: const EdgeInsets.fromLTRB(PdSize.gutter, 8, 8, 4),
            child: Row(children: [
              Expanded(
                // 路径较长时滚到末尾显示当前目录，较短时靠左
                child: LayoutBuilder(
                  builder: (context, box) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minWidth: box.maxWidth),
                      child: Row(children: [
                    _Crumb(text: _ws?.name ?? '', active: parts.isEmpty, onTap: () => _cd('')),
                    for (var i = 0; i < parts.length; i++) ...[
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Text('/', style: TextStyle(fontSize: PdFont.summary, color: c.text4))),
                      _Crumb(text: parts[i], active: i == parts.length - 1, onTap: () => _cd(parts.sublist(0, i + 1).join('/'))),
                    ],
                  ]),
                    ),
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _pickSort,
                style: TextButton.styleFrom(
                  foregroundColor: c.text2,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(_desc ? LucideIcons.arrowDownWideNarrow300 : LucideIcons.arrowUpNarrowWide300, size: 16),
                label: Text(sortLabel, style: const TextStyle(fontSize: PdFont.summary)),
              ),
            ]),
          ),
          if (_loading) LinearProgressIndicator(minHeight: 2, color: c.accent, backgroundColor: Colors.transparent),
          Expanded(
            child: _error.isNotEmpty
                ? EmptyHint(icon: LucideIcons.wifiOff300, text: _error, action: '重试', onAction: _ws == null ? _loadWorkspaces : _load)
                : _ws == null && !_loading
                    ? const EmptyHint(icon: LucideIcons.folderX300, text: '电脑上还没有添加工作区\n请在电脑端设置中添加')
                    : shown.isEmpty && !_loading
                        ? EmptyHint(icon: LucideIcons.folderOpen300, text: _results != null ? '没有找到匹配的文件' : '这里是空的')
                        : RefreshIndicator(
                            color: c.accent,
                            onRefresh: _load,
                            child: ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              itemCount: shown.length,
                              itemBuilder: (_, i) => _FileRow(
                                e: shown[i],
                                showPath: _results != null,
                                last: i == shown.length - 1,
                                onTap: () => _open(shown[i], shown),
                                onLongPress: () => _longPress(shown[i]),
                              ),
                            ),
                          ),
          ),
        ]),
      ),
    );
  }
}

/** _GlobalSubmit：全局搜索按钮 */
class _GlobalSubmit extends StatelessWidget {
  const _GlobalSubmit({required this.onSubmit});

  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerRight,
        child: TextButton(onPressed: onSubmit, child: const Text('在整个工作区中搜索')),
      );
}

/** _Crumb：面包屑中的一段 */
class _Crumb extends StatelessWidget {
  const _Crumb({required this.text, required this.active, required this.onTap});

  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: active ? null : onTap,
        child: Text(text, style: TextStyle(fontSize: PdFont.summary, color: active ? context.pd.text : context.pd.text3)),
      );
}

/**
 * _FileRow：文件或文件夹一行
 */
class _FileRow extends StatelessWidget {
  const _FileRow({required this.e, required this.onTap, required this.onLongPress, required this.last, this.showPath = false});

  final FileEntry e;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool last;
  final bool showPath;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final sub = showPath
        ? e.path
        : e.isDir
            ? [if (e.childCount >= 0) '${e.childCount} 项', formatAgo(e.modTime)].where((s) => s.isNotEmpty).join(' · ')
            : '${formatSize(e.size)} · ${formatAgo(e.modTime)}';
    return Material(
      color: c.card,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(children: [
          SizedBox(
            height: PdSize.fileItem,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter),
              child: Row(children: [
                FileIcon(name: e.name, isDir: e.isDir, dateFolder: e.dateFolder),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text)),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  ]),
                ),
                if (e.isDir) Icon(LucideIcons.chevronRight300, size: 18, color: c.text4),
              ]),
            ),
          ),
          if (!last) Padding(padding: const EdgeInsets.only(left: 68), child: Container(height: PdSize.divider, color: c.divider)),
        ]),
      ),
    );
  }
}
