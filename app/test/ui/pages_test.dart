/**
 * 页面测试：浅色与深色、常规与小屏大字号下逐页渲染（任何溢出、重叠报错都会使测试失败），并验证主要交互。
 */
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/transfer/task.dart';

import 'harness.dart';

/** 测试的屏幕组合：名称、尺寸、字体缩放 */
const _screens = [
  ('phone', Size(390, 844), 1.0),
  ('small', Size(320, 568), 1.3),
];

void main() {
  setUpAll(loadFonts);

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final (screen, size, scale) in _screens) {
      final tag = '${theme.name}-$screen';

      testWidgets('四个 Tab 与聊天页渲染正常（$tag）', (tester) async {
        setSize(tester, size, textScale: scale);
        final env = (await tester.runAsync(() => UiEnv.create(theme: theme)))!;
        await tester.pumpWidget(env.widget());
        await settle(tester);

        // 消息页
        expect(find.text('PocketDesk'), findsOneWidget);
        expect(find.text('Claude Code · 重构支付模块'), findsOneWidget);
        expect(find.text('文件传输助手'), findsOneWidget);
        expect(find.text('待确认'), findsWidgets);
        await shot(tester, '$tag-01-sessions');

        // 文件页
        await tester.tap(find.text('文件').last);
        await settle(tester);
        expect(find.text('README.md'), findsOneWidget);
        expect(find.text('20261001'), findsOneWidget);
        await shot(tester, '$tag-02-files');
        await tester.tap(find.text('20261001'));
        await settle(tester);
        expect(find.text('a.md'), findsOneWidget);
        await shot(tester, '$tag-03-files-sub');

        // 传输页：放入几种状态的任务
        final m = env.app.scope!.transfers;
        TransferTask task(String name, Direction d, String st, int size, int done, {String err = ''}) => TransferTask(
              id: name, hostId: 'h1', direction: d, source: '/x/$name', name: name, size: size, createdAt: 1, dateFolder: '20261001', status: st, doneBytes: done, error: err)
          ..speed = st == TaskStatus.running ? 12.4 * 1024 * 1024 : 0
          ..lanes = st == TaskStatus.running ? 4 : 0;
        m.tasks.addAll([
          task('视频教程-第一章-环境搭建与项目初始化完整版.mp4', Direction.up, TaskStatus.running, 1288490188, 824633720),
          task('设计稿.zip', Direction.down, TaskStatus.running, 356515840, 106954752),
          task('报销单.pdf', Direction.up, TaskStatus.queued, 2202009, 0),
          task('合同.docx', Direction.up, TaskStatus.failed, 102400, 0, err: '文件已被修改，请重试'),
          task('周报草稿.docx', Direction.up, TaskStatus.done, 4823449, 4823449)..finishedAt = ago(const Duration(hours: 1)),
        ]);
        m.clearNotice();
        await tester.tap(find.text('传输').last);
        await settle(tester);
        expect(find.textContaining('视频教程'), findsOneWidget);
        await shot(tester, '$tag-04-transfer');
        await tester.tap(find.text('已完成'));
        await settle(tester);
        expect(find.text('周报草稿.docx'), findsOneWidget);
        await tester.tap(find.text('收件箱'));
        await settle(tester);
        expect(find.text('白板照片.jpg'), findsOneWidget);
        await shot(tester, '$tag-05-inbox');

        // 我
        await tester.tap(find.text('我').last);
        await settle(tester);
        expect(find.textContaining('在线 · 局域网'), findsOneWidget);
        await shot(tester, '$tag-06-me');

        // 聊天页
        await tester.tap(find.text('消息').last);
        await settle(tester);
        await tester.tap(find.text('Claude Code · 重构支付模块'));
        await settle(tester, 20);
        expect(find.text('需要执行命令'), findsOneWidget);
        expect(find.text('本轮改动 · 3 个文件'), findsOneWidget);
        expect(find.text('排队中'), findsOneWidget);
        expect(find.text('网络请求超时'), findsOneWidget);
        await shot(tester, '$tag-07-chat');

        // 扩展面板与指令列表
        await tester.tap(find.bySemanticsLabel('更多').last);
        await settle(tester);
        expect(find.text('工作区文件'), findsOneWidget);
        await shot(tester, '$tag-08-chat-panel');
        await tester.enterText(find.byType(TextField).last, '/');
        await settle(tester);
        expect(find.text('/model'), findsOneWidget);
        await shot(tester, '$tag-09-chat-slash');
        await tester.enterText(find.byType(TextField).last, '');
        await settle(tester);

        // 审批：点允许后发送到电脑
        await tester.tap(find.text('允许'));
        await settle(tester);
        expect(env.server.calls, contains('POST /api/approvals/ap1'));

        // 文件传输助手
        await tester.tap(find.bySemanticsLabel('返回').last);
        await settle(tester);
        await tester.tap(find.text('文件传输助手'));
        await settle(tester, 20);
        expect(find.text('周报.pdf'), findsOneWidget);
        await shot(tester, '$tag-10-assistant');

        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(env.dispose);
      });
    }
  }
}
