/**
 * 可缩放的图片视图：双指捏合缩放（10% 到 800%）、双击放大与还原、拖动平移；外部可用按钮控制放大、缩小与还原。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/** ZoomController：缩放控制，既给手势使用，也给界面上的放大缩小按钮使用 */
class ZoomController extends ChangeNotifier {
  /** 最小与最大缩放倍数 */
  static const double minScale = 0.1;
  static const double maxScale = 8;

  final TransformationController transform = TransformationController();
  Size _viewport = Size.zero;
  AnimationController? _anim;

  /** scale：当前缩放倍数（取横向比例；只缩放不旋转，不能用三个轴里的最大值，否则缩小时总是 1） */
  double get scale => transform.value.storage[0];

  /** zoomed：是否不在原大小（放大或缩小时左右滑动用来平移，不切换图片） */
  bool get zoomed => (scale - 1).abs() > 0.02;

  /** canIn、canOut：还能不能继续放大、缩小 */
  bool get canIn => scale < maxScale - 0.01;
  bool get canOut => scale > minScale + 0.01;

  /** attach：视图把自己的视口大小和动画控制器交给控制器 */
  void attach(Size viewport, AnimationController anim) {
    _viewport = viewport;
    _anim = anim;
  }

  /** _target：以焦点为中心缩放到目标倍数后的矩阵，并限制在图片范围内 */
  Matrix4 _target(double next, Offset focal) {
    final cur = transform.value;
    final s = scale;
    final k = next.clamp(minScale, maxScale) / s;
    final m = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1)
      ..multiply(cur);
    final ns = m.storage[0];
    // 缩小时图片居中；放大时不能拖出视野
    m.storage[12] = ns <= 1 ? _viewport.width * (1 - ns) / 2 : m.storage[12].clamp(_viewport.width * (1 - ns), 0.0);
    m.storage[13] = ns <= 1 ? _viewport.height * (1 - ns) / 2 : m.storage[13].clamp(_viewport.height * (1 - ns), 0.0);
    return m;
  }

  /** _animateTo：平滑过渡到目标矩阵 */
  void _animateTo(Matrix4 end) {
    final a = _anim;
    if (a == null) {
      transform.value = end;
      notifyListeners();
      return;
    }
    final tween = Matrix4Tween(begin: transform.value, end: end).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic));
    void tick() {
      transform.value = tween.value;
      notifyListeners();
    }

    a
      ..removeListener(tick)
      ..stop()
      ..reset()
      ..addListener(tick);
    a.forward().whenComplete(() => a.removeListener(tick));
  }

  /** zoomBy：按倍数放大或缩小（以视口中心或指定点为中心） */
  void zoomBy(double factor, {Offset? focal}) => _animateTo(_target(scale * factor, focal ?? Offset(_viewport.width / 2, _viewport.height / 2)));

  /** toggleAt：双击时，不在原大小就还原，在原大小就放大到 2.5 倍 */
  void toggleAt(Offset focal) => _animateTo(zoomed ? Matrix4.identity() : _target(2.5, focal));

  /** settle：手势结束后把图片摆回合适的位置（缩小时居中，放大时贴边） */
  void settle() {
    final cur = transform.value;
    final next = _target(scale, Offset(_viewport.width / 2, _viewport.height / 2));
    if ((next.storage[12] - cur.storage[12]).abs() > 0.5 || (next.storage[13] - cur.storage[13]).abs() > 0.5) _animateTo(next);
    notifyListeners();
  }

  /** reset：还原到适合屏幕 */
  void reset() => _animateTo(Matrix4.identity());

  /** touched：手势缩放过程中通知界面刷新倍数显示 */
  void touched() => notifyListeners();

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }
}

/** ZoomView：把子内容放进可缩放区域，子内容撑满视口 */
class ZoomView extends StatefulWidget {
  const ZoomView({super.key, required this.controller, required this.child, this.onTap});

  final ZoomController controller;
  final Widget child;

  /** 单击（用于显示或隐藏周围的按钮） */
  final VoidCallback? onTap;

  @override
  State<ZoomView> createState() => _ZoomViewState();
}

class _ZoomViewState extends State<ZoomView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  Offset _lastTap = Offset.zero;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.controller;
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        z.attach(size, _anim);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _lastTap = d.localPosition,
          onDoubleTap: () => z.toggleAt(_lastTap),
          child: InteractiveViewer(
            transformationController: z.transform,
            minScale: ZoomController.minScale,
            maxScale: ZoomController.maxScale,
            // 允许缩到比屏幕小，手势结束后再摆正位置
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionUpdate: (_) => z.touched(),
            onInteractionEnd: (_) => z.settle(),
            child: SizedBox(width: size.width, height: size.height, child: Center(child: widget.child)),
          ),
        );
      },
    );
  }
}

/** ZoomBar：放大、缩小、还原按钮条，显示当前倍数 */
class ZoomBar extends StatelessWidget {
  const ZoomBar({super.key, required this.controller});

  final ZoomController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final pct = '${(controller.scale * 100).round()}%';
        Widget btn(IconData icon, String tip, VoidCallback? onTap) => Semantics(
              label: tip,
              button: true,
              child: InkResponse(
                onTap: onTap,
                radius: 24,
                child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 22, color: onTap == null ? Colors.white30 : Colors.white)),
              ),
            );
        return Container(
          decoration: BoxDecoration(color: const Color(0xCC1E1E1E), borderRadius: BorderRadius.circular(26)),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            btn(LucideIcons.minus300, '缩小', controller.canOut ? () => controller.zoomBy(1 / 1.6) : null),
            GestureDetector(
              onTap: controller.reset,
              child: SizedBox(width: 54, child: Center(child: Text(pct, style: const TextStyle(color: Colors.white, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])))),
            ),
            btn(LucideIcons.plus300, '放大', controller.canIn ? () => controller.zoomBy(1.6) : null),
          ]),
        );
      },
    );
  }
}
