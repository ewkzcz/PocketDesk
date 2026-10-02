/**
 * 聊天记录归并测试：流式文本、思考、工具、审批、改动、排队、用量、去重与向前加载。
 */
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/data/chat.dart';
import 'package:pocketdesk/data/models.dart';

PdEvent e(int seq, String type, Map<String, dynamic> data) => PdEvent(session: 's', seq: seq, type: type, data: data, createdAt: seq * 1000);

void main() {
  test('流式文本合并为一个气泡，完成后以最终文本为准', () {
    final log = ChatLog('s');
    log.apply(e(1, 'msg.user', {'text': '你好'}));
    log.apply(e(2, 'msg.delta', {'id': 'a', 'text': '在'}));
    log.apply(e(3, 'msg.delta', {'id': 'a', 'text': '的'}));
    expect((log.items[1] as AgentItem).text, '在的');
    expect((log.items[1] as AgentItem).streaming, isTrue);
    log.apply(e(4, 'msg.done', {'id': 'a', 'text': '在的。'}));
    expect(log.items.length, 2);
    expect((log.items[1] as AgentItem).text, '在的。');
    expect((log.items[1] as AgentItem).streaming, isFalse);
    expect(log.lastSeq, 4);
    expect(log.firstSeq, 1);
  });

  test('Agent 重启后回复编号重复：新一轮的回复显示为新气泡，不并进以前的气泡', () {
    final log = ChatLog('s');
    log.apply(e(1, 'msg.user', {'text': '第一问'}));
    log.apply(e(2, 'msg.delta', {'id': 'acp-0', 'text': '第一答'}));
    log.apply(e(3, 'msg.done', {'id': 'acp-0', 'text': '第一答'}));
    log.apply(e(4, 'msg.user', {'text': '第二问'}));
    log.apply(e(5, 'msg.delta', {'id': 'acp-0', 'text': '第二答'}));
    log.apply(e(6, 'msg.user', {'text': '排队的', 'queued': true}));
    log.apply(e(7, 'msg.done', {'id': 'acp-0', 'text': '第二答完整'}));
    final texts = log.items.map((x) => x is AgentItem ? x.text : (x as UserItem).text).toList();
    expect(texts, ['第一问', '第一答', '第二问', '第二答完整', '排队的']);
  });

  test('重复序号被忽略', () {
    final log = ChatLog('s');
    expect(log.apply(e(1, 'msg.user', {'text': 'a'})), isTrue);
    expect(log.apply(e(1, 'msg.user', {'text': 'a'})), isFalse);
    expect(log.items.length, 1);
  });

  test('思考、工具与审批卡片的状态更新', () {
    final log = ChatLog('s');
    log.apply(e(1, 'thinking', {'id': 't', 'text': '想', 'delta': true}));
    log.apply(e(2, 'thinking', {'id': 't', 'text': '一想', 'delta': true}));
    log.apply(e(3, 'thinking', {'id': 't', 'done': true}));
    log.apply(e(4, 'thinking', {'id': 'empty', 'done': true}));
    log.apply(e(5, 'tool.start', {'id': 'x', 'name': 'Bash', 'kind': 'exec', 'input': {'command': 'ls'}}));
    log.apply(e(6, 'tool.end', {'id': 'x', 'output': 'a.txt', 'isError': false}));
    log.apply(e(7, 'approval.request', {'id': 'p', 'tool': 'Write', 'kind': 'write', 'summary': '写入 a.txt', 'expiresAt': 99}));
    expect(log.pendingApprovals, 1);
    log.apply(e(8, 'approval.done', {'id': 'p', 'status': 'allowed', 'always': true}));
    final think = log.items[0] as ThinkingItem;
    expect(think.text, '想一想');
    expect(think.done, isTrue);
    expect(log.items.whereType<ThinkingItem>().length, 1);
    final tool = log.items[1] as ToolItem;
    expect(tool.summary, 'Bash');
    expect(tool.output, 'a.txt');
    expect(tool.done, isTrue);
    final ap = log.items[2] as ApprovalItem;
    expect(ap.status, ApprovalStatus.allowed);
    expect(ap.always, isTrue);
    expect(log.pendingApprovals, 0);
  });

  test('排队消息在开始处理后取消排队标记', () {
    final log = ChatLog('s');
    log.apply(e(1, 'msg.user', {'text': '一', 'queued': true}));
    log.apply(e(2, 'msg.user', {'text': '二', 'queued': true}));
    log.apply(e(3, 'system', {'text': '开始处理排队消息'}));
    final users = log.items.whereType<UserItem>().toList();
    expect(users[0].queued, isFalse);
    expect(users[1].queued, isTrue);
    expect(log.items.last, isA<SystemItem>());
  });

  test('状态、模型、用量、错误、改动与文件消息', () {
    final log = ChatLog('s');
    log.apply(e(1, 'state', {'state': 'running'}));
    log.apply(e(2, 'session.model', {'model': 'opus'}));
    log.apply(e(3, 'usage', {'inputTokens': 10, 'outputTokens': 5, 'costUsd': 0.5}));
    log.apply(e(4, 'usage', {'inputTokens': 1, 'outputTokens': 1, 'costUsd': 1}));
    log.apply(e(5, 'error', {'message': '崩溃', 'retryable': true}));
    log.apply(e(6, 'diff.summary', {'files': [{'path': 'a.go', 'added': 3, 'removed': 1, 'status': 'M'}], 'git': true}));
    log.apply(e(7, 'file', {'direction': 'down', 'name': 'a.pdf', 'size': 12, 'outboxId': 'o1'}));
    expect(log.state, 'running');
    expect(log.model, 'opus');
    expect(log.usage.inputTokens, 11);
    expect(log.usage.costUsd, 1.5);
    expect(log.usage.turns, 2);
    final err = log.items[0] as SystemItem;
    expect(err.error && err.retryable, isTrue);
    expect((log.items[1] as DiffItem).files.single.path, 'a.go');
    final f = log.items[2] as FileItem;
    expect(f.up, isFalse);
    expect(f.outboxId, 'o1');
  });

  test('向前加载插入到最前并保持流式合并', () {
    final log = ChatLog('s');
    log.apply(e(10, 'msg.delta', {'id': 'b', 'text': '新'}));
    expect(log.hasMoreBefore, isTrue);
    log.prepend([e(8, 'msg.user', {'text': '旧问'}), e(9, 'msg.done', {'id': 'a', 'text': '旧答'}), e(10, 'msg.user', {'text': '重复'})]);
    expect(log.items.length, 3);
    expect((log.items[0] as UserItem).text, '旧问');
    expect(log.firstSeq, 8);
    log.apply(e(11, 'msg.delta', {'id': 'b', 'text': '的'}));
    expect((log.items.last as AgentItem).text, '新的');
    log.prepend([]);
    expect(log.firstSeq, 8);
  });
}
