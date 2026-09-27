/**
 * 交互流程测试：打开 App 的身份验证、左滑操作、新建菜单、文件长按菜单、设置页、手动配对、终端快捷键与输入、文本编辑保存、改动查看。
 */
library;

import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/net/events.dart' show LinkState;
import 'package:pocketdesk/core/discovery.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/ui/pages/diff_page.dart';
import 'package:pocketdesk/ui/pages/pair_page.dart';
import 'package:pocketdesk/ui/pages/terminal_page.dart';
import 'package:pocketdesk/ui/viewers/book/book_reader.dart';
import 'package:pocketdesk/ui/viewers/image_viewer.dart';
import 'package:pocketdesk/ui/viewers/office/office_viewer.dart';
import 'package:pocketdesk/ui/viewers/text_viewer.dart';

import '../core/services_test.dart' show FakeDiscovery;
import '../support/office_fixtures.dart';
import 'harness.dart';

const _ws = Workspace(id: 'w1', name: 'payments', rootPath: '/p', readOnly: false);

void main() {
  setUpAll(loadFonts);

  Future<UiEnv> start(WidgetTester tester, {bool biometric = false, ThemeMode theme = ThemeMode.light, Widget? page, void Function(UiServer s)? setup}) async {
    setSize(tester, const Size(390, 844));
    final env = (await tester.runAsync(() => UiEnv.create(biometric: biometric, theme: theme, setup: setup)))!;
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
    expect(find.text('Claude Code 免审批'), findsOneWidget);
    expect(find.text('Codex 免审批'), findsOneWidget);
    expect(find.text('DSH 免审批'), findsNothing);
    await shot(tester, 'flow-plus');
    // 免审批会话：请求带上标记，聊天页顶部标出
    await tester.tap(find.text('Claude Code 免审批'));
    await settle(tester);
    await tester.tap(find.text('payments').last);
    await settle(tester);
    expect((env.server.bodies['POST /api/sessions'] as Map)['autoApprove'], isTrue);
    expect(find.textContaining('免审批'), findsWidgets);
    await finish(tester, env);
  });

  testWidgets('新建会话可选电脑上任意文件夹作为工作目录', (tester) async {
    final env = await start(tester);
    await tester.tap(find.bySemanticsLabel('新建'));
    await settle(tester);
    await tester.tap(find.text('新建 Codex 会话'));
    await settle(tester);
    // 默认工作目录排第一，最后是选择其他文件夹
    expect(find.textContaining('默认工作目录'), findsOneWidget);
    await tester.tap(find.text('选择其他文件夹…'));
    await settle(tester);
    // 从个人文件夹开始，路径可点回上一级
    expect(find.text('/ me'), findsOneWidget);
    await tester.tap(find.text('在这里打开'));
    await settle(tester);
    final body = env.server.bodies['POST /api/sessions'] as Map;
    expect(body['workspaceId'], 'computer');
    expect(body['cwd'], 'Users/me');
    await finish(tester, env);
  });

  testWidgets('工作空间用文件夹选择器添加，传输设置显示收发目录', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('我').last);
    await settle(tester);
    await tester.tap(find.text('工作空间'));
    await settle(tester);
    expect(find.text('payments（默认）'), findsOneWidget);
    await tester.tap(find.text('添加工作空间').last);
    await settle(tester);
    await tester.tap(find.text('添加这个文件夹'));
    await settle(tester);
    expect((env.server.bodies['POST /api/ws'] as Map)['path'], '/Users/me');
    expect(find.text('me'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('返回').last);
    await settle(tester);
    await tester.tap(find.text('传输设置'));
    await settle(tester);
    await tester.dragUntilVisible(find.text('手机保存位置'), find.byType(ListView).last, const Offset(0, -200));
    expect(find.text('/Users/me/PocketDesk/Inbox'), findsOneWidget);
    expect(find.text('/Users/me/PocketDesk/Outbox'), findsOneWidget);
    await finish(tester, env);
  });

  testWidgets('文件传输助手：显示文件存到了电脑哪里，点开在 App 内预览', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('文件传输助手'));
    await settle(tester);
    expect(find.textContaining('已存到电脑 Inbox/20261001'), findsOneWidget);
    await tester.tap(find.text('截图.png'));
    await settle(tester);
    // 通过「此电脑」打开收件目录中的这张图
    final viewer = tester.widget<ImageViewerPage>(find.byType(ImageViewerPage));
    expect(viewer.ws.id, 'computer');
    expect(viewer.images.single.path, 'Users/me/PocketDesk/Inbox/20261001/截图.png');
    await finish(tester, env);
  });

  testWidgets('txt 用小说阅读器：分页翻页、目录跳章、字号与底色、记住位置', (tester) async {
    final book = [for (var c = 1; c <= 5; c++) '第${'一二三四五'[c - 1]}章 山雨\n${List.generate(60, (i) => '第 $c 章第 $i 段：少年站在山巅，看着远方翻涌的云海。').join('\n')}'].join('\n');
    const ws = Workspace(id: 'w1', name: 'payments', rootPath: '/Users/me/payments', readOnly: false);
    const entry = FileEntry(name: '小说.txt', path: '小说.txt', isDir: false, size: 1000, modTime: 0);
    final env = await start(tester, page: BookReaderPage(ws: ws, entry: entry, load: () async => Uint8List.fromList(gbk.encode(book))));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle(tester);
    // GBK 编码正确解码，第一页显示章节名与页码
    expect(find.text('第一章 山雨'), findsOneWidget);
    expect(find.textContaining('1 / '), findsOneWidget);
    await shot(tester, 'flow-book');
    // 点右侧翻到第 2 页，点左侧回到第 1 页
    final size = tester.getSize(find.byType(BookReaderPage));
    await tester.tapAt(Offset(size.width - 20, size.height / 2));
    await settle(tester);
    expect(find.textContaining('2 / '), findsOneWidget);
    await tester.tapAt(Offset(20, size.height / 2));
    await settle(tester);
    expect(find.textContaining('1 / '), findsOneWidget);
    // 点中间呼出控制栏，打开目录跳到第四章
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('目录'));
    await settle(tester);
    expect(find.text('共 5 章'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('第四章 山雨')));
    await settle(tester);
    expect(find.text('第四章 山雨'), findsOneWidget);
    // 翻几页后放大字号，仍在第四章
    for (var i = 0; i < 3; i++) {
      await tester.tapAt(Offset(size.width - 20, size.height / 2));
      await settle(tester);
    }
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('字号增大'));
    await settle(tester);
    expect(find.text('第四章 山雨'), findsOneWidget);
    expect(env.settings.readerFontSize, 20);
    // 夜间底色
    await tester.tap(find.bySemanticsLabel('夜间'));
    await settle(tester);
    expect(env.settings.readerTheme, 'night');
    await tester.pump(const Duration(seconds: 1));
    final pos = (await tester.runAsync(() => env.app.scope!.sessions.db.bookPos(env.app.scope!.host.id, 'w1', '小说.txt')))!;
    expect(pos.chapter, 3);
    expect(pos.offset, greaterThan(0));
    await finish(tester, env);
  });

  for (final (kind, name, bytes, expectText) in [
    (OfficeKind.word, '周报.docx', docxBytes, '项目周报'),
    (OfficeKind.excel, '账单.xlsx', xlsxBytes, '2025-10-01'),
    (OfficeKind.slides, '汇报.pptx', pptxBytes, '第一页标题'),
  ]) {
    testWidgets('Office 在 App 内查看：$name', (tester) async {
      const ws = Workspace(id: 'w1', name: 'payments', rootPath: '/Users/me/payments', readOnly: false);
      final entry = FileEntry(name: name, path: name, isDir: false, size: 1000, modTime: 0);
      final env = await start(tester, page: OfficeViewerPage(ws: ws, entry: entry, kind: kind, load: () async => bytes()));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await settle(tester);
      expect(find.textContaining(expectText, findRichText: true), findsWidgets);
      await shot(tester, 'flow-office-${kind.name}');
      if (kind == OfficeKind.excel) {
        // 列号、行号与工作表切换
        expect(find.text('A'), findsOneWidget);
        expect(find.text('1'), findsWidgets);
        await tester.tap(find.text('明细'));
        await settle(tester);
        // AB30：从屏幕内的一点向上滑到第 30 行，AB 列在右侧（表格比屏幕宽）
        await tester.dragFrom(const Offset(150, 400), const Offset(0, -700));
        await settle(tester);
        expect(find.text('30'), findsOneWidget);
        expect(find.text('AB', skipOffstage: false), findsOneWidget);
        expect(find.text('TRUE', skipOffstage: false), findsOneWidget);
        await tester.dragFrom(const Offset(300, 400), const Offset(-2000, 0));
        await settle(tester);
        expect(find.text('TRUE'), findsOneWidget);
      }
      await tester.tap(find.bySemanticsLabel('更多').last);
      await settle(tester);
      expect(find.text('用其他应用打开'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester);
      await finish(tester, env);
    });
  }

  testWidgets('搜索过滤会话', (tester) async {
    final env = await start(tester);
    await tester.enterText(find.byType(TextField).first, '周报');
    await settle(tester);
    expect(find.text('DSH · 周报生成'), findsOneWidget);
    expect(find.text('Claude Code · 重构支付模块'), findsNothing);
    await finish(tester, env);
  });

  testWidgets('Markdown 在手机上直接排版：表格、任务列表、公式、图片，记住阅读位置', (tester) async {
    final env = await start(tester);
    await tester.tap(find.text('文件').last);
    await settle(tester);
    await tester.tap(find.text('README.md'));
    await settle(tester);
    expect(find.text('周报'), findsOneWidget);
    expect(find.text('扫码配对'), findsOneWidget);
    expect(find.byType(Math), findsNWidgets(2));
    expect(find.byType(Checkbox).evaluate().isNotEmpty || find.byIcon(Icons.check_box).evaluate().isNotEmpty, isTrue);
    // 在手机上排版，不请求电脑转换；图片按 md 所在目录从工作区读取
    expect(env.server.calls.where((c) => c.contains('/render')), isEmpty);
    final reader = find.byKey(const ValueKey('md-reader'));
    await tester.dragUntilVisible(find.byType(Image), reader, const Offset(0, -200));
    expect(find.byType(Image), findsWidgets);
    await shot(tester, 'flow-md-reader');
    // 菜单
    await tester.tap(find.bySemanticsLabel('更多').last);
    await settle(tester);
    for (final t in ['刷新', '查看或编辑源文件', '分享', '发给会话']) {
      expect(find.text(t), findsOneWidget);
    }
    await tester.tapAt(const Offset(10, 10));
    await settle(tester);
    // 大纲：列出标题，点击跳到对应位置
    ScrollController ctl() => tester.widget<ListView>(reader).controller!;
    ctl().jumpTo(0);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('目录'));
    await settle(tester);
    expect(find.text('2 节'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text('下周计划')));
    await settle(tester);
    expect(ctl().offset, greaterThan(100));
    // 翻页：下一页前进约一屏，上一页回退
    ctl().jumpTo(0);
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('下一页'));
    await settle(tester);
    final paged = ctl().offset;
    expect(paged, greaterThan(200));
    await tester.tap(find.bySemanticsLabel('上一页'));
    await settle(tester);
    expect(ctl().offset, lessThan(paged));
    // 滚动后退出，再次打开回到原位置
    await tester.drag(find.byKey(const ValueKey('md-reader')), const Offset(0, -150));
    await settle(tester);
    final before = tester.widget<ListView>(find.byKey(const ValueKey('md-reader'))).controller!.offset;
    expect(before, greaterThan(0));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.bySemanticsLabel('返回').last);
    await settle(tester);
    await tester.tap(find.text('README.md'));
    await settle(tester);
    expect(tester.widget<ListView>(find.byKey(const ValueKey('md-reader'))).controller!.offset, closeTo(before, 1));
    await finish(tester, env);
  });

  testWidgets('文件页加载失败后，电脑重新在线时自动刷新', (tester) async {
    // App 启动时电脑还没连上，文件页加载失败
    final env = await start(tester, setup: (s) => s.workspacesDown = true);
    final conn = env.app.scope!.conn;
    conn.link = LinkState.offline;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    conn.notifyListeners();
    await tester.tap(find.text('文件').last);
    await settle(tester);
    expect(find.text('README.md'), findsNothing);
    // 电脑恢复在线，不用点重试
    env.server.workspacesDown = false;
    conn.debugOnline('192.168.1.5', env.server.status);
    await settle(tester);
    expect(find.text('README.md'), findsOneWidget);
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
    // 快捷键栏按需构建，先滚到 / 出现，再让它完整露出，避免点到边缘
    await tester.dragUntilVisible(find.text('/'), find.byType(ListView).first, const Offset(-120, 0));
    await tester.ensureVisible(find.text('/'));
    await settle(tester);
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
