/**
 * 界面风格测试：八套风格各有浅色与深色，主题都能生成，文字与背景对比足够。
 */
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/ui/styles.dart';
import 'package:pocketdesk/ui/theme.dart';
import 'package:pocketdesk/ui/tokens.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('八套风格，标识不重复，找不到时回到微信', () {
    expect(PdThemes.all.length, 8);
    expect(PdThemes.all.map((t) => t.id).toSet().length, 8);
    expect(PdThemes.byId('不存在').id, 'wechat');
    expect(PdThemes.byId('glacier').name, '冰川玻璃');
  });

  test('每套风格的浅色与深色都能生成主题，正文与背景对比不低于 4.5', () {
    final bad = <String>[];
    void check(String what, Color fg, Color bg, double min) {
      final r = _contrast(fg, bg);
      if (r < min) bad.add('$what ${r.toStringAsFixed(2)} < $min');
    }

    for (final spec in PdThemes.all) {
      for (final b in Brightness.values) {
        final theme = buildTheme(b, spec);
        final c = theme.extension<PdColors>()!;
        final st = theme.extension<PdStyle>()!;
        expect(st.id, spec.id);
        final tag = '${spec.id} ${b.name}';
        check('$tag 正文/页面', c.text, c.page, 4.5);
        check('$tag 正文/卡片', c.text, c.card, 4.5);
        check('$tag 次要文字/卡片', c.text2, c.card, 4.5);
        check('$tag 说明文字/卡片', c.text3, c.card, 3);
        check('$tag 我方气泡', c.bubbleMineText, c.bubbleMine, 3);
        check('$tag 顶栏', c.onBar, c.topBar, 3);
        check('$tag 强调色/卡片', c.accent, c.card, 2.3);
      }
    }
    expect(bad, isEmpty);
  });

  test('有背景装饰的风格页面底色透明，其余用页面色', () {
    for (final spec in PdThemes.all) {
      final theme = buildTheme(Brightness.light, spec);
      final st = theme.extension<PdStyle>()!;
      if (st.backdrop == PdBackdropKind.none) {
        expect(theme.scaffoldBackgroundColor, theme.extension<PdColors>()!.page);
      } else {
        expect(theme.scaffoldBackgroundColor, Colors.transparent);
      }
    }
  });

  test('头像形状：圆形风格取边长的一半', () {
    final qq = PdThemes.qq.light.style;
    expect(qq.isCircle, isTrue);
    expect(qq.avatarRadiusFor(40), 20);
    expect(PdThemes.wechat.light.style.isCircle, isFalse);
  });
}
