/**
 * 提醒与直达：App 在前台时顶部弹出提醒（待审批、任务完成），点提醒或系统通知直接进入对应会话，有待审批时弹出审批。
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/auth_gate.dart';
import 'agents.dart';
import 'pages/chat_page.dart';
import 'tokens.dart';

/** pdNavigator：根导航，从通知进入会话时使用 */
final pdNavigator = GlobalKey<NavigatorState>();

OverlayEntry? _banner;
Timer? _bannerTimer;

/**
 * showBanner：顶部弹出提醒，5 秒后自动收起，点击进入会话，上滑关闭
 */
void showBanner({required String kind, required String title, required String body, required String session, String approval = ''}) {
  final overlay = pdNavigator.currentState?.overlay;
  if (overlay == null) return;
  _hideBanner();
  _banner = OverlayEntry(
    builder: (context) => _Banner(
      kind: kind,
      title: title,
      body: body,
      urgent: approval.isNotEmpty,
      onTap: () {
        _hideBanner();
        unawaited(openChat(session, approval: approval));
      },
      onClose: _hideBanner,
    ),
  );
  overlay.insert(_banner!);
  _bannerTimer = Timer(Duration(seconds: approval.isNotEmpty ? 8 : 5), _hideBanner);
}

/** _hideBanner：收起提醒 */
void _hideBanner() {
  _bannerTimer?.cancel();
  _bannerTimer = null;
  _banner?.remove();
  _banner = null;
}

/** openLink：处理 pocketdesk://open?session=…&approval=… 链接 */
Future<void> openLink(String link) async {
  final u = Uri.tryParse(link);
  if (u == null || u.scheme != 'pocketdesk') return;
  final session = u.queryParameters['session'] ?? '';
  if (session.isEmpty) return;
  await openChat(session, approval: u.queryParameters['approval'] ?? '');
}

/**
 * openChat：进入会话，有待审批时弹出审批
 *
 * 处理流程：
 * 1、等电脑连上并读到这个会话（从通知冷启动时需要一点时间）
 * 2、验证身份，回到首页后打开聊天
 */
Future<void> openChat(String session, {String approval = ''}) async {
  final nav = pdNavigator.currentState;
  if (nav == null) return;
  final app = nav.context.read<AppState>();
  // 1、等待会话
  for (var i = 0; i < 40; i++) {
    final scope = app.scope;
    if (scope != null && scope.sessions.byId(session) != null) break;
    if (scope != null && i % 8 == 4) unawaited(scope.sessions.refresh().catchError((Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final s = app.scope?.sessions.byId(session);
  if (s == null || !nav.mounted) return;
  // 2、打开
  if (!await nav.context.read<AuthGate>().ensure('验证身份以进入会话') || !nav.mounted) return;
  nav.popUntil((r) => r.isFirst);
  await nav.push(MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: session, focusApproval: approval)));
}

/** _Banner：顶部提醒卡片 */
class _Banner extends StatelessWidget {
  const _Banner({required this.kind, required this.title, required this.body, required this.urgent, required this.onTap, required this.onClose});

  final String kind;
  final String title;
  final String body;
  final bool urgent;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      left: 8,
      right: 8,
      top: top + 6,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: -1, end: 0),
        duration: PdMotion.normal,
        curve: PdMotion.curve,
        builder: (context, v, child) => FractionalTranslation(translation: Offset(0, v), child: child),
        child: GestureDetector(
          onTap: onTap,
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < 0) onClose();
          },
          child: Material(
            color: c.card,
            elevation: 6,
            shadowColor: PdDarkUi.shadow,
            borderRadius: BorderRadius.circular(PdSize.cardRadius),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                AgentAvatar(kind, size: 36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      if (urgent) ...[Icon(LucideIcons.shieldAlert300, size: 15, color: c.danger), const SizedBox(width: 4)],
                      Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: urgent ? c.danger : c.text, fontWeight: FontWeight.w600))),
                    ]),
                    if (body.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 2), child: Text(body, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.text2))),
                  ]),
                ),
                const SizedBox(width: 8),
                Text(urgent ? '去处理' : '查看', style: TextStyle(fontSize: PdFont.summary, color: c.accent)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
