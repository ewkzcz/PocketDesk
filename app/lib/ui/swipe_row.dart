/**
 * 左滑操作行：向左滑动露出右侧操作按钮，同一时间只展开一行，点击内容或其他行时收起。
 */
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/** SwipeAction：一个操作按钮 */
class SwipeAction {
  const SwipeAction(this.label, this.color, this.onTap, {this.width = 76});

  final String label;
  final Color color;
  final VoidCallback onTap;
  final double width;
}

/** 当前展开的行，保证只有一行展开 */
final _openRow = ValueNotifier<Object?>(null);

/**
 * SwipeRow：可左滑的行
 */
class SwipeRow extends StatefulWidget {
  const SwipeRow({super.key, required this.child, required this.actions, this.onTap, this.onLongPress});

  final Widget child;
  final List<SwipeAction> actions;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /** closeAll：收起所有展开的行 */
  static void closeAll() => _openRow.value = null;

  @override
  State<SwipeRow> createState() => _SwipeRowState();
}

class _SwipeRowState extends State<SwipeRow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: PdMotion.normal);
  final _token = Object();

  double get _max => widget.actions.fold(0, (s, a) => s + a.width);

  @override
  void initState() {
    super.initState();
    _openRow.addListener(_onOther);
  }

  @override
  void dispose() {
    _openRow.removeListener(_onOther);
    if (_openRow.value == _token) _openRow.value = null;
    _ctrl.dispose();
    super.dispose();
  }

  /** _onOther：其他行展开时收起自己 */
  void _onOther() {
    if (_openRow.value != _token && _ctrl.value > 0) _ctrl.animateTo(0, curve: PdMotion.curve);
  }

  /** _settle：松手后按位置与速度决定展开或收起 */
  void _settle(double velocity) {
    final open = velocity < -300 || (velocity <= 300 && _ctrl.value > 0.4);
    _ctrl.animateTo(open ? 1 : 0, curve: PdMotion.curve);
    if (open) {
      _openRow.value = _token;
    } else if (_openRow.value == _token) {
      _openRow.value = null;
    }
  }

  /** _close：收起 */
  void _close() {
    _ctrl.animateTo(0, curve: PdMotion.curve);
    if (_openRow.value == _token) _openRow.value = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          if (_openRow.value != _token) _openRow.value = _token;
        },
        onHorizontalDragUpdate: (d) => _ctrl.value = (_ctrl.value - d.primaryDelta! / _max).clamp(0.0, 1.0),
        onHorizontalDragEnd: (d) => _settle(d.primaryVelocity ?? 0),
        onTap: () {
          if (_ctrl.value > 0) {
            _close();
          } else {
            SwipeRow.closeAll();
            widget.onTap?.call();
          }
        },
        onLongPress: widget.onLongPress,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, child) {
              final dx = _ctrl.value * _max;
              return Stack(children: [
                // 操作按钮铺在右侧，随内容滑出
                if (dx > 0)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    width: dx,
                    child: Row(children: [
                      for (final a in widget.actions)
                        Expanded(
                          flex: (a.width * 10).round(),
                          child: GestureDetector(
                            onTap: () {
                              _close();
                              a.onTap();
                            },
                            child: Container(
                              color: a.color,
                              alignment: Alignment.center,
                              child: Text(a.label, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: const TextStyle(color: Colors.white, fontSize: PdFont.item)),
                            ),
                          ),
                        ),
                    ]),
                  ),
                Transform.translate(offset: Offset(-dx, 0), child: child),
              ]);
            },
            child: widget.child,
          ),
        ),
      );
  }
}
