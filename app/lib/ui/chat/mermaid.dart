/**
 * Mermaid 图表：在文档与聊天里把 mermaid 代码块画成图；点击图表全屏查看，可双指缩放、拖动；语法错误时显示原代码。
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../tokens.dart';
import '../widgets.dart';

/**
 * MermaidView：一个图表
 *
 * 全屏模式下图表保持原始大小，页面可缩放与拖动；行内模式按屏幕宽度缩放并随图表高度自适应。
 */
class MermaidView extends StatefulWidget {
  const MermaidView({super.key, required this.code, this.full = false});

  final String code;
  final bool full;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView> {
  late final WebViewController _web;
  bool _ready = false;
  String _error = '';
  double _height = 120;
  bool _dark = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel('R', onMessageReceived: (_) {
        _ready = true;
        _draw();
      })
      ..addJavaScriptChannel('H', onMessageReceived: (m) {
        final h = double.tryParse(m.message);
        if (h != null && mounted) {
          setState(() {
            _error = '';
            _height = h.clamp(40, 2000);
          });
        }
      })
      ..addJavaScriptChannel('E', onMessageReceived: (m) {
        if (mounted) setState(() => _error = m.message);
      })
      ..loadFlutterAsset('assets/mermaid/index.html');
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark != _dark) {
      _dark = dark;
      if (_ready) _draw();
    }
  }

  @override
  void didUpdateWidget(MermaidView old) {
    super.didUpdateWidget(old);
    if (old.code != widget.code) {
      // 聊天里代码逐段到达，稍等一下再画，避免每一段都重画
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 500), _draw);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /** _draw：把代码交给页面绘制 */
  void _draw() {
    if (!_ready) return;
    final js = 'render(${_quote(widget.code)}, $_dark, ${!widget.full})';
    unawaited(_web.runJavaScript(js));
  }

  /** _quote：转成 JS 字符串 */
  static String _quote(String s) => "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll('\n', r'\n').replaceAll('\r', '')}'";

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    if (_error.isNotEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: c.tool, borderRadius: BorderRadius.circular(PdSize.smallRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('图表语法有误，无法绘制', style: TextStyle(fontSize: PdFont.summary, color: c.danger)),
          const SizedBox(height: 6),
          SelectableText(widget.code, style: TextStyle(fontSize: 12.5, height: 1.5, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback, color: c.text)),
        ]),
      );
    }
    final view = SizedBox(height: widget.full ? null : _height, child: WebViewWidget(controller: _web));
    if (widget.full) return view;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(color: c.card, borderRadius: BorderRadius.circular(PdSize.smallRadius), border: Border.all(color: c.divider, width: 0.5)),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        IgnorePointer(child: view),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MermaidPage(code: widget.code))),
          ),
        ),
        Positioned(top: 4, right: 4, child: Icon(LucideIcons.maximize2300, size: 16, color: c.text4)),
      ]),
    );
  }
}

/** MermaidPage：全屏查看图表 */
class MermaidPage extends StatelessWidget {
  const MermaidPage({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => Scaffold(appBar: const PdBar(title: '图表'), body: MermaidView(code: code, full: true));
}
