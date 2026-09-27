/**
 * 会话操作：新建 Agent 会话或终端（选择工作目录，默认工作目录优先，也可选电脑上任意文件夹）、打开会话（Agent 与终端需身份验证）。
 */
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../agents.dart';
import '../widgets.dart';
import 'chat_page.dart';
import 'places.dart';
import 'terminal_page.dart';

/**
 * newAgentSession：新建 Agent 会话并进入
 */
Future<void> newAgentSession(BuildContext context, String kind, {bool autoApprove = false}) async {
  final app = context.read<AppState>();
  final scope = app.scope;
  if (scope == null) return;
  if (!await context.read<AuthGate>().ensure('验证身份以新建会话') || !context.mounted) return;
  final dir = await pickWorkDir(context, title: '在哪里新建 ${agentFor(kind).label}${autoApprove ? ' 免审批' : ''} 会话');
  if (dir == null || !context.mounted) return;
  try {
    final s = await scope.conn.api.createSession(kind, dir.ws.id, dir.cwd, autoApprove: autoApprove);
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
  final dir = await pickWorkDir(context, title: '在哪里打开终端');
  if (dir == null || !context.mounted) return;
  try {
    final s = await scope.conn.api.createSession('terminal', dir.ws.id, dir.cwd, cols: 80, rows: 24, command: command);
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
  if (t.isEmpty || t == label) return s.isTerminal ? '终端' : '$label · 新会话';
  // 电脑端生成的标题已带 Agent 名（如「Claude Code · 重构支付模块」），不再重复
  return t.startsWith('$label · ') ? t : '$label · $t';
}
