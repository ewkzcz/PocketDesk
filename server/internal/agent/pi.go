/**
 * Pi 驱动：以 rpc 模式常驻运行，标准输入输出逐行 JSON；
 * 加载内置审批扩展，执行命令和写工作区外文件前经扩展界面请求向手机要确认。
 */
package agent

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

/** piApproveExt：审批扩展源码 */
//go:embed pi_approve.ts
var piApproveExt []byte

/** piApprovalTitle：审批扩展发起选择请求时的标题前缀，后接 JSON 内容 */
const piApprovalTitle = "pocketdesk:approval "

/** piExtensionPath：把审批扩展写到缓存目录，内容不变时不重写 */
func piExtensionPath() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		dir = os.TempDir()
	}
	p := filepath.Join(dir, "PocketDesk", "pi-approve.ts")
	if old, err := os.ReadFile(p); err == nil && bytes.Equal(old, piApproveExt) {
		return p, nil
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	return p, os.WriteFile(p, piApproveExt, 0o644)
}

/** PiDriver：Pi 接入 */
type PiDriver struct{}

/** Kind：类型 */
func (PiDriver) Kind() string { return KindPi }

/** PiArgs：组装启动参数，有会话文件时续聊 */
func PiArgs(opt Options) []string {
	args := append([]string{}, opt.Command...)
	args = append(args, "--mode", "rpc")
	if opt.Model != "" {
		args = append(args, "--model", opt.Model)
	}
	if opt.ResumeID != "" {
		args = append(args, "--session", opt.ResumeID)
	}
	return args
}

/**
 * Start：启动常驻进程并查询会话信息
 *
 * 处理流程：
 * 1、启动 rpc 模式
 * 2、发送 get_state 取会话文件路径，用于续聊
 */
func (PiDriver) Start(_ context.Context, opt Options) (Process, error) {
	if len(opt.Command) == 0 {
		opt.Command = []string{"pi"}
	}
	// 1、启动；有审批方时加载审批扩展
	args := PiArgs(opt)
	if opt.Approver != nil && !opt.AutoApprove {
		ext, err := piExtensionPath()
		if err != nil {
			return nil, fmt.Errorf("准备审批扩展失败: %w", err)
		}
		args = append(args, "-e", ext)
	}
	parser := &piParser{}
	p, err := startLineProc(args, opt.Cwd, append(EnvPath(), opt.Env...), func(lp *lineProc, line []byte) {
		if bytes.Contains(line, []byte(`"extension_ui_request"`)) {
			piUIRequest(lp, opt.Approver, line)
			return
		}
		for _, e := range parser.parse(line) {
			lp.emit(e)
		}
	})
	if err != nil {
		return nil, err
	}
	// 2、会话信息
	p.writeJSON(map[string]any{"type": "get_state"})
	return &piProc{lineProc: p}, nil
}

/**
 * piUIRequest：处理扩展界面请求
 *
 * 处理流程：
 * 1、只有选择、确认、输入、编辑四类对话需要回复，其余为通知直接忽略
 * 2、审批扩展的选择请求：解析内容，异步等待手机决定后回复 allow / deny
 * 3、其他扩展的对话：手机上没有对应界面，直接取消，避免 Pi 一直等待
 */
func piUIRequest(lp *lineProc, ap Approver, line []byte) {
	var r struct {
		ID     string `json:"id"`
		Method string `json:"method"`
		Title  string `json:"title"`
	}
	if json.Unmarshal(line, &r) != nil {
		return
	}
	// 1、通知类
	switch r.Method {
	case "select", "confirm", "input", "editor":
	default:
		return
	}
	// 2、审批
	if r.Method == "select" && strings.HasPrefix(r.Title, piApprovalTitle) && ap != nil {
		var req ApprovalRequest
		json.Unmarshal([]byte(strings.TrimPrefix(r.Title, piApprovalTitle)), &req)
		go func() {
			d, err := ap.RequestApproval(context.Background(), req)
			value := "deny"
			if err == nil && d.Allow {
				value = "allow"
			}
			lp.writeJSON(map[string]any{"type": "extension_ui_response", "id": r.ID, "value": value})
		}()
		return
	}
	// 3、其他对话
	lp.writeJSON(map[string]any{"type": "extension_ui_response", "id": r.ID, "cancelled": true})
}

/** piProc：Pi 进程 */
type piProc struct{ *lineProc }

/** Send：发送提示词 */
func (p *piProc) Send(_ context.Context, m Message) error {
	return p.writeJSON(map[string]any{"type": "prompt", "message": SkillPrompt(KindPi, m.Skills, PromptWithAttachments(m))})
}

/** Interrupt：发送 abort 指令 */
func (p *piProc) Interrupt() error {
	return p.writeJSON(map[string]any{"type": "abort"})
}

/** piParser：解析 rpc 输出 */
type piParser struct {
	msgSeq int
}

