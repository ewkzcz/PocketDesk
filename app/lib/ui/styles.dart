/**
 * 界面风格：八套风格（微信、Codex、QQ、Claude、冰川玻璃、新粗野、极光、纸刊），每套含浅色与深色两组配色，
 * 以及圆角、头像形状、气泡、卡片、顶栏、底栏、背景等版式参数。页面只读取这里的常量，不写死颜色与圆角。
 */
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/** PdBackdropKind：页面背景装饰 */
enum PdBackdropKind { none, glow, aurora, dots }

/** PdShadowKind：卡片阴影类型 */
enum PdShadowKind { none, soft, hard }

/** PdStyle：一套风格的版式参数，通过 ThemeExtension 挂在主题上 */
@immutable
class PdStyle extends ThemeExtension<PdStyle> {
  const PdStyle({
    required this.id,
    this.cardRadius = PdSize.cardRadius,
    this.smallRadius = PdSize.smallRadius,
    this.avatarRadius = PdSize.avatarRadius,
    this.bubbleRadius = PdSize.bubbleRadius,
    this.bubbleTail = true,
    this.inset = false,
    this.outline = 0,
    this.outlineColor,
    this.shadow = PdShadowKind.none,
    this.shadowColor = const Color(0x1A000000),
    this.titleFont,
    this.titleWeight = FontWeight.w600,
    this.titleLeft = false,
    this.tabPill = false,
    this.flatAgent = false,
    this.mineGradient,
    this.backdrop = PdBackdropKind.none,
    this.backdropColors = const [],
    this.barFilled = false,
    this.cardAlpha = 1,
    this.heroGradient,
  });

  final String id;

  /** 卡片、分组圆角 */
  final double cardRadius;

  /** 按钮、输入框、小卡片圆角 */
  final double smallRadius;

  /** 头像圆角（取很大的值即为圆形） */
  final double avatarRadius;

  /** 气泡圆角 */
  final double bubbleRadius;

  /** 气泡是否带指向头像的小三角 */
  final bool bubbleTail;

  /** 设置行与列表是否做成独立的圆角卡片（否则通栏） */
  final bool inset;

  /** 卡片描边宽度，0 为不描边 */
  final double outline;

  /** 卡片描边颜色，为空时用分割线颜色 */
  final Color? outlineColor;
  final PdShadowKind shadow;
  final Color shadowColor;

  /** 大标题字体（衬线风格使用），为空时用默认字体 */
  final List<String>? titleFont;
  final FontWeight titleWeight;

  /** 顶栏标题靠左 */
  final bool titleLeft;

  /** 底栏做成悬浮胶囊 */
  final bool tabPill;

  /** Agent 回复不画气泡底色，直接铺在页面上 */
  final bool flatAgent;

  /** 我方气泡渐变色 */
  final List<Color>? mineGradient;
  final PdBackdropKind backdrop;
  final List<Color> backdropColors;

  /** 顶栏使用强调色填充 */
  final bool barFilled;

  /** 卡片底色透明度（毛玻璃风格小于 1） */
  final double cardAlpha;

  /** 头部装饰渐变（我页顶部卡片等） */
  final List<Color>? heroGradient;

  /** isCircle：头像是否为圆形 */
  bool get isCircle => avatarRadius >= 100;

  /** radiusFor：按头像边长得到圆角 */
  double avatarRadiusFor(double size) => avatarRadius >= 100 ? size / 2 : avatarRadius * (size / PdSize.avatar).clamp(0.7, 1.4);

  /** cardColor：卡片底色（含透明度） */
  Color cardColor(PdColors c) => cardAlpha >= 1 ? c.card : c.card.withValues(alpha: cardAlpha);

  /** border：卡片描边 */
  Border? border(PdColors c) => outline <= 0 ? null : Border.all(color: outlineColor ?? c.divider, width: outline);

