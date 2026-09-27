/**
 * 会话名：电脑端生成的标题已带 Agent 名时不重复。
 */
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/data/models.dart';
import 'package:pocketdesk/ui/pages/session_actions.dart';

SessionInfo _s(String kind, String title) => SessionInfo(
    id: 's', kind: kind, title: title, workspaceId: 'w', cwd: '.', model: '', state: 'idle', pinned: false, lastSeq: 0, preview: '', updatedAt: 0);

void main() {
  test('标题带不带 Agent 名都只显示一次', () {
    expect(sessionTitle(_s('claude', 'Claude Code')), 'Claude Code · 新会话');
    expect(sessionTitle(_s('claude', '')), 'Claude Code · 新会话');
    expect(sessionTitle(_s('claude', 'Claude Code · 重构支付模块')), 'Claude Code · 重构支付模块');
    expect(sessionTitle(_s('dsh', 'DSH · 只回复 ok')), 'DSH · 只回复 ok');
    expect(sessionTitle(_s('codex', '修复登录页')), 'Codex · 修复登录页');
    expect(sessionTitle(_s('terminal', '')), '终端');
  });
}
