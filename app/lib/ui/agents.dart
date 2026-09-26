/**
 * Agent 标识：各类会话的名称、头像文字或图标、底色。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'tokens.dart';

/** 可新建的 Agent 类型（顺序即菜单顺序） */
const agentKinds = ['claude', 'codex', 'pi', 'dsh'];

/** agentFor：按会话类型取标识 */
PdAgent agentFor(String kind) => switch (kind) {
      'claude' => const PdAgent('Claude Code', 'CC', Color(0xFFD97757)),
      'codex' => const PdAgent('Codex', 'CX', Color(0xFF10A37F)),
      'pi' => const PdAgent('Pi', 'Pi', Color(0xFF6B5BFF)),
      'dsh' => const PdAgent('DSH', 'DS', Color(0xFF4D6BFE)),
      'terminal' => PdAgent('终端', '>_', const Color(0xFF333333), icon: LucideIcons.terminal300),
      'assistant' => PdAgent('文件传输助手', '', const Color(0xFF07C160), icon: LucideIcons.send300),
      _ => PdAgent(kind, kind.isEmpty ? '?' : kind.substring(0, kind.length.clamp(1, 2)).toUpperCase(), const Color(0xFF8C8C8C)),
    };

/** AgentAvatar：圆角方形头像 */
class AgentAvatar extends StatelessWidget {
  const AgentAvatar(this.kind, {super.key, this.size = PdSize.avatar});

  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = agentFor(kind);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: a.color, borderRadius: BorderRadius.circular(PdSize.avatarRadius)),
      child: a.icon != null
          ? Icon(a.icon, color: Colors.white, size: size * 0.46)
          : Text(a.short, style: TextStyle(color: Colors.white, fontSize: size * 0.32, fontWeight: FontWeight.w600, height: 1)),
    );
  }
}