  /** shadows：卡片阴影 */
  List<BoxShadow> get shadows => switch (shadow) {
        PdShadowKind.none => const [],
        PdShadowKind.soft => [BoxShadow(color: shadowColor, blurRadius: 24, offset: const Offset(0, 8))],
        PdShadowKind.hard => [BoxShadow(color: shadowColor, offset: const Offset(3, 3))],
      };

  /** card：卡片外观 */
  BoxDecoration card(PdColors c, {double? radius, Color? color}) => BoxDecoration(
        color: color ?? cardColor(c),
        borderRadius: BorderRadius.circular(radius ?? cardRadius),
        border: border(c),
        boxShadow: shadows,
      );

  @override
  PdStyle copyWith() => this;

  @override
  PdStyle lerp(ThemeExtension<PdStyle>? other, double t) => t < 0.5 ? this : (other is PdStyle ? other : this);
}

/** 取当前主题风格参数的便捷扩展 */
extension PdStyleTheme on BuildContext {
  PdStyle get style => Theme.of(this).extension<PdStyle>() ?? PdThemes.wechat.light.style;
}

/** PdLook：一套风格在某种明暗下的配色与版式 */
class PdLook {
  const PdLook(this.colors, this.style);

  final PdColors colors;
  final PdStyle style;
}

/** PdThemeSpec：风格说明（名称、简介、预览色）与浅色深色两组外观 */
class PdThemeSpec {
  const PdThemeSpec({required this.id, required this.name, required this.desc, required this.light, required this.dark, required this.swatch});

  final String id;
  final String name;
  final String desc;
  final PdLook light;
  final PdLook dark;

  /** 预览用的四个代表色：页面、卡片、强调、文字 */
  final List<Color> swatch;

  PdLook look(Brightness b) => b == Brightness.dark ? dark : light;
}

/** _c：用少量基础色生成一整套配色，其余沿用通用值 */
PdColors _c({
  required Color accent,
  required Color page,
  required Color card,
  required Color text,
  required Color text2,
  required Color text3,
  required Color divider,
  required Color mine,
  required Color mineText,
  required Color agent,
  Color? bar,
  Color? topBar,
  Color? onBar,
  Color? input,
  Color? text4,
  Color? danger,
  Color? tool,
  Color? chip,
  Color? pressed,
  Color? accentSoft,
  Color? field,
  Color? menu,
  Color? toast,
  Color? info,
  Color? neutral,
  Color? warnBg,
  Color? warnBorder,
  Color? warnText,
}) {
  final dark = ThemeData.estimateBrightnessForColor(page) == Brightness.dark;
  return PdColors(
    accent: accent,
    page: page,
    bar: bar ?? card,
    card: card,
    input: input ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), page) : Color.alphaBlend(Colors.black.withValues(alpha: 0.06), page)),
    bubbleMine: mine,
    bubbleMineText: mineText,
    bubbleAgent: agent,
    divider: divider,
    text: text,
    text2: text2,
    text3: text3,
    text4: text4 ?? text3.withValues(alpha: 0.55),
    danger: danger ?? (dark ? const Color(0xFFFF453A) : const Color(0xFFE5362B)),
    warnBg: warnBg ?? (dark ? const Color(0xFF2E2412) : const Color(0xFFFFF6E5)),
    warnBorder: warnBorder ?? (dark ? const Color(0xFF7A5A1E) : const Color(0xFFFFCC66)),
    warnText: warnText ?? (dark ? const Color(0xFFFFB340) : const Color(0xFFB25E00)),
    tool: tool ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.05), card) : Color.alphaBlend(Colors.black.withValues(alpha: 0.035), card)),
    chip: chip ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), card) : Color.alphaBlend(Colors.black.withValues(alpha: 0.05), page)),
    pressed: pressed ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), page) : Color.alphaBlend(Colors.black.withValues(alpha: 0.08), page)),
    accentSoft: accentSoft ?? accent.withValues(alpha: dark ? 0.2 : 0.12),
    termBg: const Color(0xFF1E1E1E),
    termBar: const Color(0xFF262626),
    termKey: const Color(0xFF3A3A3A),
    termText: const Color(0xFFD8D8D8),
    info: info ?? const Color(0xFF0A84FF),
    neutral: neutral ?? text3,
    field: field ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.08), card) : card),
    menu: menu ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.1), card) : const Color(0xFF3A3A3C)),
    toast: toast ?? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: 0.12), card) : const Color(0xE6222222)),
    onBar: onBar ?? text,
    topBar: topBar ?? bar ?? card,
  );
}

