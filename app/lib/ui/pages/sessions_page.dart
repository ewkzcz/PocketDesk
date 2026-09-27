/**
 * 消息页：会话列表（置顶、状态、未读、左滑操作），顶部搜索，右上角「+」新建会话或扫码配对。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/events.dart';
import '../agents.dart';
import '../format.dart';
import '../swipe_row.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'pair_page.dart';
import 'session_actions.dart';

/**
 * SessionsPage：会话列表
 */
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final _search = TextEditingController();
  final _plusKey = GlobalKey();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /**
   * _plusMenu：右上角菜单
   *
   * 处理流程：
   * 1、列出电脑上已安装的 Agent（离线时列出全部）
   * 2、终端开启时显示「新建终端」，最后是「扫一扫」
   */
  Future<void> _plusMenu() async {
    final scope = context.read<AppState>().scope;
    final box = _plusKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = box.localToGlobal(Offset(box.size.width, box.size.height));
    // 1、Agent
    final status = scope?.conn.status;
    final installed = status == null ? agentKinds : [for (final k in agentKinds) if (status.agents.any((a) => a.kind == k && a.installed)) k];
    final items = <(String, IconData, Future<void> Function())>[
      if (scope != null && (status?.features.agents ?? true))
        for (final k in installed) ('新建 ${agentFor(k).label} 会话', LucideIcons.messageSquarePlus300, () => newAgentSession(context, k)),
      // 免审批：Claude Code 跳过全部权限确认，Codex 不审批也不进沙箱
      if (scope != null && (status?.features.agents ?? true))
        for (final k in installed.where((k) => k == 'claude' || k == 'codex')) ('${agentFor(k).label} 免审批', LucideIcons.zap300, () => newAgentSession(context, k, autoApprove: true)),
      // 2、终端与扫码
      if (scope != null && (status?.features.terminal ?? false)) ('新建终端', LucideIcons.terminal300, () => newTerminal(context)),
      ('扫一扫', LucideIcons.scanLine300, () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage()))),
    ];
    final i = await showMenu<int>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx - 200, pos.dy, pos.dx - 8, 0),
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
      items: [
        for (var j = 0; j < items.length; j++)
          PopupMenuItem<int>(
            value: j,
            height: 48,
            child: Row(children: [
              Icon(items[j].$2, size: 20, color: Colors.white),
              const SizedBox(width: 12),
              Flexible(child: Text(items[j].$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: PdFont.item))),
            ]),
          ),
      ],
    );
    if (i != null && mounted) await items[i].$3();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final scope = app.scope;
    final plus = PdIconButton(key: _plusKey, icon: LucideIcons.circlePlus300, tooltip: '新建', onTap: _plusMenu);
    if (scope == null) {
      return Scaffold(
        appBar: PdBar(title: 'PocketDesk', actions: [plus]),
        body: !app.ready
            ? const SizedBox.shrink()
            : EmptyHint(
                icon: LucideIcons.monitorSmartphone300,
                text: app.hosts.isEmpty ? '还没有配对电脑\n在电脑上打开 PocketDesk，选择「配对新手机」' : '这台电脑需要重新配对',
                action: '扫码配对',
                onAction: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage())),
              ),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([scope.sessions, scope.conn]),
      builder: (context, _) {
        final store = scope.sessions;
        final conn = scope.conn;
        final title = conn.online ? 'PocketDesk' : (conn.link == LinkState.connecting || conn.probing ? '连接中…' : 'PocketDesk（未连接）');
        final list = store.sessions;
        return Scaffold(
          appBar: PdBar(title: title, actions: [plus]),
          body: RefreshIndicator(
            color: context.pd.accent,
            onRefresh: () async {
              if (!conn.online) await conn.connect();
              try {
                await store.refresh();
              } catch (_) {
                if (context.mounted) toast(context, '电脑不在线');
              }
            },
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: list.length + 2,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    child: SearchField(
                      controller: _search,
                      hint: '搜索会话、消息',
                      onChanged: (v) => setState(() => store.query = v),
                    ),
                  );
                }
                if (i == 1) return _Banner(scope: scope);
                final s = list[i - 2];
                return _SessionRow(key: ValueKey(s.id), s: s, unread: store.unread(s.id), last: i - 2 == list.length - 1);
              },
            ),
          ),
        );
      },
    );
  }
}

/** _Banner：离线提示条，点击重试 */
class _Banner extends StatelessWidget {
  const _Banner({required this.scope});

