/**
 * 聊天项组件：我方与 Agent 气泡（带小三角）、思考过程、工具卡片、审批卡片、改动卡片、系统提示、文件消息。
 */
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/chat.dart';
import '../../data/models.dart';
import '../agents.dart';
import '../file_kinds.dart';
import '../format.dart';
import '../tokens.dart';
import 'markdown.dart';

/** bubbleMax：气泡最大宽度（屏幕宽度的 70%） */
double bubbleMax(BuildContext context) => MediaQuery.sizeOf(context).width * PdSize.bubbleMaxFactor;

/**
 * Bubble：带小三角的气泡
 */
class Bubble extends StatelessWidget {
  const Bubble({super.key, required this.mine, required this.child, this.color});

  final bool mine;
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final bg = color ?? (mine ? c.bubbleMine : c.bubbleAgent);
    const tail = 6.0;
    return CustomPaint(
      painter: _TailPainter(bg, mine),
      child: Container(
        margin: EdgeInsets.only(left: mine ? 0 : tail, right: mine ? tail : 0),
        constraints: BoxConstraints(maxWidth: bubbleMax(context)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(PdSize.bubbleRadius)),
        child: child,
      ),
    );
  }
}

/** _TailPainter：画出指向头像一侧的小三角 */
class _TailPainter extends CustomPainter {
  _TailPainter(this.color, this.mine);

  final Color color;
  final bool mine;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 13.0;
    const w = 6.0;
    const h = 6.0;
    final p = Path();
    if (mine) {
      p.moveTo(size.width - w, top - h);
      p.lineTo(size.width, top);
      p.lineTo(size.width - w, top + h);
    } else {
      p.moveTo(w, top - h);
      p.lineTo(0, top);
      p.lineTo(w, top + h);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_TailPainter old) => old.color != color || old.mine != mine;
}

/** TimeDivider：时间分隔 */
class TimeDivider extends StatelessWidget {
  const TimeDivider(this.ms, {super.key});

  final int ms;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(child: Text(formatChatTime(ms), style: TextStyle(fontSize: PdFont.tiny, color: context.pd.text4))),
      );
}

/**
 * UserBubble：我发出的消息
 */
class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.item});

  final UserItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final text = item.fileName.isNotEmpty && item.text.isEmpty ? '[文字] ${item.fileName}' : item.text;
    return Row(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (item.queued) Padding(padding: const EdgeInsets.only(right: 6, top: 10), child: Text('排队中', style: TextStyle(fontSize: PdFont.tiny, color: c.text3))),
      Bubble(
        mine: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (item.delegate.isNotEmpty) Text('@${agentFor(item.delegate).label}', style: TextStyle(fontSize: PdFont.summary, color: c.bubbleMineText.withValues(alpha: 0.6))),
          if (text.isNotEmpty) Text(text, style: TextStyle(fontSize: PdFont.item, height: 1.5, color: c.bubbleMineText)),
          for (final a in item.attachments)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.paperclip300, size: 14, color: c.bubbleMineText.withValues(alpha: 0.6)),
                const SizedBox(width: 4),
                Flexible(child: Text(a.split('/').last, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.bubbleMineText.withValues(alpha: 0.75)))),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

/** AgentRow：Agent 一侧的一行（头像 + 内容） */
class AgentRow extends StatelessWidget {
  const AgentRow({super.key, required this.kind, required this.child, this.showAvatar = true});

  final String kind;
  final Widget child;
  final bool showAvatar;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: PdSize.chatAvatar, child: showAvatar ? AgentAvatar(kind, size: PdSize.chatAvatar) : null),
        const SizedBox(width: 8),
        Flexible(child: Align(alignment: Alignment.centerLeft, child: child)),
      ]);
}

/**
 * AgentBubble：Agent 回复（Markdown），流式输出时末尾显示光标
 */
class AgentBubble extends StatelessWidget {
  const AgentBubble({super.key, required this.item});

  final AgentItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Bubble(
      mine: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (item.agent.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('来自 ${agentFor(item.agent).label}', style: TextStyle(fontSize: PdFont.time, color: c.text3))),
        if (item.text.isEmpty && item.streaming)
          SizedBox(width: 24, height: 20, child: Center(child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.text3))))
        else
          MdText(item.text + (item.streaming ? ' ▍' : '')),
      ]),
    );
  }
}

/**
 * ThinkingBlock：思考过程，默认折叠
 */
class ThinkingBlock extends StatefulWidget {
  const ThinkingBlock({super.key, required this.item});

