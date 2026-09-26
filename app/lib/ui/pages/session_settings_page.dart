/**
 * 会话设置：改名、置顶、模型、工作目录、用量与费用、查看改动、删除手机上的记录。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../agents.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'diff_page.dart';
import 'dir_picker.dart';
import 'session_actions.dart';

/**
 * SessionSettingsPage：会话设置
 */
class SessionSettingsPage extends StatelessWidget {
  const SessionSettingsPage({super.key, required this.sessionId, this.ws});

  final String sessionId;
  final Workspace? ws;

  /** _patch：修改会话并提示错误 */
  Future<void> _patch(BuildContext context, Future<SessionInfo> Function(PdApi api) f) async {
    final scope = context.read<AppState>().scope!;
    try {
      scope.sessions.upsert(await f(scope.conn.api));
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.watch<AppState>().scope;
    if (scope == null) return const Scaffold(appBar: PdBar(title: '会话设置'));
    return ListenableBuilder(
      listenable: scope.sessions,
      builder: (context, _) {
        final s = scope.sessions.byId(sessionId);
        if (s == null) return const Scaffold(appBar: PdBar(title: '会话设置'));
        final log = scope.sessions.loadedLog(sessionId);
        final usage = log?.usage;
        final c = context.pd;
        return Scaffold(
          appBar: const PdBar(title: '会话设置'),
          body: ListView(padding: const EdgeInsets.only(top: 12), children: [
            Container(
              color: c.card,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(PdSize.gutter),
              child: Row(children: [
                AgentAvatar(s.kind),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(sessionTitle(s), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.listTitle, color: c.text)),
                    const SizedBox(height: 4),
                    Text(agentFor(s.kind).label, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  ]),
                ),
              ]),
            ),
            PdGroup(children: [
              if (!s.isAssistant)
                PdCell(
                  title: '会话名称',
                  value: s.title,
                  onTap: () async {
                    final t = await inputDialog(context, title: '修改会话名称', initial: s.title);
                    if (t != null && t.trim().isNotEmpty && context.mounted) await _patch(context, (api) => api.patchSession(sessionId, title: t.trim()));
                  },
                ),
              PdCell(
                title: '置顶聊天',
                trailing: Switch(value: s.pinned, onChanged: (v) => _patch(context, (api) => api.patchSession(sessionId, pinned: v))),
              ),
            ]),
            if (s.isAgent)
              PdGroup(children: [
                PdCell(
                  title: '模型',
                  value: s.model.isEmpty ? '默认' : s.model,
                  onTap: () async {
                    try {
                      final models = await scope.conn.api.models(s.kind);
                      if (!context.mounted) return;
                      if (models.isEmpty) {
                        toast(context, '电脑端没有配置可选模型');
                        return;
                      }
                      final i = await actionSheet(context, [for (final m in models) SheetAction(m, icon: m == s.model ? LucideIcons.check300 : null)], title: '切换模型');
                      if (i != null && context.mounted) await _patch(context, (api) => api.patchSession(sessionId, model: models[i]));
                    } on ApiException catch (e) {
                      if (context.mounted) toast(context, e.message);
                    }
                  },
                ),
                PdCell(
                  title: '工作目录',
                  value: [ws?.name ?? '', if (s.cwd != '.' && s.cwd.isNotEmpty) s.cwd].where((x) => x.isNotEmpty).join('/'),
                  onTap: ws == null
                      ? null
                      : () async {
                          final d = await pickDir(context, ws: ws!, start: s.cwd, title: '切换工作目录');
                          if (d != null && context.mounted) await _patch(context, (api) => api.patchSession(sessionId, cwd: d));
                        },
                ),
                PdCell(title: '查看本会话改动', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiffPage(sessionId: sessionId, ws: ws)))),
              ]),
            if (s.isAgent && usage != null)
              PdGroup(
                header: '用量（手机已加载的记录）',
                children: [
                  PdCell(title: '对话轮数', value: '${usage.turns}', arrow: false),
                  PdCell(title: '输入 / 输出 tokens', value: '${usage.inputTokens} / ${usage.outputTokens}', arrow: false),
                  if (usage.costUsd > 0) PdCell(title: '费用', value: '\$${usage.costUsd.toStringAsFixed(4)}', arrow: false),
                ],
              ),
            PdGroup(children: [
              PdCell(
                title: '删除聊天',
                danger: true,
                arrow: false,
                onTap: () async {
                  final ok = await confirm(context, title: '删除聊天', message: '只删除手机上的聊天记录，电脑上的会话保留。', ok: '删除', danger: true);
                  if (!ok || !context.mounted) return;
                  await scope.sessions.hide(sessionId);
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                },
              ),
            ]),
          ]),
        );
      },
    );
  }
}
