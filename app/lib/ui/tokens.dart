/**
 * 视觉常量：颜色、字号、尺寸统一在此定义，浅色与深色两套色值，页面只读取这里的常量。
 */
library;

import 'package:flutter/material.dart';

/** PdColors：一套主题色值，通过 ThemeExtension 挂在主题上 */
@immutable
class PdColors extends ThemeExtension<PdColors> {
  const PdColors({
    required this.accent,
    required this.page,
    required this.bar,
    required this.card,
    required this.input,
    required this.bubbleMine,
    required this.bubbleMineText,
    required this.bubbleAgent,
    required this.divider,
    required this.text,
    required this.text2,
    required this.text3,
    required this.text4,
    required this.danger,
    required this.warnBg,
    required this.warnBorder,
    required this.warnText,
    required this.tool,
    required this.chip,
    required this.pressed,
    required this.accentSoft,
    required this.termBg,
    required this.termBar,
    required this.termKey,
    required this.termText,
  });

  final Color accent;
  final Color page;
  final Color bar;
  final Color card;
  final Color input;
  final Color bubbleMine;
  final Color bubbleMineText;
  final Color bubbleAgent;
  final Color divider;
  final Color text;
  final Color text2;
  final Color text3;
  final Color text4;
  final Color danger;
  final Color warnBg;
  final Color warnBorder;
  final Color warnText;
  final Color tool;
  final Color chip;
  final Color pressed;
  final Color accentSoft;
  final Color termBg;
  final Color termBar;
  final Color termKey;
  final Color termText;

  /** 浅色：页面 #EDEDED、卡片 #FFFFFF、我方气泡 #95EC69 */
  static const light = PdColors(
    accent: Color(0xFF07C160),
    page: Color(0xFFEDEDED),
    bar: Color(0xFFF7F7F7),
    card: Color(0xFFFFFFFF),
    input: Color(0xFFDEDEDE),
    bubbleMine: Color(0xFF95EC69),
    bubbleMineText: Color(0xFF000000),
    bubbleAgent: Color(0xFFFFFFFF),
    divider: Color(0xFFE5E5E5),
    text: Color(0xFF000000),
    text2: Color(0xFF5C5C5C),
    text3: Color(0xFF888888),
    text4: Color(0xFFB2B2B2),
    danger: Color(0xFFFA5151),
    warnBg: Color(0xFFFFF7E6),
    warnBorder: Color(0xFFF5C15D),
    warnText: Color(0xFFB4690E),
    tool: Color(0xFFF5F5F5),
    chip: Color(0xFFF0F0F0),
    pressed: Color(0xFFD9D9D9),
    accentSoft: Color(0xFFE8F7EF),
    termBg: Color(0xFF1E1E1E),
    termBar: Color(0xFF262626),
    termKey: Color(0xFF3A3A3A),
    termText: Color(0xFFD8D8D8),
  );

  /** 深色：页面 #111111、卡片 #191919、我方气泡 #3EB575 */
  static const dark = PdColors(
    accent: Color(0xFF07C160),
    page: Color(0xFF111111),
    bar: Color(0xFF191919),
    card: Color(0xFF191919),
    input: Color(0xFF2C2C2C),
    bubbleMine: Color(0xFF3EB575),
    bubbleMineText: Color(0xFF000000),
    bubbleAgent: Color(0xFF2C2C2C),
    divider: Color(0xFF2A2A2A),
    text: Color(0xFFD5D5D5),
    text2: Color(0xFFA8A8A8),
    text3: Color(0xFF7F7F7F),
    text4: Color(0xFF5E5E5E),
    danger: Color(0xFFFA5151),
    warnBg: Color(0xFF2E2410),
    warnBorder: Color(0xFF6E5520),
    warnText: Color(0xFFE8C27A),
    tool: Color(0xFF232323),
    chip: Color(0xFF2A2A2A),
    pressed: Color(0xFF262626),
    accentSoft: Color(0xFF10321F),
    termBg: Color(0xFF1E1E1E),
    termBar: Color(0xFF262626),
    termKey: Color(0xFF3A3A3A),
    termText: Color(0xFFD8D8D8),
  );

  @override
  PdColors copyWith() => this;

  @override
  PdColors lerp(ThemeExtension<PdColors>? other, double t) {
    if (other is! PdColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return PdColors(
      accent: l(accent, other.accent),
      page: l(page, other.page),
      bar: l(bar, other.bar),
      card: l(card, other.card),
      input: l(input, other.input),
      bubbleMine: l(bubbleMine, other.bubbleMine),
      bubbleMineText: l(bubbleMineText, other.bubbleMineText),
      bubbleAgent: l(bubbleAgent, other.bubbleAgent),
      divider: l(divider, other.divider),
      text: l(text, other.text),
      text2: l(text2, other.text2),
      text3: l(text3, other.text3),
      text4: l(text4, other.text4),
      danger: l(danger, other.danger),
      warnBg: l(warnBg, other.warnBg),
      warnBorder: l(warnBorder, other.warnBorder),
      warnText: l(warnText, other.warnText),
      tool: l(tool, other.tool),
      chip: l(chip, other.chip),
      pressed: l(pressed, other.pressed),
      accentSoft: l(accentSoft, other.accentSoft),
      termBg: l(termBg, other.termBg),
      termBar: l(termBar, other.termBar),
      termKey: l(termKey, other.termKey),
      termText: l(termText, other.termText),
    );
  }
}

/** PdSize：尺寸常量（逻辑像素） */
abstract final class PdSize {
  static const double topBar = 44;
  static const double chatBar = 52;
  static const double tabBar = 50;
  static const double listItem = 72;
  static const double fileItem = 60;
  static const double settingItem = 52;
  static const double avatar = 48;
  static const double chatAvatar = 36;
  static const double avatarRadius = 6;
  static const double bubbleRadius = 4;
  static const double bubbleMaxFactor = 0.7;
  static const double cardRadius = 12;
  static const double smallRadius = 8;
  static const double divider = 0.5;
  static const double gutter = 16;
  static const double touch = 44;
}

/** PdFont：字号常量 */
abstract final class PdFont {
  static const double body = 17;
  static const double title = 17;
  static const double listTitle = 16;
  static const double item = 15;
  static const double summary = 13;
  static const double time = 12;
  static const double tiny = 11;
  static const double tab = 11;
  static const String mono = 'monospace';
  static const List<String> monoFallback = ['SF Mono', 'Menlo', 'Consolas', 'Roboto Mono', 'monospace'];
}

/** PdAgent：Agent 头像与标识 */
class PdAgent {
  const PdAgent(this.label, this.short, this.color, {this.icon});

  final String label;
  final String short;
  final Color color;
  final IconData? icon;
}

/** PdMotion：动效时长与曲线（临界阻尼，无回弹） */
abstract final class PdMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 220);
  static const Curve curve = Curves.easeOutCubic;
}

/** 取当前主题色值的便捷扩展 */
extension PdTheme on BuildContext {
  PdColors get pd => Theme.of(this).extension<PdColors>() ?? PdColors.light;
}
