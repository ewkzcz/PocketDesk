/**
 * 通用组件：顶栏、设置行与分组、角标、提示、确认框、底部操作菜单、输入框、空状态。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'tokens.dart';

/**
 * PdBar：顶栏，标题下方可带一行小字
 */
class PdBar extends StatelessWidget implements PreferredSizeWidget {
  const PdBar({super.key, required this.title, this.subtitle = '', this.actions = const [], this.leading, this.dark = false, this.onTitleTap});

  final String title;
  final String subtitle;
  final List<Widget> actions;
  final Widget? leading;
  final bool dark;
  final VoidCallback? onTitleTap;

  @override
  Size get preferredSize => Size.fromHeight(subtitle.isEmpty ? PdSize.topBar : PdSize.chatBar);

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final fg = dark ? Colors.white : c.text;
    // 按本页是否可返回判断（页面关闭动画期间导航状态会短暂可返回，不能以此为准）
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    final side = actions.length > 1 ? 44.0 * actions.length + 4 : 56.0;
    final lead = leading ?? (canPop ? PdIconButton(icon: LucideIcons.chevronLeft300, color: fg, tooltip: '返回', onTap: () => Navigator.of(context).maybePop()) : null);
    return Material(
      color: dark ? c.termBar : c.bar,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: preferredSize.height,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: dark ? c.termKey : c.divider, width: PdSize.divider))),
          child: Row(children: [
            SizedBox(width: side, child: lead == null ? null : Align(alignment: Alignment.centerLeft, child: lead)),
            Expanded(
              child: GestureDetector(
                onTap: onTitleTap,
                behavior: HitTestBehavior.opaque,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: subtitle.isEmpty ? PdFont.title : PdFont.listTitle, fontWeight: FontWeight.w600, color: fg)),
                  if (subtitle.isNotEmpty)
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.tiny, color: dark ? PdDarkUi.subtle : c.text3)),
                ]),
              ),
            ),
            SizedBox(width: side, child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions)),
          ]),
        ),
      ),
    );
  }
}

/** PdIconButton：44×44 可点击图标 */
class PdIconButton extends StatelessWidget {
  const PdIconButton({super.key, required this.icon, required this.onTap, this.tooltip = '', this.color, this.size = 22});

  final IconData icon;
  final VoidCallback? onTap;
  final String tooltip;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final btn = InkResponse(
      onTap: onTap,
      radius: 22,
      child: SizedBox(width: PdSize.touch, height: PdSize.touch, child: Icon(icon, size: size, color: onTap == null ? context.pd.text4 : (color ?? context.pd.text))),
    );
    return tooltip.isEmpty ? btn : Semantics(label: tooltip, button: true, child: btn);
  }
}

/** InsetDivider：左侧缩进的分割线 */
class InsetDivider extends StatelessWidget {
  const InsetDivider({super.key, this.indent = PdSize.gutter, this.color});

  final double indent;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        color: color ?? context.pd.card,
        padding: EdgeInsets.only(left: indent),
        child: Container(height: PdSize.divider, color: context.pd.divider),
      );
}

/**
 * PdCell：设置行（图标、标题、右侧说明、箭头或开关）
 */
class PdCell extends StatelessWidget {
  const PdCell({super.key, required this.title, this.icon, this.value = '', this.onTap, this.trailing, this.danger = false, this.subtitle = '', this.arrow = true});

  final String title;
  final IconData? icon;
  final String value;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool danger;
  final bool arrow;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Material(
      color: c.card,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PdSize.settingItem),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 8),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 22, color: danger ? c.danger : c.text2), const SizedBox(width: 12)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(title, style: TextStyle(fontSize: PdFont.item, color: danger ? c.danger : c.text)),
                  if (subtitle.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle, style: TextStyle(fontSize: PdFont.time, color: c.text3))),
                ]),
              ),
              // 右侧说明靠右，最多占一半宽度，过长省略
              if (value.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.5),
                  child: Padding(padding: const EdgeInsets.only(left: 8), child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: TextStyle(fontSize: PdFont.summary, color: c.text3))),
                ),
              ?trailing,
              if (trailing == null && arrow && onTap != null) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(LucideIcons.chevronRight300, size: 18, color: c.text4)),
            ]),
          ),
        ),
      ),
    );
  }
}

/** PdGroup：一组设置行，组间留白，行间有分割线 */
class PdGroup extends StatelessWidget {
  const PdGroup({super.key, required this.children, this.header = '', this.footer = '', this.indent = PdSize.gutter});

  final List<Widget> children;
  final String header;
  final String footer;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(InsetDivider(indent: indent));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (header.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(PdSize.gutter, 0, PdSize.gutter, 6), child: Text(header, style: TextStyle(fontSize: PdFont.summary, color: c.text3))),
        ...rows,
        if (footer.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(PdSize.gutter, 6, PdSize.gutter, 0), child: Text(footer, style: TextStyle(fontSize: PdFont.time, color: c.text3, height: 1.5))),
      ]),
    );
  }
}

/** CountBadge：红色数字角标 */
class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: context.pd.danger, borderRadius: BorderRadius.circular(9)),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: PdFont.tiny, height: 1.1, fontWeight: FontWeight.w500)),
    );
  }
}

/** DotBadge：红点 */
class DotBadge extends StatelessWidget {
  const DotBadge({super.key});

  @override
  Widget build(BuildContext context) =>
      Container(width: 8, height: 8, decoration: BoxDecoration(color: context.pd.danger, shape: BoxShape.circle));
}

