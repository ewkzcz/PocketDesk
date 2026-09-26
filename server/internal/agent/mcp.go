/**
 * MCP 审批工具（stdio）：Claude Code 需要权限时调用它，它把请求转给电脑端服务并阻塞等待手机上的决定。
 */
package agent

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"sync"
)

/** ApproveFunc：把一次审批请求转交服务端，返回 Claude 约定的 behavior 结果 */
type ApproveFunc func(ctx context.Context, toolName string, input map[string]any) (map[string]any, error)

/**
 * ServeApprovalMCP：在给定输入输出上运行 MCP 服务，直到输入结束
 *
 * 处理流程：
 * 1、逐行读取 JSON-RPC 请求
 * 2、initialize / tools/list / ping 直接应答
 * 3、tools/call 在独立协程中调用审批，完成后应答
 */
func ServeApprovalMCP(ctx context.Context, r io.Reader, w io.Writer, approve ApproveFunc) error {
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
			resp(map[string]any{"tools": []any{map[string]any{
				"name":        "approve",
				"description": "Ask the PocketDesk owner to approve a tool call from the phone.",
				"inputSchema": map[string]any{"type": "object", "properties": map[string]any{
					"tool_name":   map[string]any{"type": "string"},
					"input":       map[string]any{"type": "object"},
					"tool_use_id": map[string]any{"type": "string"},
				}, "required": []string{"tool_name", "input"}},
			}}})
		case "ping":
			resp(map[string]any{})
		// 3、审批
		case "tools/call":
			var p struct {
				Arguments struct {
					ToolName string         `json:"tool_name"`
					Input    map[string]any `json:"input"`
				} `json:"arguments"`
			}
			json.Unmarshal(m.Params, &p)
			wg.Add(1)
			go func(id *json.RawMessage) {
				defer wg.Done()
				out, err := approve(ctx, p.Arguments.ToolName, p.Arguments.Input)
				if err != nil {
					out = map[string]any{"behavior": "deny", "message": "审批通道不可用：" + err.Error()}
				}
				text, _ := json.Marshal(out)
				write(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"content": []any{map[string]any{"type": "text", "text": string(text)}}}})
			}(m.ID)
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
