/**
 * 斜杠指令与 @ 委托：输入「/」时弹出的指令列表，以及把一条消息交给其他 Agent 的前缀解析。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agents.dart';
import '../tokens.dart';

/** SlashCommand：一条指令 */
class SlashCommand {
  const SlashCommand(this.name, this.desc, this.icon);

  final String name;
  final String desc;
  final IconData icon;
}

/** 全部指令 */
const slashCommands = [
  SlashCommand('/new', '在同一 Agent 和目录下开新会话', LucideIcons.messageSquarePlus300),
  SlashCommand('/stop', '打断当前执行', LucideIcons.circleStop300),
  SlashCommand('/model', '切换模型', LucideIcons.cpu300),
  SlashCommand('/cd', '切换工作目录', LucideIcons.folderInput300),
  SlashCommand('/diff', '查看本会话累计改动', LucideIcons.gitCompare300),
  SlashCommand('/compact', '压缩上下文', LucideIcons.minimize2300),
  SlashCommand('/resume', '接着电脑上已有的会话聊', LucideIcons.history300),
];

/** matchCommands：按输入过滤指令（输入以 / 开头且还没有空格时） */
List<SlashCommand> matchCommands(String text) {
  if (!text.startsWith('/') || text.contains(' ') || text.contains('\n')) return const [];
  return slashCommands.where((c) => c.name.startsWith(text.toLowerCase())).toList();
}

/** parseDelegate：解析「@codex 内容」，返回委托的 Agent 与剩余文字 */
({String delegate, String text}) parseDelegate(String input) {
  final m = RegExp(r'^@(claude|codex|pi|dsh)(?:\s+|$)', caseSensitive: false).firstMatch(input);
  if (m == null) return (delegate: '', text: input);
  return (delegate: m.group(1)!.toLowerCase(), text: input.substring(m.end).trim());
}

/**
 * CommandPopup：指令候选列表（显示在输入栏上方）
 */
class CommandPopup extends StatelessWidget {
  const CommandPopup({super.key, required this.items, required this.onPick});

  final List<SlashCommand> items;
  final void Function(SlashCommand c) onPick;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(PdSize.smallRadius),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 12, offset: const Offset(0, -2))],
      ),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => Container(height: PdSize.divider, color: c.divider),
        itemBuilder: (_, i) => InkWell(
          onTap: () => onPick(items[i]),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Icon(items[i].icon, size: 18, color: c.text2),
              const SizedBox(width: 10),
              Text(items[i].name, style: TextStyle(fontSize: PdFont.item, color: c.text, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback)),
              const SizedBox(width: 10),
              Expanded(child: Text(items[i].desc, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.text3))),
            ]),
          ),
        ),
      ),
    );
  }
}

/** QuickChip：输入栏上方的快捷指令 */
class QuickChip extends StatelessWidget {
  const QuickChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: context.pd.card, borderRadius: BorderRadius.circular(14)),
          child: Text(label, style: TextStyle(fontSize: PdFont.time, color: context.pd.text2)),
        ),
      );
}

/** delegateLabel：@ 委托的显示文字 */
String delegateLabel(String kind) => '@$kind 交给 ${agentFor(kind).label}';
