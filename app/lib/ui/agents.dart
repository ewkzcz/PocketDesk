/**
 * Agent 标识：各类会话的名称、头像文字或图标、底色。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../core/settings.dart';
import 'avatars.dart';
import 'styles.dart';
import 'tokens.dart';

/** 可新建的 Agent 类型（顺序即菜单顺序） */
const agentKinds = ['claude', 'codex', 'pi', 'dsh'];

/** agentFor：按会话类型取标识 */
PdAgent agentFor(String kind) => switch (kind) {
      'claude' => const PdAgent('Claude Code', 'CC', PdAgentColors.claude),
      'codex' => const PdAgent('Codex', 'CX', PdAgentColors.codex),
      'pi' => const PdAgent('Pi', 'Pi', PdAgentColors.pi),
      'dsh' => const PdAgent('DSH', 'DS', PdAgentColors.dsh),
      'terminal' => PdAgent('终端', '>_', PdAgentColors.terminal, icon: LucideIcons.terminal300),
      'assistant' => PdAgent('文件传输助手', '', PdAgentColors.assistant, icon: LucideIcons.send300),
      _ => PdAgent(kind, kind.isEmpty ? '?' : kind.substring(0, kind.length.clamp(1, 2)).toUpperCase(), PdAgentColors.other),
    };

/** AgentAvatar：会话头像，图片取自头像设置（没设置时用默认 AI 标志），形状跟随风格 */
class AgentAvatar extends StatelessWidget {
  const AgentAvatar(this.kind, {super.key, this.size = PdSize.avatar});

  final String kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = agentFor(kind);
    final custom = context.watch<AppSettings>().avatarSpec(kind);
    final spec = custom.isEmpty ? defaultAvatarSpec(kind) : custom;
    final tile = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: a.color, borderRadius: BorderRadius.circular(context.style.avatarRadiusFor(size))),
      child: a.icon != null
          ? Icon(a.icon, color: Colors.white, size: size * 0.46)
          : Text(a.short, style: TextStyle(color: Colors.white, fontSize: size * 0.32, fontWeight: FontWeight.w600, height: 1)),
    );
    if (spec.isEmpty) return tile;
    return PdAvatar(spec: spec, size: size, label: a.label, fallback: tile);
  }
}