  final HostScope scope;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final conn = scope.conn;
    if (conn.online || conn.link == LinkState.connecting || conn.probing) return const SizedBox.shrink();
    final msg = conn.lastError.isNotEmpty ? conn.lastError : '电脑不在线，任务仍在电脑上继续';
    return Material(
      color: c.warnBg,
      child: InkWell(
        onTap: () => conn.connect(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 10),
          child: Row(children: [
            Icon(LucideIcons.wifiOff300, size: 18, color: c.warnText),
            const SizedBox(width: 8),
            Expanded(child: Text(msg, style: TextStyle(fontSize: PdFont.summary, color: c.warnText))),
            Text('重试', style: TextStyle(fontSize: PdFont.summary, color: c.accent)),
          ]),
        ),
      ),
    );
  }
}

/**
 * _SessionRow：一行会话
 */
class _SessionRow extends StatelessWidget {
  const _SessionRow({super.key, required this.s, required this.unread, required this.last});

  final SessionInfo s;
  final int unread;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = context.read<AppState>().scope!;
    final store = scope.sessions;
    // 摘要颜色与前缀跟随状态
    var preview = s.preview;
    var previewColor = c.text3;
    if (s.state == SessionState.running) {
      preview = preview.isEmpty ? '执行中…' : '执行中 · $preview';
      previewColor = c.accent;
    } else if (s.state == SessionState.awaiting) {
      previewColor = c.danger;
      if (!preview.startsWith('待确认')) preview = '待确认 · $preview';
    } else if (s.state == SessionState.error) {
      previewColor = c.danger;
    }
    Widget? status;
    if (s.state == SessionState.running) {
      status = SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6, color: c.accent));
    } else if (s.state == SessionState.awaiting) {
      status = const Tag('待确认');
    } else if (s.state == SessionState.error) {
      status = Icon(LucideIcons.circleAlert300, size: 16, color: c.danger);
    } else if (unread > 0) {
      status = CountBadge(unread);
    } else if (s.preview.startsWith('已完成')) {
      status = Icon(LucideIcons.check300, size: 16, color: c.accent);
    }
    return SwipeRow(
      onTap: () => openSession(context, s),
      actions: [
        SwipeAction(s.pinned ? '取消置顶' : '置顶', c.neutral, () async {
          try {
            await store.togglePin(s.id);
          } catch (_) {
            if (context.mounted) toast(context, '电脑不在线，稍后再试');
          }
        }, width: s.pinned ? 88 : 72),
        SwipeAction(unread > 0 ? '标为已读' : '标为未读', c.info, () => unread > 0 ? store.markRead(s.id) : store.markUnread(s.id), width: 88),
        SwipeAction('删除', c.danger, () async {
          final ok = await confirm(context,
              title: '删除该聊天',
              message: s.isTerminal ? '只删除手机上的记录，电脑上的终端继续运行。' : '只删除手机上的聊天记录，电脑上的会话保留。',
              ok: '删除',
              danger: true);
          if (ok) await store.hide(s.id);
        }),
      ],
      child: Container(
        color: s.pinned ? c.bar : c.card,
        child: Column(children: [
          SizedBox(
            height: PdSize.listItem,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter),
              child: Row(children: [
                AgentAvatar(s.kind),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Text(sessionTitle(s), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.listTitle, color: c.text, height: 1.3))),
                      if (s.autoApprove)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(color: c.warnBg, borderRadius: BorderRadius.circular(4)),
                          child: Text('免审批', style: TextStyle(fontSize: PdFont.tiny, color: c.warnText, height: 1.3)),
                        ),
                    ]),
                    const SizedBox(height: 4),
                    Text(preview.isEmpty ? ' ' : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: PdFont.summary, color: previewColor, height: 1.3, fontFamily: s.isTerminal ? PdFont.mono : null, fontFamilyFallback: s.isTerminal ? PdFont.monoFallback : null)),
                  ]),
                ),
                const SizedBox(width: 8),
                Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(formatListTime(s.updatedAt), style: TextStyle(fontSize: PdFont.time, color: c.text4)),
                  const SizedBox(height: 6),
                  SizedBox(height: 18, child: Center(child: status ?? const SizedBox.shrink())),
                ]),
              ]),
            ),
          ),
          if (!last) Padding(padding: const EdgeInsets.only(left: 76), child: Container(height: PdSize.divider, color: c.divider)),
        ]),
      ),
    );
  }
}