  final ThinkingItem item;

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: bubbleMax(context) + 10),
      child: GestureDetector(
        onTap: () => setState(() => _open = !_open),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: c.tool, borderRadius: BorderRadius.circular(PdSize.smallRadius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(LucideIcons.brain300, size: 14, color: c.text3),
              const SizedBox(width: 6),
              Text(widget.item.done ? '思考过程' : '正在思考…', style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
              const SizedBox(width: 4),
              Icon(_open ? LucideIcons.chevronUp300 : LucideIcons.chevronDown300, size: 14, color: c.text3),
            ]),
            if (_open) Padding(padding: const EdgeInsets.only(top: 6), child: Text(widget.item.text, style: TextStyle(fontSize: PdFont.summary, height: 1.5, color: c.text3))),
          ]),
        ),
      ),
    );
  }
}

/** toolIcon：工具类型图标 */
IconData toolIcon(String kind) => switch (kind) {
      'exec' || 'bash' || 'shell' => LucideIcons.squareTerminal300,
      'read' => LucideIcons.fileText300,
      'write' || 'edit' => LucideIcons.filePen300,
      'search' || 'grep' || 'glob' => LucideIcons.search300,
      'web' || 'fetch' => LucideIcons.globe300,
      'task' || 'agent' => LucideIcons.bot300,
      'todo' => LucideIcons.listTodo300,
      _ => LucideIcons.wrench300,
    };

/** _prettyInput：工具参数的可读文本 */
String _prettyInput(Map<String, dynamic> input) {
  if (input.isEmpty) return '';
  final cmd = input['command'];
  if (cmd is String && input.length <= 2) return cmd;
  return const JsonEncoder.withIndent('  ').convert(input);
}

/**
 * ToolCard：工具调用卡片，默认折叠，展开看参数与输出
 */
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.item});

  final ToolItem item;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;
  bool _full = false;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final t = widget.item;
    final mono = TextStyle(fontSize: 12, height: 1.45, color: c.text2, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback);
    final input = _prettyInput(t.input);
    // 输出较长时先显示前 20 行（最多 2000 字）
    var output = t.output;
    final head = output.split('\n').take(20).join('\n');
    final short = head.length > 2000 ? head.substring(0, 2000) : head;
    final long = short.length < output.length;
    if (long && !_full) output = '$short\n…';
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: bubbleMax(context) + 10),
      child: Material(
        color: c.tool,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Icon(toolIcon(t.kind), size: 16, color: t.isError ? c.danger : c.text2),
                const SizedBox(width: 8),
                Expanded(child: Text(t.summary, maxLines: _open ? 4 : 1, overflow: TextOverflow.ellipsis, style: mono.copyWith(color: t.isError ? c.danger : c.text2))),
                const SizedBox(width: 6),
                if (!t.done)
                  SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: c.text3))
                else
                  Icon(t.isError ? LucideIcons.circleX300 : LucideIcons.chevronRight300, size: 16, color: t.isError ? c.danger : c.text4),
              ]),
              if (_open) ...[
                if (input.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('参数', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  const SizedBox(height: 2),
                  SelectableText(input, style: mono),
                ],
                if (t.output.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('输出', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  const SizedBox(height: 2),
                  SelectableText(output, style: mono),
                  if (long) GestureDetector(onTap: () => setState(() => _full = !_full), child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(_full ? '收起' : '展开全部', style: TextStyle(fontSize: PdFont.time, color: c.info)))),
                ],
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/** approvalTitle：审批标题 */
String approvalTitle(String kind) => switch (kind) {
      'exec' || 'bash' || 'shell' => '需要执行命令',
      'write' || 'edit' => '需要修改文件',
      'read' => '需要读取文件',
      'web' || 'fetch' => '需要访问网络',
      _ => '需要你的确认',
    };

/**
 * ApprovalCard：审批卡片（允许、拒绝、本会话总是允许此类操作）
 */
class ApprovalCard extends StatelessWidget {
  const ApprovalCard({super.key, required this.item, required this.onDecide});

  final ApprovalItem item;
  final void Function(String action) onDecide;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final pending = item.status == ApprovalStatus.pending;
    final detail = _prettyInput(item.input).isNotEmpty ? _prettyInput(item.input) : item.summary;
    final result = switch (item.status) {
      ApprovalStatus.allowed => item.always ? '已允许（本会话总是允许此类操作）' : '已允许',
      ApprovalStatus.denied => '已拒绝',
      ApprovalStatus.expired => '超过 10 分钟未处理，已按拒绝处理',
      _ => '',
    };
    return Container(
      width: math.min(bubbleMax(context) + 10, 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: c.warnBg, border: Border.all(color: c.warnBorder), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(LucideIcons.shieldAlert300, size: 16, color: c.warnText),
          const SizedBox(width: 6),
          Expanded(child: Text(approvalTitle(item.kind), style: TextStyle(fontSize: PdFont.summary, fontWeight: FontWeight.w600, color: c.warnText))),
          Text(item.tool, style: TextStyle(fontSize: PdFont.tiny, color: c.warnText)),
        ]),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          constraints: const BoxConstraints(maxHeight: 180),
          decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(6)),
          child: SingleChildScrollView(
            child: SelectableText(detail, style: TextStyle(fontSize: 12, height: 1.45, color: c.text, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback)),
          ),
        ),
        const SizedBox(height: 8),
        if (pending) ...[
          Row(children: [
            Expanded(child: FilledButton(onPressed: () => onDecide('allow'), style: FilledButton.styleFrom(minimumSize: const Size(0, 36)), child: const Text('允许'))),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => onDecide('deny'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  foregroundColor: c.text2,
                  backgroundColor: c.card,
                  side: BorderSide(color: c.divider),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PdSize.smallRadius)),
                ),
                child: const Text('拒绝'),
              ),
            ),
          ]),
          TextButton(
            onPressed: () => onDecide('always'),
            style: TextButton.styleFrom(foregroundColor: c.text3, minimumSize: const Size(0, 32)),
            child: const Text('本会话总是允许此类操作', style: TextStyle(fontSize: PdFont.time)),
          ),
        ] else
          Text(result, textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.time, color: item.status == ApprovalStatus.allowed ? c.accent : c.text3)),
      ]),
    );
  }
}

