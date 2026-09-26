/**
 * 会话操作：新建 Agent 会话或终端（选择工作区）、打开会话（Agent 与终端需身份验证）。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../agents.dart';
import '../widgets.dart';
import 'chat_page.dart';
import 'terminal_page.dart';

/**
 * pickWorkspace：选择工作区（只有一个时直接返回）
 */
Future<Workspace?> pickWorkspace(BuildContext context, {String title = '选择工作区'}) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return null;
  final List<Workspace> list;
  try {
    list = await scope.conn.api.workspaces();
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  }
  if (!context.mounted) return null;
  if (list.isEmpty) {
    toast(context, '电脑上还没有添加工作区');
    return null;
  }
  if (list.length == 1) return list.first;
  final i = await actionSheet(context, [for (final w in list) SheetAction(w.name, icon: LucideIcons.folder300, subtitle: w.readOnly ? '只读' : '')], title: title);
  return i == null ? null : list[i];
}

/**
 * newAgentSession：新建 Agent 会话并进入
 */
Future<void> newAgentSession(BuildContext context, String kind) async {
  final app = context.read<AppState>();
  final scope = app.scope;
  if (scope == null) return;
  if (!await context.read<AuthGate>().ensure('验证身份以新建会话') || !context.mounted) return;
  final ws = await pickWorkspace(context, title: '在哪个工作区新建 ${agentFor(kind).label} 会话');
  if (ws == null || !context.mounted) return;
  try {
    final s = await scope.conn.api.createSession(kind, ws.id, '.');
    scope.sessions.upsert(s);
    if (context.mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: s.id)));
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
  }
}

/**
 * newTerminal：新建终端会话并进入（可指定快捷启动命令）
 */
Future<void> newTerminal(BuildContext context, {String command = ''}) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return;
  if (scope.conn.status?.features.terminal == false) {
    toast(context, '终端功能未开启，请在电脑端设置中开启');
    return;
  }
  if (!await context.read<AuthGate>().ensure('验证身份以打开终端') || !context.mounted) return;
  final ws = await pickWorkspace(context, title: '在哪个工作区打开终端');
  if (ws == null || !context.mounted) return;
  try {
    final s = await scope.conn.api.createSession('terminal', ws.id, '.', cols: 80, rows: 24, command: command);
    scope.sessions.upsert(s);
    if (context.mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TerminalPage(sessionId: s.id)));
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
  }
}

/**
 * openSession：打开会话，Agent 会话与终端需要身份验证
 */
Future<void> openSession(BuildContext context, SessionInfo s) async {
  if (s.isAgent || s.isTerminal) {
    final ok = await context.read<AuthGate>().ensure(s.isTerminal ? '验证身份以进入终端' : '验证身份以进入会话');
    if (!ok || !context.mounted) return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => s.isTerminal ? TerminalPage(sessionId: s.id) : ChatPage(sessionId: s.id)));
}

/** sessionTitle：列表与顶栏显示的会话名 */
String sessionTitle(SessionInfo s) {
  if (s.isAssistant) return '文件传输助手';
  final label = agentFor(s.kind).label;
  final t = s.title.trim();
  return t.isEmpty ? (s.isTerminal ? '终端' : '$label · 新会话') : '$label · $t';
}