/** Tag：小标签（如「待确认」） */
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color, this.textColor = Colors.white});

  final String text;
  final Color? color;
  final Color textColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: color ?? context.pd.danger, borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(color: textColor, fontSize: PdFont.tiny, height: 1.2)),
      );
}

/** toast：底部轻提示 */
void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

/** confirm：确认对话框 */
Future<bool> confirm(BuildContext context, {required String title, String message = '', String ok = '确定', String cancel = '取消', bool danger = false}) async {
  final c = context.pd;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message.isEmpty ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), style: TextButton.styleFrom(foregroundColor: c.text2), child: Text(cancel)),
        TextButton(onPressed: () => Navigator.pop(ctx, true), style: TextButton.styleFrom(foregroundColor: danger ? c.danger : c.accent), child: Text(ok)),
      ],
    ),
  );
  return r ?? false;
}

/** confirmSend：发送文件前让用户确认，列出前几个文件名 */
Future<bool> confirmSend(BuildContext context, List<String> names, {String to = '电脑'}) {
  final shown = names.take(3).map((n) => n.isEmpty ? '照片' : n).join('\n');
  final more = names.length > 3 ? '\n等 ${names.length} 个文件' : '';
  return confirm(context, title: '发送到$to', message: '$shown$more', ok: '发送');
}

/** SheetAction：底部菜单的一项 */
class SheetAction {
  const SheetAction(this.label, {this.icon, this.danger = false, this.subtitle = ''});

  final String label;
  final IconData? icon;
  final bool danger;
  final String subtitle;
}

/**
 * actionSheet：底部操作菜单，返回选中项下标，取消返回 null
 */
Future<int?> actionSheet(BuildContext context, List<SheetAction> actions, {String title = ''}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final c = ctx.pd;
      Widget item(String label, VoidCallback onTap, {IconData? icon, bool danger = false, String subtitle = ''}) => InkWell(
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[Icon(icon, size: 20, color: danger ? c.danger : c.text2), const SizedBox(width: 8)],
                Flexible(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.body, color: danger ? c.danger : c.text)),
                    if (subtitle.isNotEmpty) Text(subtitle, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  ]),
                ),
              ]),
            ),
          );
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (title.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.divider, width: PdSize.divider))),
                child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
              ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: actions.length,
                separatorBuilder: (_, _) => Container(height: PdSize.divider, color: c.divider),
                itemBuilder: (_, i) => item(actions[i].label, () => Navigator.pop(ctx, i), icon: actions[i].icon, danger: actions[i].danger, subtitle: actions[i].subtitle),
              ),
            ),
            Container(height: 8, color: c.page),
            item('取消', () => Navigator.pop(ctx)),
          ]),
        ),
      );
    },
  );
}

/** inputDialog：输入对话框，确定返回输入内容，取消返回 null */
Future<String?> inputDialog(BuildContext context, {required String title, String initial = '', String hint = '', String ok = '确定', int maxLines = 1}) =>
    showDialog<String>(context: context, builder: (_) => _InputDialog(title: title, initial: initial, hint: hint, ok: ok, maxLines: maxLines));

/** _InputDialog：输入框由对话框自己持有，关闭动画结束、对话框移除后才释放 */
class _InputDialog extends StatefulWidget {
  const _InputDialog({required this.title, required this.initial, required this.hint, required this.ok, required this.maxLines});

  final String title;
  final String initial;
  final String hint;
  final String ok;
  final int maxLines;

  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // 选中文件名主体，方便直接改名
    final dot = widget.initial.lastIndexOf('.');
    _ctrl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : widget.initial.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLines: widget.maxLines,
        decoration: InputDecoration(hintText: widget.hint, fillColor: c.page),
        onSubmitted: widget.maxLines == 1 ? (v) => Navigator.pop(context, v) : null,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), style: TextButton.styleFrom(foregroundColor: c.text2), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(context, _ctrl.text), child: Text(widget.ok)),
      ],
    );
  }
}

/** EmptyHint：空状态 */
class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text, this.action = '', this.onAction});

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 48, color: c.text4),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: c.text3, height: 1.6)),
          if (action.isNotEmpty) ...[const SizedBox(height: 16), FilledButton(onPressed: onAction, child: Text(action))],
        ]),
      ),
    );
  }
}

/** SearchField：灰底圆角搜索框 */
class SearchField extends StatelessWidget {
  const SearchField({super.key, this.controller, this.hint = '搜索', this.onChanged, this.onSubmitted, this.onTap, this.onLongPress, this.readOnly = false, this.autofocus = false, this.focusNode});

  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool readOnly;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return GestureDetector(
      onLongPress: onLongPress,
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          readOnly: readOnly,
          autofocus: autofocus,
          onTap: onTap,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          // 撑满 36 高的灰底，文字垂直居中
          expands: true,
          maxLines: null,
          textAlignVertical: TextAlignVertical.center,
          textInputAction: TextInputAction.search,
          style: TextStyle(fontSize: 14, color: c.text),
          decoration: InputDecoration(
            hintText: hint,
            hintMaxLines: 1,
            hintStyle: TextStyle(fontSize: 14, color: c.text3, overflow: TextOverflow.ellipsis),
            fillColor: c.input,
            contentPadding: EdgeInsets.zero,
            prefixIcon: Icon(LucideIcons.search300, size: 16, color: c.text3),
            prefixIconConstraints: const BoxConstraints(minWidth: 34),
          ),
        ),
      ),
    );
  }
}
