/**
 * 页面背景：冰川玻璃与极光风格的渐变光斑、新粗野风格的点阵；每个页面各自带一层背景，页面切换时不会透出下层页面。
 */
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'styles.dart';
import 'tokens.dart';

/** PdBackdrop：给页面铺上风格背景，没有背景装饰的风格原样返回 */
class PdBackdrop extends StatelessWidget {
  const PdBackdrop({super.key, required this.style, required this.colors, required this.child});

  final PdStyle style;
  final PdColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (style.backdrop == PdBackdropKind.none) return child;
    final dark = ThemeData.estimateBrightnessForColor(colors.page) == Brightness.dark;
    return Stack(fit: StackFit.expand, children: [
      ColoredBox(color: colors.page),
      switch (style.backdrop) {
        PdBackdropKind.dots => CustomPaint(painter: _DotsPainter(style.backdropColors.firstOrNull ?? colors.divider)),
        _ => _Glow(colors: style.backdropColors, dark: dark, aurora: style.backdrop == PdBackdropKind.aurora),
      },
      child,
    ]);
  }
}

/** _Glow：几团模糊的渐变光斑，深色下更亮更浓 */
class _Glow extends StatelessWidget {
  const _Glow({required this.colors, required this.dark, required this.aurora});

  final List<Color> colors;
  final bool dark;
  final bool aurora;

  Widget orb(Color c, double size, double alpha) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [c.withValues(alpha: alpha), c.withValues(alpha: 0)])),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final a = dark ? 0.55 : 0.5;
    final cs = [for (var i = 0; i < 3; i++) colors.isEmpty ? Colors.transparent : colors[i % colors.length]];
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          return Stack(clipBehavior: Clip.hardEdge, children: [
            Positioned(left: -w * 0.35, top: -w * 0.3, child: orb(cs[0], w * 1.3, a)),
            Positioned(right: -w * 0.45, top: h * (aurora ? 0.28 : 0.2), child: orb(cs[1], w * 1.2, a * 0.85)),
            Positioned(left: -w * 0.2, bottom: -w * 0.5, child: orb(cs[2], w * 1.4, a * (aurora ? 0.9 : 0.7))),
          ]);
        },
      ),
    );
  }
}

/** _DotsPainter：规则的小圆点 */
class _DotsPainter extends CustomPainter {
  _DotsPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    const gap = 18.0;
    for (var y = gap / 2; y < size.height; y += gap) {
      for (var x = gap / 2; x < size.width; x += gap) {
        canvas.drawCircle(Offset(x, y), 1, p);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color;
}

/** PdPageTransitions：页面切换沿用 iOS 风格滑入，并给每个页面带上自己的背景 */
class PdPageTransitions extends PageTransitionsBuilder {
  const PdPageTransitions(this.style, this.colors);

  final PdStyle style;
  final PdColors colors;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final page = style.backdrop == PdBackdropKind.none ? child : PdBackdrop(style: style, colors: colors, child: child);
    return const CupertinoPageTransitionsBuilder().buildTransitions<T>(route, context, animation, secondaryAnimation, page);
  }
}