/**
 * DiffCard：本轮改动卡片
 */
class DiffCard extends StatelessWidget {
  const DiffCard({super.key, required this.item, required this.onOpen});

  final DiffItem item;
  final void Function(FileChange? file) onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final mono = TextStyle(fontSize: 12, color: c.text, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback);
    final shown = item.files.take(8).toList();
    return Container(
      width: math.min(bubbleMax(context) + 10, 300),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Text('本轮改动 · ${item.files.length} 个文件', style: TextStyle(fontSize: PdFont.summary, fontWeight: FontWeight.w600, color: c.text)),
        ),
        for (final f in shown)
          InkWell(
            onTap: () => onOpen(f),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(children: [
                Expanded(child: Text(f.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono)),
                const SizedBox(width: 8),
                ..._stat(c, f),
              ]),
            ),
          ),
        if (item.files.length > shown.length)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2), child: Text('还有 ${item.files.length - shown.length} 个文件', style: TextStyle(fontSize: PdFont.time, color: c.text3))),
        InkWell(
          onTap: () => onOpen(null),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(children: [
              Text('查看差异', style: TextStyle(fontSize: PdFont.summary, color: c.accent)),
              Icon(LucideIcons.chevronRight300, size: 14, color: c.accent),
            ]),
          ),
        ),
      ]),
    );
  }

  /** _stat：增删行数或状态 */
  static List<Widget> _stat(PdColors c, FileChange f) {
    const s = TextStyle(fontSize: 12);
    if (f.binary) return [Text('二进制', style: s.copyWith(color: c.text3))];
    if (f.status == 'A' || f.status == 'added') return [Text('+${f.added} 新建', style: s.copyWith(color: c.accent))];
    if (f.status == 'D' || f.status == 'deleted') return [Text('删除', style: s.copyWith(color: c.danger))];
    return [
      Text('+${f.added}', style: s.copyWith(color: c.accent)),
      const SizedBox(width: 4),
      Text('-${f.removed}', style: s.copyWith(color: c.danger)),
    ];
  }
}

/**
 * SystemNote：系统提示（灰色居中），出错时红色并可重试
 */
class SystemNote extends StatelessWidget {
  const SystemNote({super.key, required this.item, this.onRetry});

  final SystemItem item;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: item.error ? c.danger.withValues(alpha: 0.1) : c.pressed.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(4)),
        child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.center, children: [
          if (item.error) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(LucideIcons.circleAlert300, size: 13, color: c.danger)),
          Text(item.text, textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.time, color: item.error ? c.danger : c.text3)),
          if (item.error && item.retryable && onRetry != null)
            GestureDetector(onTap: onRetry, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text('重试', style: TextStyle(fontSize: PdFont.time, color: c.info)))),
        ]),
      ),
    );
  }
}

/**
 * FileBubble：文件消息
 */
class FileBubble extends StatelessWidget {
  const FileBubble({super.key, required this.item, required this.status, this.onTap});

  final FileItem item;
  final String status;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final card = Material(
      color: c.card,
      borderRadius: BorderRadius.circular(PdSize.bubbleRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: math.min(bubbleMax(context), 240),
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text)),
                const SizedBox(height: 4),
                Text([formatSize(item.size), status].where((s) => s.isNotEmpty).join(' · '), style: TextStyle(fontSize: PdFont.time, color: c.text3)),
              ]),
            ),
            const SizedBox(width: 10),
            FileIcon(name: item.name, isDir: false, size: 40),
          ]),
        ),
      ),
    );
    return item.up ? Row(mainAxisAlignment: MainAxisAlignment.end, children: [card]) : card;
  }
}
