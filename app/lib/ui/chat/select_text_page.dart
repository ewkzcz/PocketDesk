/**
 * 选择文字：整条消息放大显示，可以自由选择任意一段复制，也可以一键复制全部。
 */
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../tokens.dart';
import '../widgets.dart';
import 'markdown.dart';

/** SelectTextPage：选择文字 */
class SelectTextPage extends StatelessWidget {
  const SelectTextPage({super.key, required this.text, this.markdown = true});

  final String text;

  /** markdown：按 Markdown 排版；工具输出等按原样等宽显示 */
  final bool markdown;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Scaffold(
      appBar: PdBar(title: '选择文字', actions: [
        PdIconButton(
          icon: LucideIcons.copy300,
          tooltip: '复制全部',
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) toast(context, '已复制全部');
          },
        ),
      ]),
      body: SelectionArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(PdSize.gutter, 16, PdSize.gutter, 32), children: [
          if (markdown)
            MdText(text, fontSize: 16)
          else
            Text(text, style: TextStyle(fontSize: 13, height: 1.5, color: c.text, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback)),
        ]),
      ),
    );
  }
}
