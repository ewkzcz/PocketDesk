/**
 * 外观：切换界面风格（微信、Codex、QQ、Claude、冰川玻璃、极光、新粗野、纸刊）与明暗，设置我和各个 AI 的头像与昵称。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../agents.dart';
import '../avatars.dart';
import '../backdrop.dart';
import '../styles.dart';
import '../tokens.dart';
import '../widgets.dart';

/**
 * AppearancePage：外观
 */
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  /** _nickname：修改昵称 */
  Future<void> _nickname(BuildContext context) async {
    final s = context.read<AppSettings>();
    final t = await inputDialog(context, title: '我的昵称', initial: s.nickname, hint: '显示在通讯录和聊天里');
    if (t != null) s.nickname = t.trim();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final s = context.watch<AppSettings>();
    final bright = Theme.of(context).brightness;
    return Scaffold(
      appBar: const PdBar(title: '外观'),
      body: ListView(padding: const EdgeInsets.only(top: 16, bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PdSize.gutter, 0, PdSize.gutter, 8),
          child: Text('界面风格', style: TextStyle(fontSize: PdFont.summary, color: c.text3, fontWeight: FontWeight.w500)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LayoutBuilder(
            builder: (context, box) {
              const gap = 10.0;
              final w = (box.maxWidth - gap) / 2;
              return Wrap(spacing: gap, runSpacing: gap, children: [
                for (final t in PdThemes.all) SizedBox(width: w, child: _ThemeCard(spec: t, brightness: bright, selected: s.styleId == t.id, onTap: () => s.styleId = t.id)),
              ]);
            },
          ),
        ),
        const SizedBox(height: 20),
        PdGroup(header: '明暗', children: [
          for (final (i, label) in [(ThemeMode.system, '跟随系统'), (ThemeMode.light, '浅色'), (ThemeMode.dark, '深色')])
            PdCell(title: label, arrow: false, trailing: s.themeMode == i ? Icon(LucideIcons.check300, size: 20, color: c.accent) : null, onTap: () => s.themeMode = i),
        ]),
        PdGroup(header: '头像与昵称', footer: '每个 AI 都可以单独换头像；内置了几家 AI 的标志，也可以从相册选图片。', children: [
          AvatarCell(keyName: 'me', title: '我的头像', avatar: const MyAvatar(size: 36)),
          PdCell(title: '我的昵称', value: s.nickname.isEmpty ? '未设置' : s.nickname, onTap: () => _nickname(context)),
          for (final k in agentKinds) AvatarCell(keyName: k, title: '${agentFor(k).label} 的头像', avatar: AgentAvatar(k, size: 36)),
        ]),
      ]),
    );
  }
}

/** _ThemeCard：一套风格的预览卡片，用这套风格自己的配色与圆角画出迷你界面 */
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({required this.spec, required this.brightness, required this.selected, required this.onTap});

  final PdThemeSpec spec;
  final Brightness brightness;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final look = spec.look(brightness);
    final pc = look.colors;
    final st = look.style;
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        selected: selected,
        button: true,
        label: '${spec.name}风格',
        child: Container(
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? c.accent : c.divider, width: selected ? 2 : 1),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: SizedBox(height: 132, child: _Mini(colors: pc, style: st))),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: Text(spec.name, style: TextStyle(fontSize: PdFont.item, fontWeight: FontWeight.w600, color: c.text))),
              if (selected) Icon(LucideIcons.circleCheck300, size: 18, color: c.accent),
            ]),
            const SizedBox(height: 2),
            Text(spec.desc, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3, height: 1.4)),
          ]),
        ),
      ),
    );
  }
}

/** _Mini：迷你聊天界面（顶栏、两个气泡、底栏） */
class _Mini extends StatelessWidget {
  const _Mini({required this.colors, required this.style});

  final PdColors colors;
  final PdStyle style;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final st = style;
    final heavy = st.shadow == PdShadowKind.hard;
    BoxDecoration bubble(bool mine) {
      final flat = !mine && st.flatAgent;
      return BoxDecoration(
        color: flat ? null : (mine && st.mineGradient != null ? null : (mine ? c.bubbleMine : c.bubbleAgent)),
        gradient: mine && st.mineGradient != null ? LinearGradient(colors: st.mineGradient!) : null,
        borderRadius: BorderRadius.circular((st.bubbleRadius * 0.6).clamp(2.0, 12.0)),
        border: heavy ? Border.all(color: st.outlineColor ?? c.divider, width: 1.2) : null,
      );
    }

    final avatarR = st.isCircle ? 8.0 : (st.avatarRadius * 0.4).clamp(1.5, 5.0);
    Widget line(double w, Color col) => Container(width: w, height: 4, decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(2)));
    return PdBackdrop(
      style: st,
      colors: c,
      child: Container(
        color: st.backdrop == PdBackdropKind.none ? c.page : null,
        child: Column(children: [
          Container(height: 22, color: c.topBar.withValues(alpha: st.backdrop == PdBackdropKind.none || st.backdrop == PdBackdropKind.dots ? 1 : 0.6), alignment: st.titleLeft ? Alignment.centerLeft : Alignment.center, padding: const EdgeInsets.symmetric(horizontal: 8), child: line(26, c.onBar.withValues(alpha: 0.7))),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(width: 14, height: 14, decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(avatarR))),
                  const SizedBox(width: 5),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5), decoration: bubble(false), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [line(44, c.text2.withValues(alpha: 0.7)), const SizedBox(height: 3), line(30, c.text3.withValues(alpha: 0.7))])),
                ]),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerRight,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5), decoration: bubble(true), child: line(36, c.bubbleMineText.withValues(alpha: 0.8))),
                    const SizedBox(width: 5),
                    Container(width: 14, height: 14, decoration: BoxDecoration(color: c.text3, borderRadius: BorderRadius.circular(avatarR))),
                  ]),
                ),
                const Spacer(),
                Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: st.tabPill ? st.cardColor(c) : c.bar,
                    borderRadius: BorderRadius.circular(st.tabPill ? 9 : 2),
                    border: heavy ? Border.all(color: st.outlineColor ?? c.divider, width: 1.2) : (st.tabPill ? st.border(c) : null),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                    for (var i = 0; i < 4; i++) Container(width: 8, height: 8, decoration: BoxDecoration(color: i == 0 ? c.accent : c.text4, shape: BoxShape.circle)),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
