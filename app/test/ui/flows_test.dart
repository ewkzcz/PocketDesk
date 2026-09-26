/**
 * 交互流程测试：打开 App 的身份验证、左滑操作、新建菜单、文件长按菜单、设置页、手动配对、终端快捷键与输入、文本编辑保存、改动查看。
 */
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/discovery.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/ui/pages/diff_page.dart';
import 'package:pocketdesk/ui/pages/pair_page.dart';
import 'package:pocketdesk/ui/pages/terminal_page.dart';
import 'package:pocketdesk/ui/viewers/text_viewer.dart';

import '../core/services_test.dart' show FakeDiscovery;
import 'harness.dart';

const _ws = Workspace(id: 'w1', name: 'payments', rootPath: '/p', readOnly: false);

void main() {
  setUpAll(loadFonts);

  Future<UiEnv> start(WidgetTester tester, {bool biometric = false, ThemeMode theme = ThemeMode.light, Widget? page}) async {
    setSize(tester, const Size(390, 844));
    final env = (await tester.runAsync(() => UiEnv.create(biometric: biometric, theme: theme)))!;
    await tester.pumpWidget(page == null ? env.widget() : pageHost(env, page));
    await settle(tester);
    return env;
  }

  Future<void> finish(WidgetTester tester, UiEnv env) async {
    // 先让界面触发的本地写入完成
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(env.dispose);
  }

  testWidgets('开启身份验证时先验证再显示内容', (tester) async {
    final env = await start(tester, biometric: true);
    expect(env.auth.calls, 1);
    expect(find.text('Claude Code · 重构支付模块'), findsOneWidget);
    await finish(tester, env);
  });

  testWidgets('验证失败停留在锁定页，点击重新验证', (tester) async {
    setSize(tester, const Size(390, 844));
    final env = (await tester.runAsync(() => UiEnv.create(biometric: true)))!;
    env.auth.pass = false;
    await tester.pumpWidget(env.widget());
    await settle(tester);
    expect(find.text('点击验证身份'), findsOneWidget);
    await shot(tester, 'flow-lock');
    env.auth.pass = true;
    await tester.tap(find.text('点击验证身份'));
    await settle(tester);
    expect(find.text('文件传输助手'), findsOneWidget);
    await finish(tester, env);
  });

  testWidgets('左滑露出置顶、标为已读、删除', (tester) async {
    final env = await start(tester);
    await tester.drag(find.text('Codex · 修复登录页 bug'), const Offset(-300, 0));
    await settle(tester);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('标为未读'), findsOneWidget);
    await shot(tester, 'flow-swipe');
    await tester.tap(find.text('置顶'));
    await settle(tester);
    expect(env.server.calls, contains('PATCH /api/sessions/cx'));
    expect(env.app.scope!.sessions.byId('cx')!.pinned, isTrue);
    // 删除只隐藏手机上的记录
    await tester.drag(find.text('Pi · 数据清洗脚本'), const Offset(-300, 0));
    await settle(tester);
    await tester.tap(find.text('删除'));
    await settle(tester);
    await tester.tap(find.text('删除').last);
    await settle(tester);
    expect(find.text('Pi · 数据清洗脚本'), findsNothing);
    await finish(tester, env);
  });

  testWidgets('右上角菜单列出已安装的 Agent、终端与扫一扫', (tester) async {
    final env = await start(tester);
    await tester.tap(find.bySemanticsLabel('新建'));
    await settle(tester);
    expect(find.text('新建 Claude Code 会话'), findsOneWidget);
    expect(find.text('新建 DSH 会话'), findsOneWidget);
    expect(find.text('新建终端'), findsOneWidget);
    expect(find.text('扫一扫'), findsOneWidget);
    await shot(tester, 'flow-plus');
    await finish(tester, env);
  });

  testWidgets('搜索过滤会话', (tester) async {
    final env = await start(tester);
    await tester.enterText(find.byType(TextField).first, '周报');
    await settle(tester);
    expect(find.text('DSH · 周报生成'), findsOneWidget);
    expect(find.text('Claude Code · 重构支付模块'), findsNothing);
    await finish(tester, env);
  });

  testWidgets('文件长按菜单与排序', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('文件').last);
    await settle(tester);
    await tester.longPress(find.text('README.md'));
    await settle(tester);
    for (final t in ['下载到手机', '重命名', '移动', '复制路径', '发给会话', '删除']) {
      expect(find.text(t), findsOneWidget);
    }
    await shot(tester, 'flow-file-menu');
    await tester.tap(find.text('下载到手机'));
    await settle(tester);
    expect(env.app.scope!.transfers.tasks.single.source, 'ws:w1:README.md');
    await tester.tap(find.text('默认'));
    await settle(tester);
    await tester.tap(find.text('大小'));
    await settle(tester);
    expect(env.server.calls.where((c) => c.endsWith('/list')).length, greaterThanOrEqualTo(2));
    // 只读工作区不显示修改操作
    await tester.tap(find.text('notes'));
    await settle(tester);
    await tester.longPress(find.text('README.md'));
    await settle(tester);
    expect(find.text('重命名'), findsNothing);
    expect(find.text('复制路径'), findsOneWidget);
    await finish(tester, env);
  });

  testWidgets('设置页：传输、安全、已配对电脑、关于', (tester) async {
    final env = await start(tester, theme: ThemeMode.dark);
    await tester.tap(find.text('我').last);
    await settle(tester);
    await tester.tap(find.text('传输设置'));
    await settle(tester);
    await shot(tester, 'flow-transfer-settings');
    await tester.tap(find.byType(Switch).first);
    await settle(tester);
    expect(env.settings.wifiOnly, isTrue);
    await tester.tap(find.bySemanticsLabel('增加'));
    await settle(tester);
    expect(env.settings.concurrency, 4);
    await tester.tap(find.bySemanticsLabel('返回').last);
    await settle(tester);
    await tester.tap(find.text('安全设置'));
    await settle(tester);
    await shot(tester, 'flow-security');
    await tester.tap(find.bySemanticsLabel('返回').last);
    await settle(tester);
    await tester.tap(find.text('MacBook Pro'));
    await settle(tester);
    expect(find.text('解除配对'), findsOneWidget);
    expect(find.text('192.168.1.5'), findsOneWidget);
    await shot(tester, 'flow-computers');
    await tester.tap(find.text('添加连接地址'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '100.100.7.8');
    await tester.tap(find.text('确定'));
    await settle(tester);
    expect(find.text('100.100.7.8'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回').last);
    await settle(tester);
    await tester.tap(find.text('外观'));
    await settle(tester);
    await tester.tap(find.text('浅色'));
    await settle(tester);
    expect(env.settings.themeMode, ThemeMode.light);
    await finish(tester, env);
  });

  testWidgets('手动配对：发现电脑并输入配对码后可提交', (tester) async {
    final disc = FakeDiscovery();
    final env = await start(tester, page: ManualPairPage(discovery: disc));
    expect(find.widgetWithText(FilledButton, '配对'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '配对')).onPressed, isNull);
    disc.ctrl.add(const Found(name: '书房电脑', ip: '192.168.1.8', port: 8443, fpPrefix: 'abababababababab'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'k7m2-9qxa');
    await settle(tester);
    expect(find.text('书房电脑'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '配对')).onPressed, isNotNull);
    await shot(tester, 'flow-manual-pair');
    await finish(tester, env);
  });

  testWidgets('终端：输出显示、快捷键、粘滞 Ctrl、命令行', (tester) async {
    final sock = FakeTermSocket();
    final env = await start(tester, page: TerminalPage(sessionId: 't1', socketFactory: (_, _) => sock));
    await settle(tester);
    await shot(tester, 'flow-terminal');
    await tester.tap(find.text('Esc'));
    await tester.tap(find.text('Tab'));
    await tester.tap(find.text('↑'));
    // Ctrl 为粘滞键，对下一个按键生效
    await tester.tap(find.text('Ctrl'));
    await tester.dragUntilVisible(find.text('/'), find.byType(ListView).first, const Offset(-120, 0));
    await tester.tap(find.text('/'));
    await tester.tap(find.text('|'));
    await settle(tester);
    expect(sock.input, ['\x1b', '\t', '\x1b[A', '\x1f', '|']);
    await tester.enterText(find.byType(TextField).last, 'git status');
    await tester.tap(find.bySemanticsLabel('执行'));
    await settle(tester);
    expect(sock.input.last, 'git status\r');
    expect(sock.control.any((m) => m['type'] == 'resize'), isTrue);
    await finish(tester, env);
  });

  test('Ctrl 组合键的控制码', () {
    expect(ctrlChar('c'), '\x03');
    expect(ctrlChar('['), '\x1b');
    expect(ctrlChar(' '), '\x00');
    expect(ctrlChar('/'), '\x1f');
    expect(ctrlChar('?'), '\x7f');
    expect(ctrlChar('1'), '1');
  });

  testWidgets('发送失败后重发沿用同一消息编号', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('DSH · 周报生成'));
    await settle(tester, 20);
    env.server.failSends = 1;
    await tester.enterText(find.byType(TextField).last, '整理一下');
    await settle(tester);
    await tester.tap(find.text('发送'));
    await settle(tester);
    // 失败后文字回到输入框；等提示消失后重发
    expect(find.text('整理一下'), findsOneWidget);
    await settle(tester, 70);
    await tester.tap(find.text('发送'));
    await settle(tester);
    expect(env.server.sent.length, 2);
    expect(env.server.sent[0]['clientId'], isNotEmpty);
    expect(env.server.sent[1]['clientId'], env.server.sent[0]['clientId']);
    // 发送成功后，新消息使用新编号
    await tester.enterText(find.byType(TextField).last, '再来一条');
    await settle(tester);
    await tester.tap(find.text('发送'));
    await settle(tester);
    expect(env.server.sent[2]['clientId'], isNot(env.server.sent[0]['clientId']));
    await finish(tester, env);
  });

  testWidgets('文本查看与编辑保存', (tester) async {
    final env = await start(tester, page: const TextViewerPage(ws: _ws, path: 'main.go'));
    await settle(tester);
    expect(find.textContaining('package main', findRichText: true), findsOneWidget);
    await shot(tester, 'flow-text');
    await tester.tap(find.bySemanticsLabel('编辑'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'package main\n');
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('保存'));
    await settle(tester);
    expect(env.server.calls, contains('PUT /api/ws/w1/file'));
    expect(find.text('已保存'), findsOneWidget);
    await finish(tester, env);
  });

  testWidgets('改动清单与单个文件差异', (tester) async {
    final env = await start(tester, page: const DiffPage(sessionId: 'cc', ws: _ws));
    await settle(tester);
    expect(find.text('shared/validators.js'), findsOneWidget);
    await tester.tap(find.text('payments/checkout.js'));
    await settle(tester);
    expect(find.text('+const a = 2;'), findsOneWidget);
    await shot(tester, 'flow-diff');
    await finish(tester, env);
  });
}
