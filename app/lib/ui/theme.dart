/**
 * 主题：由 PdColors 生成浅色与深色 Material 主题，统一顶栏、对话框、输入框、开关等控件外观。
 */
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'backdrop.dart';
import 'styles.dart';
import 'tokens.dart';

/**
 * buildTheme：生成主题
 *
 * 处理流程：
 * 1、配色方案取自所选风格的浅色或深色配色
 * 2、去掉水波纹，按压使用浅灰底色，贴近原生列表手感
 * 3、统一各控件的颜色与形状，圆角、标题字体、页面背景跟随风格
 */
ThemeData buildTheme(Brightness b, [PdThemeSpec? spec]) {
  final look = (spec ?? PdThemes.wechat).look(b);
  final c = look.colors;
  final st = look.style;
  // 1、配色
  final onAccent = c.accent.computeLuminance() > 0.5 ? const Color(0xFF111111) : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
    primary: c.accent,
    onPrimary: onAccent,
    surface: c.card,
    onSurface: c.text,
    surfaceContainerHighest: c.input,
    error: c.danger,
    outline: c.divider,
    outlineVariant: c.divider,
  );
  final barDark = ThemeData.estimateBrightnessForColor(c.topBar) == Brightness.dark;
  final overlay = barDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
  final base = Typography.material2021(platform: TargetPlatform.android).black.apply(bodyColor: c.text, displayColor: c.text);
  // 控件文字都从基础文字样式派生，保证字体一致
  TextStyle t(double size, Color color, [FontWeight? w]) => base.bodyMedium!.copyWith(fontSize: size, color: color, fontWeight: w, height: null);
  // 标题类文字：衬线风格换字体，其余沿用默认字体
  TextStyle head(double size, Color color) => t(size, color, st.titleWeight).copyWith(fontFamilyFallback: st.titleFont, fontFamily: st.titleFont?.first);
  final textTheme = base.copyWith(
    bodyLarge: t(PdFont.body, c.text),
    bodyMedium: t(PdFont.item, c.text),
    bodySmall: t(PdFont.summary, c.text3),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: st.backdrop == PdBackdropKind.none ? c.page : Colors.transparent,
    canvasColor: c.page,
    dividerColor: c.divider,
    // 2、按压反馈
    splashFactory: NoSplash.splashFactory,
    highlightColor: c.pressed,
    hoverColor: Colors.transparent,
    extensions: [c, st],
    // 3、控件
    appBarTheme: AppBarTheme(
      backgroundColor: c.topBar,
      foregroundColor: c.onBar,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: !st.titleLeft,
      toolbarHeight: PdSize.topBar,
      systemOverlayStyle: overlay,
      titleTextStyle: head(PdFont.title, c.onBar),
    ),
    textTheme: textTheme,
    dividerTheme: DividerThemeData(color: c.divider, thickness: PdSize.divider, space: PdSize.divider),
    dialogTheme: DialogThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(st.cardRadius), side: st.outline > 0 ? BorderSide(color: st.outlineColor ?? c.divider, width: st.outline) : BorderSide.none),
      titleTextStyle: head(PdFont.title, c.text),
      contentTextStyle: t(PdFont.item, c.text2).copyWith(height: 1.5),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(st.cardRadius)), side: st.outline > 0 ? BorderSide(color: st.outlineColor ?? c.divider, width: st.outline) : BorderSide.none),
      showDragHandle: false,
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 4,
      shadowColor: PdDarkUi.shadow,
      color: c.menu,
      surfaceTintColor: Colors.transparent,
      textStyle: t(PdFont.item, Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(st.smallRadius)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.toast,
      contentTextStyle: t(14, Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(st.smallRadius)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.card,
      hintStyle: t(PdFont.item, c.text4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(st.smallRadius), borderSide: BorderSide.none),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.input),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.page, circularTrackColor: Colors.transparent),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accent, selectionColor: c.accent.withValues(alpha: 0.3), selectionHandleColor: c.accent),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: onAccent,
        minimumSize: const Size(0, PdSize.touch),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(st.smallRadius), side: st.shadow == PdShadowKind.hard ? BorderSide(color: st.outlineColor ?? c.divider, width: st.outline) : BorderSide.none),
        textStyle: t(PdFont.item, Colors.white, FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: c.accent, textStyle: t(PdFont.item, c.accent))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(textStyle: t(PdFont.item, c.text2))),
    pageTransitionsTheme: PageTransitionsTheme(builders: {
      TargetPlatform.android: PdPageTransitions(st, c),
      TargetPlatform.iOS: PdPageTransitions(st, c),
    }),
  );
}
