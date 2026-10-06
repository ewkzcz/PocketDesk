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
    required this.info,
    required this.neutral,
    required this.field,
    required this.menu,
    required this.toast,
    required this.onBar,
    required this.topBar,
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

  /** 下载进度、次要操作按钮 */
  final Color info;

  /** 置顶等中性操作按钮 */
  final Color neutral;

  /** 输入栏中的输入框底色 */
  final Color field;

  /** 深色弹出菜单底色 */
  final Color menu;

  /** 轻提示底色 */
  final Color toast;

  /** 顶栏上的文字与图标颜色（顶栏用强调色底时为白色） */
  final Color onBar;

  /** 页面顶栏底色（底栏、输入栏等其他条形区域用 bar） */
  final Color topBar;

  /** 浅色：页面 #F2F2F7、卡片 #FFFFFF、我方气泡 #95EC69 */
  static const light = PdColors(
    accent: Color(0xFF07C160),
    page: Color(0xFFF2F2F7),
    bar: Color(0xFFF7F7FA),
    card: Color(0xFFFFFFFF),
    input: Color(0xFFE3E3E8),
    bubbleMine: Color(0xFF95EC69),
    bubbleMineText: Color(0xFF000000),
    bubbleAgent: Color(0xFFFFFFFF),
    divider: Color(0xFFE5E5EA),
    text: Color(0xFF000000),
    text2: Color(0xFF545458),
    text3: Color(0xFF8A8A8E),
    text4: Color(0xFFC4C4C7),
    danger: Color(0xFFFF3B30),
    warnBg: Color(0xFFFFF6E5),
    warnBorder: Color(0xFFFFCC66),
    warnText: Color(0xFFB25E00),
    tool: Color(0xFFF4F4F7),
    chip: Color(0xFFEFEFF4),
    pressed: Color(0xFFD1D1D6),
    accentSoft: Color(0xFFE2F8EB),
    termBg: Color(0xFF1E1E1E),
    termBar: Color(0xFF262626),
    termKey: Color(0xFF3A3A3A),
    termText: Color(0xFFD8D8D8),
    info: Color(0xFF0A84FF),
    neutral: Color(0xFF8E8E93),
    field: Color(0xFFFFFFFF),
    menu: Color(0xFF4C4C4C),
    toast: Color(0xE6333333),
    onBar: Color(0xFF000000),
    topBar: Color(0xFFF7F7FA),
  );

  /** 深色：页面 #0E0E10、卡片 #1C1C1E、我方气泡 #34C368 */
  static const dark = PdColors(
    accent: Color(0xFF07C160),
    page: Color(0xFF0E0E10),
    bar: Color(0xFF1C1C1E),
    card: Color(0xFF1C1C1E),
    input: Color(0xFF2C2C2E),
    bubbleMine: Color(0xFF34C368),
    bubbleMineText: Color(0xFF000000),
    bubbleAgent: Color(0xFF2C2C2E),
    divider: Color(0xFF2C2C2E),
    text: Color(0xFFEDEDF0),
    text2: Color(0xFFAEAEB2),
    text3: Color(0xFF8E8E93),
    text4: Color(0xFF5A5A5E),
    danger: Color(0xFFFF453A),
    warnBg: Color(0xFF2E2412),
    warnBorder: Color(0xFF7A5A1E),
    warnText: Color(0xFFFFB340),
    tool: Color(0xFF232325),
    chip: Color(0xFF2C2C2E),
    pressed: Color(0xFF2C2C2E),
    accentSoft: Color(0xFF0F3321),
    termBg: Color(0xFF1E1E1E),
    termBar: Color(0xFF262626),
    termKey: Color(0xFF3A3A3A),
    termText: Color(0xFFD8D8D8),
    info: Color(0xFF0A84FF),
    neutral: Color(0xFF636366),
    field: Color(0xFF2C2C2E),
    menu: Color(0xFF2C2C2E),
    toast: Color(0xFF2C2C2E),
    onBar: Color(0xFFEDEDF0),
    topBar: Color(0xFF1C1C1E),
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
      info: l(info, other.info),
      neutral: l(neutral, other.neutral),
      field: l(field, other.field),
      menu: l(menu, other.menu),
      toast: l(toast, other.toast),
      onBar: l(onBar, other.onBar),
      topBar: l(topBar, other.topBar),
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

/** PdFileColors：文件类型图标色（浅底由图标色 12% 透明度生成，浅色深色通用） */
abstract final class PdFileColors {
  static const Color archive = Color(0xFF8B5CF6);
  static const Color image = Color(0xFFF08A3C);
  static const Color media = Color(0xFFE0569B);
  static const Color book = Color(0xFFB7791F);
  static const Color word = Color(0xFF2B6CDF);
  static const Color excel = Color(0xFF1D9A5B);
  static const Color slides = Color(0xFFE2572B);
}

/** PdTint：入口图标的底色（浅色深色通用） */
abstract final class PdTint {
  static const Color files = Color(0xFF3B82F6);
  static const Color transfer = Color(0xFF10B981);
  static const Color clipboard = Color(0xFF8B5CF6);
  static const Color favorites = Color(0xFFF59E0B);
  static const Color prompts = Color(0xFFEC4899);
  static const Color screen = Color(0xFF64748B);
  static const Color workspace = Color(0xFF0EA5E9);
  static const Color remote = Color(0xFF6366F1);
  static const Color phone = Color(0xFF14B8A6);
  static const Color security = Color(0xFFEF4444);
  static const Color look = Color(0xFFF97316);
  static const Color logs = Color(0xFF78716C);
  static const Color about = Color(0xFF3B82F6);
}

/** PdAgentColors：各类会话头像底色（浅色深色通用） */
abstract final class PdAgentColors {
  static const Color claude = Color(0xFFD97757);
  static const Color codex = Color(0xFF10A37F);
  static const Color pi = Color(0xFF6B5BFF);
  static const Color dsh = Color(0xFF4D6BFE);
  static const Color terminal = Color(0xFF333333);
  static const Color assistant = Color(0xFF07C160);
  static const Color other = Color(0xFF8C8C8C);
}

/** PdDarkUi：始终为深色的界面（扫码、看图、终端顶栏）使用的固定配色 */
abstract final class PdDarkUi {
  static const Color background = Color(0xFF0B0B0B);
  static const Color text = Color(0xFFD8D8D8);
  static const Color muted = Color(0xFFB2B2B2);
  static const Color subtle = Color(0xFF999999);
  static const Color warn = Color(0xFFF2C94C);
  static const Color onLight = Color(0xFF1A1A1A);
  static const Color overlayText = Color(0xB3FFFFFF);
  static const Color overlaySpinner = Color(0x8AFFFFFF);
  static const Color shadow = Color(0x1F000000);
}
