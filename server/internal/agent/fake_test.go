/**
 * 假 Agent 进程：测试二进制在设置 GO_FAKE_AGENT 时扮演对应命令行工具，用于驱动的端到端 mock 测试。
 */
package agent

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

/** TestMain：按环境变量切换为假进程 */
func TestMain(m *testing.M) {
	switch os.Getenv("GO_FAKE_AGENT") {
	case "claude":
		fakeClaude()
	case "codex":
		fakeCodex()
	case "pi":
		fakePi()
	case "acp":
		fakeACP()
	case "crash":
		fmt.Fprintln(os.Stderr, "fatal: boom")
		os.Exit(3)
	default:
		os.Exit(m.Run())
	}
	os.Exit(0)
}

/** out：输出一行 JSON */
func out(v any) {
	b, _ := json.Marshal(v)
	os.Stdout.Write(append(b, '\n'))
}

/** fakeClaude：模拟 stream-json 模式 */
func fakeClaude() {
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	interrupted := make(chan struct{}, 1)
	lines := make(chan string)
	go func() {
		for sc.Scan() {
			lines <- sc.Text()
		}
		close(lines)
	}()
	sid := "sess-new"
	for i, a := range os.Args {
		if a == "--resume" {
			sid = os.Args[i+1]
		}
	}
	out(map[string]any{"type": "system", "subtype": "init", "session_id": sid, "model": "fake-model"})
	for line := range lines {
		var m map[string]any
		json.Unmarshal([]byte(line), &m)
		if m["type"] == "control_request" {
			interrupted <- struct{}{}
			continue
		}
		text := m["message"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
		if strings.Contains(text, "slow") {
			go func() {
				select {
				case <-interrupted:
					out(map[string]any{"type": "result", "subtype": "error_during_execution", "is_error": true, "result": "已中断", "session_id": sid})
				case <-time.After(5 * time.Second):
				}
			}()
			continue
		}
		out(map[string]any{"type": "stream_event", "event": map[string]any{"type": "message_start", "message": map[string]any{"id": "m1"}}})
		out(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "你"}}})
		out(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": "好"}}})
		out(map[string]any{"type": "assistant", "message": map[string]any{"id": "m1", "content": []any{
			map[string]any{"type": "text", "text": "你好"},
			map[string]any{"type": "tool_use", "id": "t1", "name": "Edit", "input": map[string]any{"file_path": "a.go"}},
		}}})
		out(map[string]any{"type": "user", "message": map[string]any{"content": []any{map[string]any{"type": "tool_result", "tool_use_id": "t1", "content": []any{map[string]any{"type": "text", "text": "ok"}}}}}})
		out(map[string]any{"type": "result", "subtype": "success", "total_cost_usd": 0.01, "usage": map[string]any{"input_tokens": 10, "output_tokens": 5}, "session_id": sid})
	}
}

/** fakeCodex：模拟 exec --json 单轮 */
func fakeCodex() {
	prompt, _ := io.ReadAll(os.Stdin)
	tid := "thread-1"
	for i, a := range os.Args {
		if a == "resume" {
			tid = os.Args[i+1]
		}
	}
	out(map[string]any{"type": "thread.started", "thread_id": tid})
	if strings.Contains(string(prompt), "fail") {
		out(map[string]any{"type": "turn.failed", "error": map[string]any{"message": "模型错误"}})
		return
	}
	if strings.Contains(string(prompt), "slow") {
		time.Sleep(5 * time.Second)
		return
	}
	out(map[string]any{"type": "item.started", "item": map[string]any{"id": "c1", "type": "command_execution", "command": "ls"}})
	out(map[string]any{"type": "item.completed", "item": map[string]any{"id": "c1", "type": "command_execution", "aggregated_output": "a.txt", "exit_code": 0}})
	out(map[string]any{"type": "item.completed", "item": map[string]any{"id": "f1", "type": "file_change", "changes": []any{map[string]any{"path": "b.txt", "kind": "add"}}}})
	out(map[string]any{"type": "item.completed", "item": map[string]any{"id": "a1", "type": "agent_message", "text": "echo:" + strings.TrimSpace(string(prompt))}})
	out(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 3, "output_tokens": 4}})
}

/** fakePi：模拟 rpc 模式 */
func fakePi() {
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		var m map[string]any
		json.Unmarshal(sc.Bytes(), &m)
		switch m["type"] {
		case "get_state":
			out(map[string]any{"type": "response", "command": "get_state", "success": true, "data": map[string]any{"sessionFile": "/tmp/pi.jsonl"}})
		case "prompt", "steer":
			out(map[string]any{"type": "agent_start"})
			out(map[string]any{"type": "message_start", "message": map[string]any{"role": "assistant"}})
			out(map[string]any{"type": "message_update", "assistantMessageEvent": map[string]any{"type": "text_delta", "delta": "hi"}})
			out(map[string]any{"type": "tool_execution_start", "toolCallId": "p1", "toolName": "write", "args": map[string]any{"path": "x.md"}})
			out(map[string]any{"type": "tool_execution_end", "toolCallId": "p1", "toolName": "write", "result": map[string]any{"content": []any{map[string]any{"type": "text", "text": "written"}}}})
			out(map[string]any{"type": "message_end", "message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": "hi " + m["type"].(string)}}, "usage": map[string]any{"input": 1, "output": 2}}})
			out(map[string]any{"type": "agent_end"})
		case "abort":
			out(map[string]any{"type": "agent_end"})
		}
	}
}

/** fakeACP：模拟 ACP 服务，包括审批请求 */
func fakeACP() {
	sc := bufio.NewScanner(os.Stdin)
	permID := 100
	var promptID any
	for sc.Scan() {
		var m map[string]any
		json.Unmarshal(sc.Bytes(), &m)
		id := m["id"]
		method, _ := m["method"].(string)
		switch method {
		case "initialize":
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"protocolVersion": 1, "agentCapabilities": map[string]any{"loadSession": true}}})
		case "session/new":
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"sessionId": "acp-s1"}})
		case "session/load":
			out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "历史回放"}}}})
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
		case "session/prompt":
			promptID = id
			out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "先看看"}}}})
			out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "tool_call", "toolCallId": "tc1", "title": "bash", "kind": "other", "status": "in_progress", "rawInput": map[string]any{"command": "rm -rf tmp"}}}})
			// 与真实 DSH 一致：审批请求只带工具调用编号
			out(map[string]any{"jsonrpc": "2.0", "id": permID, "method": "session/request_permission", "params": map[string]any{
				"toolCall": map[string]any{"toolCallId": "tc1"},
				"options":  []any{map[string]any{"optionId": "yes", "kind": "allow_once"}, map[string]any{"optionId": "always", "kind": "allow_always"}, map[string]any{"optionId": "no", "kind": "reject_once"}},
			}})
		case "session/cancel":
			out(map[string]any{"jsonrpc": "2.0", "id": promptID, "result": map[string]any{"stopReason": "cancelled"}})
		case "":
			if res, ok := m["result"].(map[string]any); ok {
				opt := res["outcome"].(map[string]any)["optionId"]
				out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "tool_call_update", "toolCallId": "tc1", "status": "completed", "content": []any{map[string]any{"type": "content", "content": map[string]any{"type": "text", "text": fmt.Sprint(opt)}}}}}})
				out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "完成"}}}})
				out(map[string]any{"jsonrpc": "2.0", "id": promptID, "result": map[string]any{"stopReason": "end_turn"}})
			}
		}
	}
}
