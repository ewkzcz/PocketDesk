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
	case "codexapp":
		fakeCodexApp()
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
	// 旧版本没有 app-server 子命令
	for _, a := range os.Args {
		if a == "app-server" {
			fmt.Fprintln(os.Stderr, "error: unrecognized subcommand 'app-server'")
			os.Exit(2)
		}
	}
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

/** fakeCodexApp：模拟 codex app-server，与真实抓包一致：审批请求只带条目 ID */
func fakeCodexApp() {
	cwd, _ := os.Getwd()
	note := func(method string, params any) { out(map[string]any{"method": method, "params": params}) }
	result := func(id any, r any) { out(map[string]any{"id": id, "result": r}) }
	finish := func(status string) {
		note("thread/tokenUsage/updated", map[string]any{"tokenUsage": map[string]any{"total": map[string]any{"inputTokens": 10, "outputTokens": 5}}})
		note("turn/completed", map[string]any{"turn": map[string]any{"id": "tu1", "status": status}})
	}
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		var m map[string]any
		json.Unmarshal(sc.Bytes(), &m)
		id := m["id"]
		params, _ := m["params"].(map[string]any)
		switch m["method"] {
		case "initialize":
			result(id, map[string]any{"userAgent": "fake"})
		case "thread/start":
			result(id, map[string]any{"thread": map[string]any{"id": "th-new"}, "model": "gpt-x"})
		case "thread/resume":
			if params["threadId"] == "th-old" {
				result(id, map[string]any{"thread": map[string]any{"id": "th-old"}, "model": "gpt-x"})
			} else {
				out(map[string]any{"id": id, "error": map[string]any{"code": -32600, "message": "thread not found"}})
			}
		case "turn/start":
			text := params["input"].([]any)[0].(map[string]any)["text"].(string)
			result(id, map[string]any{"turn": map[string]any{"id": "tu1", "status": "inProgress"}})
			note("turn/started", map[string]any{"turn": map[string]any{"id": "tu1"}})
			if strings.Contains(text, "slow") {
				continue
			}
			note("item/started", map[string]any{"item": map[string]any{"type": "commandExecution", "id": "c1", "command": "/bin/zsh -lc 'rm -rf tmp'", "commandActions": []any{map[string]any{"type": "unknown", "command": "rm -rf tmp"}}}})
			out(map[string]any{"id": 100, "method": "item/commandExecution/requestApproval", "params": map[string]any{"itemId": "c1", "command": "/bin/zsh -lc 'rm -rf tmp'"}})
		case "turn/interrupt":
			result(id, map[string]any{})
			finish("interrupted")
		case nil:
			// 对审批请求的回复
			res, _ := m["result"].(map[string]any)
			decision := fmt.Sprint(res["decision"])
			switch fmt.Sprint(id) {
			case "100":
				note("item/completed", map[string]any{"item": map[string]any{"type": "commandExecution", "id": "c1", "status": "completed", "aggregatedOutput": decision, "exitCode": 0}})
				note("item/started", map[string]any{"item": map[string]any{"type": "fileChange", "id": "f1", "changes": []any{map[string]any{"path": cwd + "/b.txt", "diff": "x"}}, "status": "inProgress"}})
				out(map[string]any{"id": 101, "method": "item/fileChange/requestApproval", "params": map[string]any{"itemId": "f1"}})
			case "101":
				status := "declined"
				if decision == "accept" || decision == "acceptForSession" {
					status = "completed"
				}
				note("item/completed", map[string]any{"item": map[string]any{"type": "fileChange", "id": "f1", "status": status, "changes": []any{map[string]any{"path": cwd + "/b.txt", "diff": "x"}}}})
				note("item/agentMessage/delta", map[string]any{"itemId": "m1", "delta": "完成"})
				note("item/completed", map[string]any{"item": map[string]any{"type": "agentMessage", "id": "m1", "text": "完成"}})
				finish("completed")
			}
		}
	}
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
		case "prompt":
			out(map[string]any{"type": "agent_start"})
			if msg, _ := m["message"].(string); msg == "danger" {
				fakePiApproval(sc)
				continue
			}
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

/**
 * fakePiApproval：模拟审批扩展，与真实 Pi 一致：先发一个其他扩展的确认对话（应被取消），
 * 再由审批扩展发选择请求；把两次回复写进工具结果，便于测试核对
 */
func fakePiApproval(sc *bufio.Scanner) {
	ext := ""
	for i, a := range os.Args {
		if a == "-e" && i+1 < len(os.Args) {
			ext = os.Args[i+1]
		}
	}
	if b, err := os.ReadFile(ext); err != nil || !strings.Contains(string(b), "pocketdesk:approval") {
		out(map[string]any{"type": "response", "command": "prompt", "success": false, "error": "未加载审批扩展"})
		out(map[string]any{"type": "agent_end"})
		return
	}
	read := func() map[string]any {
		sc.Scan()
		var r map[string]any
		json.Unmarshal(sc.Bytes(), &r)
		return r
	}
	out(map[string]any{"type": "extension_ui_request", "id": "n1", "method": "notify", "message": "忽略"})
	out(map[string]any{"type": "extension_ui_request", "id": "c1", "method": "confirm", "title": "其他扩展", "message": "?"})
	other := read()
	out(map[string]any{"type": "tool_execution_start", "toolCallId": "b1", "toolName": "bash", "args": map[string]any{"command": "rm -rf tmp"}})
	out(map[string]any{"type": "extension_ui_request", "id": "a1", "method": "select", "title": `pocketdesk:approval {"tool":"bash","kind":"command","summary":"rm -rf tmp","input":{"command":"rm -rf tmp"}}`, "options": []string{"allow", "deny"}})
	ans := read()
	text := fmt.Sprintf("%v/%v/%v", other["cancelled"], ans["id"], ans["value"])
	out(map[string]any{"type": "tool_execution_end", "toolCallId": "b1", "toolName": "bash", "result": map[string]any{"content": []any{map[string]any{"type": "text", "text": text}}}})
	out(map[string]any{"type": "agent_end"})
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
			// 与真实 DSH 一致：模型取值是字符串数组编码，按提供方分组
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"sessionId": "acp-s1", "configOptions": []any{
				map[string]any{"id": "model", "category": "model", "type": "select", "currentValue": `["ds","flash"]`, "options": []any{
					map[string]any{"group": "ds", "name": "DeepSeek", "options": []any{map[string]any{"value": `["ds","flash"]`, "name": "Flash"}, map[string]any{"value": `["ds","pro"]`, "name": "Pro"}}},
				}},
				map[string]any{"id": "reasoning_effort", "category": "thought_level", "currentValue": "high", "options": []any{map[string]any{"value": "high"}}},
			}}})
		case "session/set_config_option":
			params, _ := m["params"].(map[string]any)
			if params["configId"] != "model" || params["value"] != `["ds","pro"]` || params["sessionId"] != "acp-s1" {
				out(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": -32602, "message": fmt.Sprint("取值不对 ", params)}})
				continue
			}
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
		case "session/load":
			out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "历史回放"}}}})
			out(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
		case "session/prompt":
			promptID = id
			out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "想一想"}}}})
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
				out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_thought_chunk", "content": map[string]any{"type": "text", "text": "再想"}}}})
				out(map[string]any{"jsonrpc": "2.0", "method": "session/update", "params": map[string]any{"update": map[string]any{"sessionUpdate": "agent_message_chunk", "content": map[string]any{"type": "text", "text": "完成"}}}})
				out(map[string]any{"jsonrpc": "2.0", "id": promptID, "result": map[string]any{"stopReason": "end_turn"}})
			}
		}
	}
}
