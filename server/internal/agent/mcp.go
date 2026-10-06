/**
 * PocketDesk 的 MCP 工具（stdio）：审批工具供 Claude Code 在需要权限时调用，阻塞等待手机上的决定；
 * 发到手机工具供各 Agent 在用户要求时把电脑上的文件经文件传输发到手机。
 */
package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"sync"
)

/** SendToolName：发到手机工具名 */
const SendToolName = "send_to_phone"

/** SendToolDesc：发到手机工具的说明，各 Agent 共用 */
const SendToolDesc = "Send files from this computer to the user's phone through PocketDesk file transfer, so the user can save and view them on the phone. Use it when the user asks to send, share or transfer a file to their phone. Folders are not supported."

/** SendPathsDesc：发到手机工具 paths 参数的说明 */
const SendPathsDesc = "Paths of the files to send; relative paths are resolved against the session working directory."

/** ApproveFunc：把一次审批请求转交服务端，返回 Claude 约定的 behavior 结果 */
type ApproveFunc func(ctx context.Context, toolName string, input map[string]any) (map[string]any, error)

/** SendFunc：把文件发到手机，返回已加入发送队列的文件名 */
type SendFunc func(ctx context.Context, paths []string) ([]string, error)

/** MCPTools：MCP 服务提供的工具，为空的不列出 */
type MCPTools struct {
	Approve ApproveFunc
	Send    SendFunc
}

/** list：tools/list 的工具清单 */
func (t MCPTools) list() []any {
	var out []any
	if t.Approve != nil {
		out = append(out, map[string]any{
			"name":        "approve",
			"description": "Ask the PocketDesk owner to approve a tool call from the phone.",
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{
				"tool_name":   map[string]any{"type": "string"},
				"input":       map[string]any{"type": "object"},
				"tool_use_id": map[string]any{"type": "string"},
			}, "required": []string{"tool_name", "input"}},
		})
	}
	if t.Send != nil {
		out = append(out, map[string]any{
			"name":        SendToolName,
			"description": SendToolDesc,
			"inputSchema": map[string]any{"type": "object", "properties": map[string]any{
				"paths": map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": SendPathsDesc},
			}, "required": []string{"paths"}},
		})
	}
	return out
}

/**
 * call：执行一次工具调用，返回 MCP 约定的结果
 *
 * 处理流程：
 * 1、审批：结果以 JSON 文本返回给 Claude
 * 2、发到手机：返回已加入发送队列的文件，失败时标记为错误
 * 3、未知工具报错
 */
func (t MCPTools) call(ctx context.Context, params json.RawMessage) map[string]any {
	text := func(s string, isErr bool) map[string]any {
		return map[string]any{"content": []any{map[string]any{"type": "text", "text": s}}, "isError": isErr}
	}
	var p struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	json.Unmarshal(params, &p)
	switch {
	// 1、审批
	case p.Name == "approve" && t.Approve != nil:
		var a struct {
			ToolName string         `json:"tool_name"`
			Input    map[string]any `json:"input"`
		}
		json.Unmarshal(p.Arguments, &a)
		out, err := t.Approve(ctx, a.ToolName, a.Input)
		if err != nil {
			out = map[string]any{"behavior": "deny", "message": "审批通道不可用：" + err.Error()}
		}
		b, _ := json.Marshal(out)
		return map[string]any{"content": []any{map[string]any{"type": "text", "text": string(b)}}}
	// 2、发到手机
	case p.Name == SendToolName && t.Send != nil:
		var a struct {
			Paths []string `json:"paths"`
		}
		json.Unmarshal(p.Arguments, &a)
		if len(a.Paths) == 0 {
			return text("请指定要发送的文件", true)
		}
		names, err := t.Send(ctx, a.Paths)
		if err != nil {
			return text("发送失败："+err.Error(), true)
		}
		return text("已加入发送队列，手机连上后自动接收："+strings.Join(names, "、"), false)
	}
	// 3、未知工具
	return text("未知工具："+p.Name, true)
}

/**
 * ServeMCP：在给定输入输出上运行 MCP 服务，直到输入结束
 *
 * 处理流程：
 * 1、逐行读取 JSON-RPC 请求
 * 2、initialize / tools/list / ping 直接应答
 * 3、tools/call 在独立协程中执行，完成后应答
 */
func ServeMCP(ctx context.Context, r io.Reader, w io.Writer, tools MCPTools) error {
	var wmu sync.Mutex
	write := func(v any) {
		b, _ := json.Marshal(v)
		wmu.Lock()
		w.Write(append(b, '\n'))
		wmu.Unlock()
	}
	var wg sync.WaitGroup
	defer wg.Wait()
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 16*1024*1024)
	// 1、逐行读取
	for sc.Scan() {
		var m struct {
			ID     *json.RawMessage `json:"id"`
			Method string           `json:"method"`
			Params json.RawMessage  `json:"params"`
		}
		if json.Unmarshal(sc.Bytes(), &m) != nil || m.ID == nil {
			continue
		}
		resp := func(result any) { write(map[string]any{"jsonrpc": "2.0", "id": m.ID, "result": result}) }
		switch m.Method {
		// 2、固定应答
		case "initialize":
			var p struct {
				ProtocolVersion string `json:"protocolVersion"`
			}
			json.Unmarshal(m.Params, &p)
			if p.ProtocolVersion == "" {
				p.ProtocolVersion = "2024-11-05"
			}
			resp(map[string]any{"protocolVersion": p.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "pocketdesk", "version": "1.0.0"}})
		case "tools/list":
			resp(map[string]any{"tools": tools.list()})
		case "ping":
			resp(map[string]any{})
		// 3、工具调用
		case "tools/call":
			wg.Add(1)
			go func(id *json.RawMessage, params json.RawMessage) {
				defer wg.Done()
				write(map[string]any{"jsonrpc": "2.0", "id": id, "result": tools.call(ctx, params)})
			}(m.ID, m.Params)
		default:
			write(map[string]any{"jsonrpc": "2.0", "id": m.ID, "error": map[string]any{"code": -32601, "message": "method not found"}})
		}
	}
	return sc.Err()
}

/** ClaudeBehavior：把审批结果转换为 Claude 约定的格式 */
func ClaudeBehavior(d Decision, input map[string]any) map[string]any {
	if d.Allow {
		if input == nil {
			input = map[string]any{}
		}
		return map[string]any{"behavior": "allow", "updatedInput": input}
	}
	msg := d.Reason
	if msg == "" {
		msg = "用户在手机上拒绝了此操作"
	}
	return map[string]any{"behavior": "deny", "message": msg}
}

/** SummarizeClaudeTool：审批卡片展示用的类别与摘要 */
func SummarizeClaudeTool(name string, input map[string]any) (string, string) {
	return toolKind(name), toolSummary(name, input)
}
