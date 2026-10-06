/**
 * 新功能测试：底部标签与发现页、通讯录与预设助手、剪切板、收藏夹、提示词、看图缩放、八套风格逐页渲染与头像设置。
 */
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pocketdesk/ui/pages/chat_page.dart';
import 'package:pocketdesk/ui/styles.dart';
import 'package:pocketdesk/ui/viewers/image_viewer.dart';

import 'harness.dart';

void main() {
  setUpAll(loadFonts);

  Future<UiEnv> start(WidgetTester tester, {ThemeMode theme = ThemeMode.light, String style = 'wechat', Widget? page}) async {
    setSize(tester, const Size(390, 844));
    final env = (await tester.runAsync(() => UiEnv.create(theme: theme, style: style)))!;
    await tester.pumpWidget(page == null ? env.widget() : pageHost(env, page));
    await settle(tester);
    return env;
  }

  Future<void> finish(WidgetTester tester, UiEnv env) async {
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  }

  testWidgets('底部四个标签：消息、通讯录、发现、我；文件与传输收在发现里', (tester) async {
    final env = await start(tester);
    for (final t in ['消息', '通讯录', '发现', '我']) {
      expect(find.text(t), findsWidgets);
    }
    await tester.tap(find.text('发现').last);
    await settle(tester);
    for (final t in ['文件', '传输', '剪切板', '收藏夹', '提示词']) {
      expect(find.text(t), findsOneWidget);
    }
    await finish(tester, env);
  });

  testWidgets('通讯录：AI 好友与预设助手；选 Agent 填参数后以模板新建会话', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('通讯录').last);
    await settle(tester);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('OCR 识别'), findsOneWidget);
    await shot(tester, 'feat-contacts');
    await tester.tap(find.text('翻译'));
    await settle(tester);
    expect(find.text('目标语言'), findsOneWidget);
    await shot(tester, 'feat-preset');
    // 换成 Codex，目标语言改成日文
    await tester.tap(find.text('Codex'));
    await settle(tester);
    await tester.tap(find.text('目标语言'));
    await settle(tester);
    await tester.tap(find.text('日文'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('开始对话'), 300, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('开始对话'));
    await settle(tester);
    await tester.tap(find.text('开始对话'));
    await settle(tester);
    final body = env.server.bodies['POST /api/sessions'] as Map;
    expect(body['kind'], 'codex');
    expect(body['title'], '翻译 · Codex');
    expect(body['instruction'], contains('日文'));
    expect(body['instruction'], isNot(contains('{{')));
    final preset = jsonDecode(body['preset'] as String) as Map;
    expect(preset['id'], 'translate');
    expect((preset['params'] as Map)['target'], '日文');
    // 进入聊天后，输入栏上方显示参数，点开可以改参数、换 Agent
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('目标语言：日文'), findsOneWidget);
    await shot(tester, 'feat-preset-chat');
    await tester.tap(find.text('目标语言：日文'));
    await settle(tester);
    expect(find.text('应用参数'), findsOneWidget);
    expect(find.text('换 Agent 处理'), findsOneWidget);
    await tester.tap(find.text('目标语言'));
    await settle(tester);
    await tester.tap(find.text('韩文'));
    await settle(tester);
    await tester.tap(find.text('应用参数'));
    await settle(tester);
    final patch = env.server.bodies['PATCH /api/sessions/new1'] as Map;
    expect(patch['instruction'], contains('韩文'));
    await finish(tester, env);
  });

  testWidgets('预设助手：修改内置提示词后显示已修改，可以恢复默认', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('通讯录').last);
    await settle(tester);
    await tester.tap(find.text('OCR 识别'));
    await settle(tester);
    await tester.scrollUntilVisible(find.text('修改系统提示词'), 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('修改系统提示词'));
    await settle(tester);
    expect(find.text('修改「OCR 识别」'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(2), '只识别文字，识别语言：{{lang}}。');
    await tester.tap(find.bySemanticsLabel('保存'));
    await settle(tester);
    final saved = env.server.library.single;
    expect(saved['kind'], 'preset');
    final body = jsonDecode(saved['body'] as String) as Map;
    expect(body['id'], 'ocr');
    expect(body['override'], isTrue);
    expect((body['params'] as List).map((p) => (p as Map)['key']), containsAll(['lang', 'format']));
    expect(find.text('已修改'), findsWidgets);
    // 恢复默认需要二次确认
    await tester.tap(find.bySemanticsLabel('更多'));
    await settle(tester);
    await tester.tap(find.text('恢复默认'));
    await settle(tester);
    expect(env.server.library, isNotEmpty);
    await tester.tap(find.text('恢复默认').last);
    await settle(tester);
    expect(env.server.library, isEmpty);
    expect(find.text('已修改'), findsNothing);
    await finish(tester, env);
  });

  testWidgets('删除前都要确认：剪切板、收藏夹、提示词', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('发现').last);
    await settle(tester);
    await tester.tap(find.text('剪切板'));
    await settle(tester);
    await tester.tap(find.text('写一条'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '要删的内容');
    await tester.tap(find.text('放进去'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('更多').last);
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    expect(find.text('删除这条内容'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(env.server.library.where((x) => x['kind'] == 'clip'), hasLength(1));
    await tester.tap(find.bySemanticsLabel('更多').last);
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    await tester.tap(find.text('删除').last);
    await settle(tester);
    expect(env.server.library.where((x) => x['kind'] == 'clip'), isEmpty);
    await finish(tester, env);
  });

  testWidgets('剪切板：写一条文字放进去，显示在列表里并可置顶、删除', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('发现').last);
    await settle(tester);
    await tester.tap(find.text('剪切板'));
    await settle(tester);
    await shot(tester, 'feat-clip-empty');
    await tester.tap(find.text('写一条'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '会议室 302，下午三点');
    await tester.tap(find.text('放进去'));
    await settle(tester);
    expect(env.server.library.single['kind'], 'clip');
    expect(find.text('会议室 302，下午三点'), findsOneWidget);
    await shot(tester, 'feat-clip');
    // 收藏这一条
    await tester.tap(find.text('收藏').last);
    await settle(tester);
    expect(env.server.library.where((x) => x['kind'] == 'fav').single['body'], '会议室 302，下午三点');
    await finish(tester, env);
  });

  testWidgets('聊天里长按消息收藏，在发现的收藏夹里看到', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('Claude Code · 重构支付模块'));
    await settle(tester);
    await tester.longPress(find.text('顺便把测试也补上'));
    await settle(tester);
    await tester.tap(find.text('收藏'));
    await settle(tester);
    expect(env.server.library.single, containsPair('kind', 'fav'));
    expect(env.server.library.single['body'], '顺便把测试也补上');
    await backToHome(tester);
    await tester.tap(find.text('发现').last);
    await settle(tester);
    await tester.tap(find.text('收藏夹'));
    await settle(tester);
    expect(find.text('顺便把测试也补上'), findsWidgets);
    await finish(tester, env);
  });

  testWidgets('提示词：新建一条，聊天时从面板里选用', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('发现').last);
    await settle(tester);
    await tester.tap(find.text('提示词'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('新建'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).at(0), '代码解释');
    await tester.enterText(find.byType(TextField).at(2), '请逐行解释下面的代码，并指出潜在问题。');
    await tester.tap(find.bySemanticsLabel('保存'));
    await settle(tester);
    expect(env.server.library.single['title'], '代码解释');
    expect(find.text('代码解释'), findsOneWidget);
    await backToHome(tester);
    await tester.tap(find.text('消息').last);
    await settle(tester);
    await tester.tap(find.text('Claude Code · 重构支付模块'));
    await settle(tester);
    // 等「已保存」的轻提示消失，避免挡住输入栏
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('更多'));
    await settle(tester);
    await tester.tap(find.text('提示词'));
    await settle(tester);
    await tester.tap(find.text('代码解释'));
    await settle(tester);
    expect(find.textContaining('请逐行解释下面的代码'), findsWidgets);
    await finish(tester, env);
  });

  testWidgets('看图：关闭在右上角，按钮与双击都能缩放', (tester) async {
    final env = await start(
      tester,
      page: ImageGalleryPage(
        count: 1,
        index: 0,
        titleOf: (_) => '截图.png',
        loader: (_) async => MemoryImage(UiServer.pngBytes),
        actionsOf: (_) => [GalleryAction(LucideIcons.share2300, '分享', () {})],
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    final close = tester.getCenter(find.bySemanticsLabel('关闭'));
    expect(close.dx, greaterThan(390 * 0.85));
    expect(close.dy, lessThan(100));
    expect(tester.getCenter(find.bySemanticsLabel('分享')).dx, lessThan(close.dx));
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('放大'));
    await settle(tester);
    expect(find.text('160%'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('放大'));
    await settle(tester);
    expect(find.text('256%'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('缩小'));
    await settle(tester);
    expect(find.text('160%'), findsOneWidget);
    await tester.tap(find.text('160%'));
    await settle(tester);
    expect(find.text('100%'), findsOneWidget);
    // 可以缩到比屏幕小，最小 10%
    await tester.tap(find.bySemanticsLabel('缩小'));
    await settle(tester);
    expect(find.text('63%'), findsOneWidget);
    for (var i = 0; i < 6; i++) {
      await tester.tap(find.bySemanticsLabel('缩小'), warnIfMissed: false);
      await settle(tester);
    }
    expect(find.text('10%'), findsOneWidget);
    await tester.tap(find.text('10%'));
    await settle(tester);
    expect(find.text('100%'), findsOneWidget);
    // 双击放大到 250%，再双击还原
    final c = tester.getCenter(find.byType(ImageGalleryPage));
    await tester.tapAt(c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(c);
    await settle(tester);
    expect(find.text('250%'), findsOneWidget);
    await shot(tester, 'feat-image-zoom');
    await tester.tap(find.bySemanticsLabel('关闭'));
    await settle(tester);
    await finish(tester, env);
  });

  testWidgets('外观：切换风格、设置头像', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('我').last);
    await settle(tester);
    await tester.tap(find.text('外观'));
    await settle(tester);
    expect(find.text('冰川玻璃'), findsOneWidget);
    await shot(tester, 'feat-appearance');
    await tester.tap(find.text('冰川玻璃'));
    await settle(tester);
    expect(env.settings.styleId, 'glacier');
    await tester.scrollUntilVisible(find.text('我的头像'), 300);
    await tester.ensureVisible(find.text('我的头像'));
    await settle(tester);
    await tester.tap(find.text('我的头像'));
    await settle(tester);
    await tester.tap(find.text('Gemini'));
    await settle(tester);
    expect(env.settings.avatarSpec('me'), 'preset:gemini');
    await finish(tester, env);
  });

  // 每套风格、浅色与深色：消息页、聊天页、通讯录、发现、我、预设助手逐页渲染（溢出与重叠会报错）
  for (final spec in PdThemes.all) {
    for (final dark in [false, true]) {
      testWidgets('风格 ${spec.id} ${dark ? '深色' : '浅色'}：逐页渲染', (tester) async {
        final tag = '${spec.id}-${dark ? 'dark' : 'light'}';
        final env = await start(tester, style: spec.id, theme: dark ? ThemeMode.dark : ThemeMode.light);
        await shot(tester, 'style-$tag-1-sessions');
        await tester.tap(find.text('通讯录').last);
        await settle(tester);
        await shot(tester, 'style-$tag-2-contacts');
        await tester.tap(find.text('发现').last);
        await settle(tester);
        await shot(tester, 'style-$tag-3-discover');
        await tester.tap(find.text('我').last);
        await settle(tester);
        await shot(tester, 'style-$tag-4-me');
        await tester.tap(find.text('消息').last);
        await settle(tester);
        await tester.tap(find.text('Claude Code · 重构支付模块'));
        await settle(tester);
        await shot(tester, 'style-$tag-5-chat');
        await finish(tester, env);
      });
    }
  }
}

