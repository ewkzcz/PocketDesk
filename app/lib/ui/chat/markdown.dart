/**
 * Markdown 渲染：Agent 回复按当前主题渲染标题、列表、表格、行内代码与代码块，代码使用等宽字体。
 */
library;

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../tokens.dart';

/**
 * MdText：渲染一段 Markdown
 */
class MdText extends StatelessWidget {
  const MdText(this.data, {super.key, this.fontSize = 15, this.color});

  final String data;
  final double fontSize;
  final Color? color;

  /** config：按主题生成配置 */
  static MarkdownConfig config(BuildContext context, {double fontSize = 15, Color? color}) {
    final c = context.pd;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = TextStyle(fontSize: fontSize, height: 1.55, color: color ?? c.text);
    final mono = TextStyle(fontSize: fontSize - 2.5, height: 1.5, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback);
    final base = dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
    final pre = (dark ? PreConfig.darkConfig : const PreConfig()).copy(
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.symmetric(vertical: 6),
      textStyle: mono,
      decoration: BoxDecoration(color: c.tool, borderRadius: BorderRadius.circular(PdSize.smallRadius)),
    );
    return base.copy(configs: [
      PConfig(textStyle: text),
      pre,
      CodeConfig(style: mono.copyWith(backgroundColor: c.chip, color: c.text)),
      LinkConfig(style: TextStyle(color: c.info, decoration: TextDecoration.none)),
      H1Config(style: text.copyWith(fontSize: fontSize + 5, fontWeight: FontWeight.w600)),
      H2Config(style: text.copyWith(fontSize: fontSize + 3, fontWeight: FontWeight.w600)),
      H3Config(style: text.copyWith(fontSize: fontSize + 1, fontWeight: FontWeight.w600)),
      H4Config(style: text.copyWith(fontWeight: FontWeight.w600)),
      H5Config(style: text.copyWith(fontWeight: FontWeight.w600)),
      H6Config(style: text.copyWith(fontWeight: FontWeight.w600)),
      BlockquoteConfig(sideColor: c.divider, textColor: c.text2),
      TableConfig(
        headerStyle: text.copyWith(fontWeight: FontWeight.w600, fontSize: fontSize - 1),
        bodyStyle: text.copyWith(fontSize: fontSize - 1),
        border: TableBorder.all(color: c.divider, width: 0.5),
      ),
      HrConfig(color: c.divider, height: 0.5),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = config(context, fontSize: fontSize, color: color);
    final widgets = MarkdownGenerator(linesMargin: const EdgeInsets.symmetric(vertical: 3)).buildWidgets(data, config: cfg);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: widgets);
  }
}
