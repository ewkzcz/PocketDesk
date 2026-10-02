/**
 * Agent 选项：切换模型与模型供应商（电脑上 CC Switch 的供应商）。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../widgets.dart';

/** supportsProvider：可以切换供应商与 skill 的 Agent */
bool supportsProvider(SessionInfo s) => s.kind == 'claude' || s.kind == 'codex';

/** _patch：修改会话，成功返回新会话 */
Future<SessionInfo?> _patch(BuildContext context, Future<SessionInfo> Function(PdApi api) f) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return null;
  try {
    final s = await f(scope.conn.api);
    scope.sessions.upsert(s);
    return s;
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  }
}

/**
 * switchModel：切换模型
 *
 * 处理流程：
 * 1、取可选模型（选了供应商时包含该供应商配置的模型）
 * 2、列表中选一个，也可以恢复默认或手动填写
 */
Future<void> switchModel(BuildContext context, SessionInfo s) async {
  final api = context.read<AppState>().scope?.conn.api;
  if (api == null) return;
  // 1、可选模型
  List<String> models;
  try {
    models = await api.models(s.kind, provider: s.provider);
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  // 2、选择
  final actions = [
    for (final m in models) SheetAction(m, icon: m == s.model ? LucideIcons.check300 : null),
    if (s.model.isNotEmpty) const SheetAction('恢复默认模型', icon: LucideIcons.rotateCcw300),
    const SheetAction('手动填写…', icon: LucideIcons.pencil300),
  ];
  final i = await actionSheet(context, actions, title: '切换模型');
  if (i == null || !context.mounted) return;
  String model;
  if (i < models.length) {
    model = models[i];
  } else if (s.model.isNotEmpty && i == models.length) {
    model = '';
  } else {
    final t = await inputDialog(context, title: '填写模型名称', initial: s.model, hint: '例如 sonnet 或 gpt-5');
    if (t == null || t.trim().isEmpty || !context.mounted) return;
    model = t.trim();
  }
  final n = await _patch(context, (api) => api.patchSession(s.id, model: model));
  if (n != null && context.mounted) toast(context, model.isEmpty ? '已恢复默认模型' : '已切换到 $model');
}

/**
 * switchProvider：切换模型供应商（只对这个会话生效）
 */
Future<void> switchProvider(BuildContext context, SessionInfo s) async {
  final api = context.read<AppState>().scope?.conn.api;
  if (api == null) return;
  if (!supportsProvider(s)) {
    toast(context, '只有 Claude Code 与 Codex 可以切换供应商');
    return;
  }
  ({bool available, List<ProviderInfo> list}) r;
  try {
    r = await api.providers(s.kind);
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (!r.available) {
    toast(context, '电脑上没有找到 CC Switch');
    return;
  }
  final cur = r.list.where((p) => p.current).firstOrNull;
  final i = await actionSheet(context, [
    SheetAction('跟随电脑当前设置', icon: s.provider.isEmpty ? LucideIcons.check300 : LucideIcons.monitor300, subtitle: cur == null ? '' : '当前：${cur.name}'),
    for (final p in r.list) SheetAction(p.name, icon: p.id == s.provider ? LucideIcons.check300 : LucideIcons.server300, subtitle: [p.host, if (p.current) '电脑当前'].where((x) => x.isNotEmpty).join(' · ')),
  ], title: '模型供应商（只对这个会话生效）');
  if (i == null || !context.mounted) return;
  final id = i == 0 ? '' : r.list[i - 1].id;
  if (id == s.provider) return;
  final n = await _patch(context, (api) => api.patchSession(s.id, provider: id));
  if (n != null && context.mounted) toast(context, i == 0 ? '已改为跟随电脑当前设置' : '已切换到 ${r.list[i - 1].name}');
}

/** providerName：会话所选供应商的名称，查不到时返回空 */
Future<String> providerName(PdApi api, SessionInfo s) async {
  if (s.provider.isEmpty || !supportsProvider(s)) return '';
  try {
    return (await api.providers(s.kind)).list.where((p) => p.id == s.provider).firstOrNull?.name ?? '';
  } on ApiException {
    return '';
  }
}