/**
 * parse：解析一行
 *
 * 处理流程：
 * 1、message_update 取文本与思考增量
 * 2、message_end 取完整回复与用量
 * 3、tool_execution_start / end 产生工具卡片
 * 4、agent_end 结束本轮；response 失败时报错；get_state 取会话 ID
 */
func (p *piParser) parse(line []byte) []Event {
	var l struct {
		Type    string          `json:"type"`
		Command string          `json:"command"`
		Success *bool           `json:"success"`
		Error   string          `json:"error"`
		Data    json.RawMessage `json:"data"`
		Message struct {
			Role    string  `json:"role"`
			Content []block `json:"content"`
			Usage   struct {
				Input  int64 `json:"input"`
				Output int64 `json:"output"`
				Cost   struct {
					Total float64 `json:"total"`
				} `json:"cost"`
			} `json:"usage"`
			ErrorMessage string `json:"errorMessage"`
		} `json:"message"`
		Event struct {
			Type  string `json:"type"`
			Delta string `json:"delta"`
		} `json:"assistantMessageEvent"`
		ToolCallID string         `json:"toolCallId"`
		ToolName   string         `json:"toolName"`
		Args       map[string]any `json:"args"`
		Result     struct {
			Content []block `json:"content"`
		} `json:"result"`
		IsError bool `json:"isError"`
	}
	if json.Unmarshal(line, &l) != nil {
		return nil
	}
	id := fmt.Sprintf("pi-%d", p.msgSeq)
	switch l.Type {
	case "message_start":
		p.msgSeq++
	// 1、增量
	case "message_update":
		switch l.Event.Type {
		case "text_delta":
			return []Event{ev(EvDelta, "id", id, "text", l.Event.Delta)}
		case "thinking_delta":
			return []Event{ev(EvThinking, "id", id+"-t", "text", l.Event.Delta, "delta", true)}
		}
	// 2、完整消息
	case "message_end":
		if l.Message.Role != "assistant" {
			return nil
		}
		var text strings.Builder
		for _, b := range l.Message.Content {
			if b.Type == "text" {
				text.WriteString(b.Text)
			}
		}
		out := []Event{ev(EvThinking, "id", id+"-t", "done", true)}
		if text.Len() > 0 {
			out = append(out, ev(EvDone, "id", id, "text", text.String()))
		}
		if l.Message.ErrorMessage != "" {
			out = append(out, ev(EvError, "message", l.Message.ErrorMessage))
		}
		return append(out, ev(EvUsage, "inputTokens", l.Message.Usage.Input, "outputTokens", l.Message.Usage.Output, "costUsd", l.Message.Usage.Cost.Total))
	// 3、工具
	case "tool_execution_start":
		out := []Event{ev(EvToolStart, "id", l.ToolCallID, "name", l.ToolName, "kind", piToolKind(l.ToolName), "summary", piSummary(l.ToolName, l.Args), "input", l.Args)}
		if l.ToolName == "write" || l.ToolName == "edit" {
			if fp, _ := l.Args["path"].(string); fp != "" {
				out = append(out, ev(EvFileWrite, "path", fp))
			}
		}
		return out
	case "tool_execution_end":
		var text strings.Builder
		for _, b := range l.Result.Content {
			if b.Type == "text" {
				text.WriteString(b.Text)
			}
		}
		return []Event{ev(EvToolEnd, "id", l.ToolCallID, "output", Truncate(text.String(), 8000), "isError", l.IsError)}
	// 4、结束与应答
	case "agent_end":
		return []Event{ev(EvTurnEnd)}
	case "response":
		if l.Success != nil && !*l.Success {
			out := []Event{ev(EvError, "message", l.Error)}
			if l.Command == "prompt" {
				out = append(out, ev(EvTurnEnd))
			}
			return out
		}
		if l.Command == "get_state" {
			var st struct {
				SessionFile string `json:"sessionFile"`
				SessionID   string `json:"sessionId"`
				Model       struct {
					ID string `json:"id"`
				} `json:"model"`
			}
			if json.Unmarshal(l.Data, &st) == nil {
				sid := st.SessionFile
				if sid == "" {
					sid = st.SessionID
				}
				if sid != "" {
					return []Event{ev(EvSessionID, "id", sid, "model", st.Model.ID)}
				}
			}
		}
	}
	return nil
}

/** piToolKind：Pi 内置工具归类 */
func piToolKind(name string) string {
	switch name {
	case "bash":
		return "command"
	case "read":
		return "read"
	case "write", "edit":
		return "edit"
	case "grep", "find", "ls":
		return "search"
	}
	return "other"
}

/** piSummary：工具摘要 */
func piSummary(name string, args map[string]any) string {
	if c, _ := args["command"].(string); c != "" {
		return c
	}
	if p, _ := args["path"].(string); p != "" {
		return name + " " + p
	}
	if p, _ := args["pattern"].(string); p != "" {
		return name + " " + p
	}
	return name
}
