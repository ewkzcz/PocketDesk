/**
 * 位置：在「此电脑」中选择任意文件夹、为新会话选择工作目录（默认工作目录优先），以及工作空间管理（添加、移除、设为默认）。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'dir_picker.dart';

/** _load：读取工作区列表，分出「此电脑」（旧版电脑端没有时为空） */
Future<(Workspace?, List<Workspace>)?> _load(BuildContext context) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return null;
  try {
    final list = await scope.conn.api.workspaces();
    return (list.where((w) => w.system).firstOrNull, list.where((w) => !w.system).toList());
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  }
}

/**
 * pickComputerFolder：在「此电脑」中选择任意文件夹，返回电脑上的完整路径；从个人文件夹开始浏览
 */
Future<String?> pickComputerFolder(BuildContext context, {String title = '选择文件夹', String action = '选择此文件夹'}) async {
  final r = await _load(context);
  final pc = r?.$1;
  if (pc == null || !context.mounted) {
    if (context.mounted && r != null) toast(context, '请先升级电脑端');
    return null;
  }
  final rel = await pickDir(context, ws: pc, start: pc.home, title: title, action: action);
  return rel == null ? null : pc.absPath(rel);
}

/** WorkDir：新会话的工作区与其中的目录 */
typedef WorkDir = ({Workspace ws, String cwd});

/**
 * pickWorkDir：为新会话或终端选择工作目录
 *
 * 处理流程：
 * 1、默认工作目录排第一，其次是已添加的工作空间
 * 2、最后一项在「此电脑」中选择任意文件夹
 */
Future<WorkDir?> pickWorkDir(BuildContext context, {required String title}) async {
  final r = await _load(context);
  if (r == null || !context.mounted) return null;
  final (pc, list) = r;
  // 1、工作空间
  final i = await actionSheet(context, [
    for (final w in list) SheetAction(w.name, icon: w.isDefault ? LucideIcons.house300 : LucideIcons.folder300, subtitle: w.isDefault ? '默认工作目录 · ${w.rootPath}' : w.rootPath),
    if (pc != null) const SheetAction('选择其他文件夹…', icon: LucideIcons.folderSearch300),
  ], title: title);
  if (i == null || !context.mounted) return null;
  if (i < list.length) return (ws: list[i], cwd: '.');
  if (pc == null) return null;
  // 2、此电脑
  final rel = await pickDir(context, ws: pc, start: pc.home, title: '选择工作目录', action: '在这里打开');
  return rel == null ? null : (ws: pc, cwd: rel);
}

/**
 * WorkspacesPage：工作空间管理
 */
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({super.key});

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  List<Workspace>? _list;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final r = await _load(context);
    if (mounted) setState(() => _list = r?.$2 ?? []);
  }

  /** _run：执行操作，失败提示，成功刷新 */
  Future<void> _run(Future<void> Function(PdApi api) f, {String done = ''}) async {
    final api = context.read<AppState>().scope?.conn.api;
    if (api == null) return;
    try {
      await f(api);
      if (mounted && done.isNotEmpty) toast(context, done);
      await _reload();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  /** _add：选择电脑上的文件夹添加为工作空间 */
  Future<void> _add() async {
    final p = await pickComputerFolder(context, title: '添加工作空间', action: '添加这个文件夹');
    if (p != null) await _run((api) => api.addWorkspace(p), done: '已添加');
  }

  /** _changeDefault：更换默认工作目录 */
  Future<void> _changeDefault() async {
    final p = await pickComputerFolder(context, title: '默认工作目录', action: '设为默认工作目录');
    if (p != null) await _run((api) => api.setDefaultWorkspace(p), done: '已更换默认工作目录');
  }

  /** _actions：单个工作空间的操作 */
  Future<void> _actions(Workspace w) async {
    final items = <(SheetAction, Future<void> Function())>[
      if (!w.isDefault) (const SheetAction('设为默认工作目录', icon: LucideIcons.house300), () => _run((api) => api.setDefaultWorkspace(w.rootPath), done: '已设为默认')),
      if (!w.isDefault)
        (const SheetAction('移除', icon: LucideIcons.trash2300, danger: true), () async {
          if (await confirm(context, title: '移除「${w.name}」', message: '只从列表中移除，电脑上的文件不受影响。', ok: '移除', danger: true)) {
            await _run((api) => api.removeWorkspace(w.id));
          }
        }),
    ];
    if (items.isEmpty) return _changeDefault();
    final i = await actionSheet(context, [for (final x in items) x.$1], title: w.rootPath);
    if (i != null) await items[i].$2();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final list = _list;
    return Scaffold(
      appBar: PdBar(title: '工作空间', actions: [PdIconButton(icon: LucideIcons.folderPlus300, tooltip: '添加工作空间', onTap: _add)]),
      body: list == null
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : ListView(padding: const EdgeInsets.only(top: 16), children: [
              PdGroup(
                footer: '新建会话、打开终端时可以直接选这些文件夹，也可以在「此电脑」中选择任意文件夹。',
                children: [
                  for (final w in list)
                    PdCell(
                      icon: w.isDefault ? LucideIcons.house300 : LucideIcons.folder300,
                      title: w.isDefault ? '${w.name}（默认）' : w.name,
                      subtitle: w.rootPath,
                      onTap: () => _actions(w),
                    ),
                ],
              ),
              PdGroup(children: [
                PdCell(icon: LucideIcons.folderPlus300, title: '添加工作空间', onTap: _add),
                PdCell(icon: LucideIcons.house300, title: '更换默认工作目录', onTap: _changeDefault),
              ]),
            ]),
    );
  }
}