/** PdThemes：全部风格 */
abstract final class PdThemes {
  /** 微信：绿色气泡、通栏列表、方头像，保持原有观感 */
  static final PdThemeSpec wechat = PdThemeSpec(
    id: 'wechat',
    name: '微信',
    desc: '绿色气泡，通栏列表',
    swatch: const [Color(0xFFF2F2F7), Color(0xFFFFFFFF), Color(0xFF07C160), Color(0xFF000000)],
    light: const PdLook(PdColors.light, PdStyle(id: 'wechat')),
    dark: const PdLook(PdColors.dark, PdStyle(id: 'wechat')),
  );

  /** Codex：近乎单色的开发工具质感，细描边，Agent 回复直接铺开 */
  static final PdThemeSpec codex = PdThemeSpec(
    id: 'codex',
    name: 'Codex',
    desc: '克制的单色，细描边，像开发工具',
    swatch: const [Color(0xFFF7F7F8), Color(0xFFFFFFFF), Color(0xFF0169CC), Color(0xFF0D0D0D)],
    light: PdLook(
      _c(
        accent: const Color(0xFF0169CC),
        page: const Color(0xFFF7F7F8),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFF7F7F8),
        text: const Color(0xFF0D0D0D),
        text2: const Color(0xFF424242),
        text3: const Color(0xFF7A7A7F),
        divider: const Color(0xFFE6E6E8),
        mine: const Color(0xFFEDEDEF),
        mineText: const Color(0xFF0D0D0D),
        agent: const Color(0xFFFFFFFF),
        menu: const Color(0xFF1F1F21),
      ),
      const PdStyle(id: 'codex', cardRadius: 12, smallRadius: 8, avatarRadius: 9, bubbleRadius: 14, bubbleTail: false, inset: true, outline: 1, flatAgent: true),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFF339CFF),
        page: const Color(0xFF0D0D0D),
        card: const Color(0xFF171717),
        bar: const Color(0xFF0D0D0D),
        text: const Color(0xFFF2F2F2),
        text2: const Color(0xFFC4C4C6),
        text3: const Color(0xFF8B8B90),
        divider: const Color(0xFF2A2A2C),
        mine: const Color(0xFF262628),
        mineText: const Color(0xFFF2F2F2),
        agent: const Color(0xFF171717),
      ),
      const PdStyle(id: 'codex', cardRadius: 12, smallRadius: 8, avatarRadius: 9, bubbleRadius: 14, bubbleTail: false, inset: true, outline: 1, flatAgent: true),
    ),
  );

  /** QQ：蓝色顶栏，圆形头像，圆润气泡 */
  static final PdThemeSpec qq = PdThemeSpec(
    id: 'qq',
    name: 'QQ',
    desc: '蓝色顶栏，圆形头像，圆润气泡',
    swatch: const [Color(0xFFF3F6FB), Color(0xFFFFFFFF), Color(0xFF0A9CDB), Color(0xFF1F2A44)],
    light: PdLook(
      _c(
        accent: const Color(0xFF0A9CDB),
        page: const Color(0xFFF3F6FB),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFFFFFFF),
        topBar: const Color(0xFF0A9CDB),
        onBar: Colors.white,
        text: const Color(0xFF1F2A44),
        text2: const Color(0xFF4A5673),
        text3: const Color(0xFF8A94AB),
        divider: const Color(0xFFE8ECF4),
        mine: const Color(0xFF0A9CDB),
        mineText: Colors.white,
        agent: const Color(0xFFFFFFFF),
      ),
      const PdStyle(id: 'qq', cardRadius: 16, smallRadius: 12, avatarRadius: 100, bubbleRadius: 16, bubbleTail: false, barFilled: true, heroGradient: [Color(0xFF0A9CDB), Color(0xFF3CC4F5)]),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFF2BBFF8),
        page: const Color(0xFF0E131C),
        card: const Color(0xFF171E2B),
        bar: const Color(0xFF171E2B),
        topBar: const Color(0xFF0F8FC4),
        onBar: Colors.white,
        text: const Color(0xFFE8EEF8),
        text2: const Color(0xFFB4BFD4),
        text3: const Color(0xFF7D8aa3),
        divider: const Color(0xFF232C3D),
        mine: const Color(0xFF0F8FC4),
        mineText: Colors.white,
        agent: const Color(0xFF1D2636),
      ),
      const PdStyle(id: 'qq', cardRadius: 16, smallRadius: 12, avatarRadius: 100, bubbleRadius: 16, bubbleTail: false, barFilled: true, heroGradient: [Color(0xFF0F8FC4), Color(0xFF2BBFF8)]),
    ),
  );

  /** Claude：米白纸面，赤陶强调色，衬线标题，回复铺开不画气泡 */
  static final PdThemeSpec claude = PdThemeSpec(
    id: 'claude',
    name: 'Claude',
    desc: '米白纸面，赤陶强调色，衬线标题',
    swatch: const [Color(0xFFFAF9F5), Color(0xFFFFFFFF), Color(0xFFD97757), Color(0xFF141413)],
    light: PdLook(
      _c(
        accent: const Color(0xFFC6613F),
        page: const Color(0xFFFAF9F5),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFFAF9F5),
        text: const Color(0xFF141413),
        text2: const Color(0xFF3D3D3A),
        text3: const Color(0xFF73726C),
        divider: const Color(0xFFEAE7DC),
        mine: const Color(0xFFF0EEE6),
        mineText: const Color(0xFF141413),
        agent: const Color(0xFFFAF9F5),
        accentSoft: const Color(0xFFF8E8E0),
        menu: const Color(0xFF30302E),
      ),
      const PdStyle(
        id: 'claude',
        cardRadius: 18,
        smallRadius: 12,
        avatarRadius: 12,
        bubbleRadius: 18,
        bubbleTail: false,
        inset: true,
        outline: 0.8,
        flatAgent: true,
        titleFont: ['Georgia', 'Songti SC', 'Noto Serif CJK SC', 'serif'],
        titleWeight: FontWeight.w500,
        titleLeft: true,
      ),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFFD97757),
        page: const Color(0xFF262624),
        card: const Color(0xFF30302E),
        bar: const Color(0xFF262624),
        text: const Color(0xFFFAF9F5),
        text2: const Color(0xFFD9D8D1),
        text3: const Color(0xFF9C9A92),
        divider: const Color(0xFF3D3D3A),
        mine: const Color(0xFF3A3A37),
        mineText: const Color(0xFFFAF9F5),
        agent: const Color(0xFF262624),
      ),
      const PdStyle(
        id: 'claude',
        cardRadius: 18,
        smallRadius: 12,
        avatarRadius: 12,
        bubbleRadius: 18,
        bubbleTail: false,
        inset: true,
        outline: 0.8,
        flatAgent: true,
        titleFont: ['Georgia', 'Songti SC', 'Noto Serif CJK SC', 'serif'],
        titleWeight: FontWeight.w500,
        titleLeft: true,
      ),
    ),
  );

  /** 冰川玻璃：冷色渐变光斑做底，半透明玻璃卡片，悬浮胶囊底栏，大圆角 */
  static final PdThemeSpec glacier = PdThemeSpec(
    id: 'glacier',
    name: '冰川玻璃',
    desc: '渐变光斑，半透明玻璃，悬浮底栏',
    swatch: const [Color(0xFFEAF1FF), Color(0xFFFFFFFF), Color(0xFF2F66EE), Color(0xFF142440)],
    light: PdLook(
      _c(
        accent: const Color(0xFF2F66EE),
        page: const Color(0xFFF2F6FD),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFF2F6FD),
        text: const Color(0xFF142440),
        text2: const Color(0xFF43526B),
        text3: const Color(0xFF6B7A94),
        divider: const Color(0x1F506EAA),
        mine: const Color(0xFF3A6FF0),
        mineText: Colors.white,
        agent: const Color(0xFFFFFFFF),
        accentSoft: const Color(0xFFE3ECFF),
        info: const Color(0xFF2F66EE),
        menu: const Color(0xFF1B2A4A),
      ),
      const PdStyle(
        id: 'glacier',
        cardRadius: 26,
        smallRadius: 16,
        avatarRadius: 16,
        bubbleRadius: 22,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0xE6FFFFFF),
        shadow: PdShadowKind.soft,
        shadowColor: Color(0x1F2F66EE),
        tabPill: true,
        mineGradient: [Color(0xFF2F66EE), Color(0xFF35B3DA)],
        backdrop: PdBackdropKind.glow,
        backdropColors: [Color(0xFF8CBEFF), Color(0xFF6ED2EB), Color(0xFFB9A5FA)],
        cardAlpha: 0.78,
        titleWeight: FontWeight.w700,
        heroGradient: [Color(0xFF2F66EE), Color(0xFF35B3DA)],
      ),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFF7BA6FF),
        page: const Color(0xFF0A1226),
        card: const Color(0xFF16213C),
        bar: const Color(0xFF0A1226),
        text: const Color(0xFFE9F0FF),
        text2: const Color(0xFFB7C4E2),
        text3: const Color(0xFF8091B5),
        divider: const Color(0x1FFFFFFF),
        mine: const Color(0xFF3A6FF0),
        mineText: Colors.white,
        agent: const Color(0xFF16213C),
      ),
      const PdStyle(
        id: 'glacier',
        cardRadius: 26,
        smallRadius: 16,
        avatarRadius: 16,
        bubbleRadius: 22,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0x24FFFFFF),
        shadow: PdShadowKind.soft,
        shadowColor: Color(0x66000000),
        tabPill: true,
        mineGradient: [Color(0xFF3A6FF0), Color(0xFF22B8D8)],
        backdrop: PdBackdropKind.glow,
        backdropColors: [Color(0xFF2F4FD8), Color(0xFF0E8FB0), Color(0xFF5B3FC4)],
        cardAlpha: 0.72,
        titleWeight: FontWeight.w700,
        heroGradient: [Color(0xFF3A6FF0), Color(0xFF22B8D8)],
      ),
    ),
  );

  /** 新粗野：粗黑描边，硬阴影，高饱和色块，小圆角 */
  static final PdThemeSpec brutal = PdThemeSpec(
    id: 'brutal',
    name: '新粗野',
    desc: '粗黑描边，硬阴影，高饱和色块',
    swatch: const [Color(0xFFFFF6D6), Color(0xFFFFFFFF), Color(0xFFFF5C39), Color(0xFF111111)],
    light: PdLook(
      _c(
        accent: const Color(0xFFFF5C39),
        page: const Color(0xFFFFF6D6),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFFFFFFF),
        topBar: const Color(0xFFFFD93D),
        text: const Color(0xFF111111),
        text2: const Color(0xFF2B2B2B),
        text3: const Color(0xFF5A5648),
        divider: const Color(0xFF111111),
        mine: const Color(0xFFFFD93D),
        mineText: const Color(0xFF111111),
        agent: const Color(0xFFFFFFFF),
        accentSoft: const Color(0xFFFFE3DB),
        info: const Color(0xFF2D5BFF),
        menu: const Color(0xFF111111),
      ),
      const PdStyle(
        id: 'brutal',
        cardRadius: 8,
        smallRadius: 6,
        avatarRadius: 6,
        bubbleRadius: 8,
        bubbleTail: false,
        inset: true,
        outline: 2,
        outlineColor: Color(0xFF111111),
        shadow: PdShadowKind.hard,
        shadowColor: Color(0xFF111111),
        titleWeight: FontWeight.w900,
        titleLeft: true,
        backdrop: PdBackdropKind.dots,
        backdropColors: [Color(0x26111111)],
      ),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFFFF6B4A),
        page: const Color(0xFF141414),
        card: const Color(0xFF1F1F1F),
        bar: const Color(0xFF1F1F1F),
        topBar: const Color(0xFFFFD93D),
        onBar: const Color(0xFF111111),
        text: const Color(0xFFFFF8E1),
        text2: const Color(0xFFE6E0C8),
        text3: const Color(0xFFA39E8A),
        divider: const Color(0xFFFFF8E1),
        mine: const Color(0xFFFFD93D),
        mineText: const Color(0xFF111111),
        agent: const Color(0xFF1F1F1F),
        info: const Color(0xFF6C8CFF),
      ),
      const PdStyle(
        id: 'brutal',
        cardRadius: 8,
        smallRadius: 6,
        avatarRadius: 6,
        bubbleRadius: 8,
        bubbleTail: false,
        inset: true,
        outline: 2,
        outlineColor: Color(0xFFFFF8E1),
        shadow: PdShadowKind.hard,
        shadowColor: Color(0xFFFFD93D),
        titleWeight: FontWeight.w900,
        titleLeft: true,
        barFilled: true,
        backdrop: PdBackdropKind.dots,
        backdropColors: [Color(0x26FFF8E1)],
      ),
    ),
  );

  /** 极光：深色夜空，紫青粉渐变光晕，发光描边 */
  static final PdThemeSpec aurora = PdThemeSpec(
    id: 'aurora',
    name: '极光',
    desc: '夜空底色，紫青渐变光晕',
    swatch: const [Color(0xFF07070D), Color(0xFF14141F), Color(0xFFA78BFA), Color(0xFFF1EEFF)],
    light: PdLook(
      _c(
        accent: const Color(0xFF6D4AE8),
        page: const Color(0xFFF5F2FF),
        card: const Color(0xFFFFFFFF),
        bar: const Color(0xFFF5F2FF),
        text: const Color(0xFF1B1530),
        text2: const Color(0xFF4A4166),
        text3: const Color(0xFF7D7599),
        divider: const Color(0x1F6D4AE8),
        mine: const Color(0xFF6D4AE8),
        mineText: Colors.white,
        agent: const Color(0xFFFFFFFF),
        accentSoft: const Color(0xFFEBE4FF),
      ),
      const PdStyle(
        id: 'aurora',
        cardRadius: 20,
        smallRadius: 14,
        avatarRadius: 14,
        bubbleRadius: 18,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0x266D4AE8),
        shadow: PdShadowKind.soft,
        shadowColor: Color(0x1F6D4AE8),
        tabPill: true,
        mineGradient: [Color(0xFF6D4AE8), Color(0xFFD946EF)],
        backdrop: PdBackdropKind.aurora,
        backdropColors: [Color(0xFFC4B5FD), Color(0xFF99F6E4), Color(0xFFF9A8D4)],
        cardAlpha: 0.82,
        heroGradient: [Color(0xFF6D4AE8), Color(0xFFD946EF)],
      ),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFFA78BFA),
        page: const Color(0xFF07070D),
        card: const Color(0xFF14141F),
        bar: const Color(0xFF07070D),
        text: const Color(0xFFF1EEFF),
        text2: const Color(0xFFC3BCE0),
        text3: const Color(0xFF8A84A8),
        divider: const Color(0x1AFFFFFF),
        mine: const Color(0xFF6D4AE8),
        mineText: Colors.white,
        agent: const Color(0xFF14141F),
        info: const Color(0xFF67E8F9),
      ),
      const PdStyle(
        id: 'aurora',
        cardRadius: 20,
        smallRadius: 14,
        avatarRadius: 14,
        bubbleRadius: 18,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0x29FFFFFF),
        shadow: PdShadowKind.soft,
        shadowColor: Color(0x663B1FA8),
        tabPill: true,
        mineGradient: [Color(0xFF6D4AE8), Color(0xFFD946EF)],
        backdrop: PdBackdropKind.aurora,
        backdropColors: [Color(0xFF6D28D9), Color(0xFF0891B2), Color(0xFFDB2777)],
        cardAlpha: 0.8,
        heroGradient: [Color(0xFF6D4AE8), Color(0xFFD946EF)],
      ),
    ),
  );

  /** 纸刊：暖白纸张，衬线大标题，细线分隔，朱红点缀，无阴影 */
  static final PdThemeSpec paper = PdThemeSpec(
    id: 'paper',
    name: '纸刊',
    desc: '暖白纸张，衬线标题，朱红点缀',
    swatch: const [Color(0xFFF4EFE6), Color(0xFFFBF8F1), Color(0xFFC8321E), Color(0xFF1B1B1B)],
    light: PdLook(
      _c(
        accent: const Color(0xFFC8321E),
        page: const Color(0xFFF4EFE6),
        card: const Color(0xFFFBF8F1),
        bar: const Color(0xFFF4EFE6),
        text: const Color(0xFF1B1B1B),
        text2: const Color(0xFF3F3B33),
        text3: const Color(0xFF7A7364),
        divider: const Color(0xFFD9D2C3),
        mine: const Color(0xFF1B1B1B),
        mineText: const Color(0xFFF4EFE6),
        agent: const Color(0xFFF4EFE6),
        accentSoft: const Color(0xFFF3DDD6),
        menu: const Color(0xFF1B1B1B),
      ),
      const PdStyle(
        id: 'paper',
        cardRadius: 2,
        smallRadius: 2,
        avatarRadius: 2,
        bubbleRadius: 2,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0xFFD9D2C3),
        flatAgent: true,
        titleFont: ['Georgia', 'Songti SC', 'Noto Serif CJK SC', 'serif'],
        titleWeight: FontWeight.w700,
        titleLeft: true,
      ),
    ),
    dark: PdLook(
      _c(
        accent: const Color(0xFFE8553F),
        page: const Color(0xFF16140F),
        card: const Color(0xFF1F1C15),
        bar: const Color(0xFF16140F),
        text: const Color(0xFFEDE6D6),
        text2: const Color(0xFFCFC7B4),
        text3: const Color(0xFF948C79),
        divider: const Color(0xFF38342A),
        mine: const Color(0xFFEDE6D6),
        mineText: const Color(0xFF16140F),
        agent: const Color(0xFF16140F),
      ),
      const PdStyle(
        id: 'paper',
        cardRadius: 2,
        smallRadius: 2,
        avatarRadius: 2,
        bubbleRadius: 2,
        bubbleTail: false,
        inset: true,
        outline: 1,
        outlineColor: Color(0xFF38342A),
        flatAgent: true,
        titleFont: ['Georgia', 'Songti SC', 'Noto Serif CJK SC', 'serif'],
        titleWeight: FontWeight.w700,
        titleLeft: true,
      ),
    ),
  );

  /** all：切换界面里的展示顺序 */
  static final List<PdThemeSpec> all = [wechat, codex, qq, claude, glacier, aurora, brutal, paper];

  /** byId：按标识取风格，找不到时用微信 */
  static PdThemeSpec byId(String id) => all.firstWhere((t) => t.id == id, orElse: () => wechat);
}
