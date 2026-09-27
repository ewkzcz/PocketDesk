/**
 * ACP 驱动（Agent Client Protocol，JSON-RPC over stdio）：用于 DSH，也可接入任何支持 ACP 的 Agent。
 */
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

/** ACPDriver：ACP 接入，kind 决定登记名 */
type ACPDriver struct {
	Name string
}

/** Kind：类型 */
func (d ACPDriver) Kind() string { return d.Name }

/** SupportsSteer：ACP 没有插话语义 */
func (ACPDriver) SupportsSteer() bool { return false }

/** acpProc：一个 ACP 会话 */
type acpProc struct {
	*rpcConn
	opt       Options
	mu        sync.Mutex
	sessionID string
	loading   bool
	msgSeq    int
	buf       strings.Builder
	turnCtx   context.Context
	cancel    context.CancelFunc
	tools     map[string]acpTool
}

/** acpTool：已开始的工具调用，审批请求只带编号时据此补全内容 */
type acpTool struct {
	title string
	kind  string
	input map[string]any
}

/**
 * Start：启动并完成握手
 *
 * 处理流程：
 * 1、启动进程，按消息类型分发
 * 2、initialize 协商版本
 * 3、有旧会话且对方支持时 session/load，否则 session/new
 * 4、记下可选模型；指定了模型时切换过去
 */
func (d ACPDriver) Start(ctx context.Context, opt Options) (Process, error) {
	if len(opt.Command) == 0 {
		return nil, errors.New("未配置启动命令")
	}
	a := &acpProc{rpcConn: newRPCConn(), opt: opt, tools: map[string]acpTool{}}
	// 1、启动
	env := append(EnvPath(), opt.Env...)
	if opt.AutoApprove {
		// DSH 的完全访问模式：不进沙箱，也不再请求审批
		env = append(env, "DSH_PERMISSION_MODE=danger-full-access")
	}
	p, err := startLineProc(append([]string{}, opt.Command...), opt.Cwd, env, func(lp *lineProc, line []byte) {
		a.dispatch(line)
	})
	if err != nil {
		return nil, err
	}
	a.attach(p)
	hctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	// 2、握手
	var init struct {
		AgentCapabilities struct {
			LoadSession bool `json:"loadSession"`
		} `json:"agentCapabilities"`
	}
	if err := a.call(hctx, "initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{"fs": map[string]bool{"readTextFile": false, "writeTextFile": false}, "terminal": false},
	}, &init); err != nil {
		p.Close()
		return nil, fmt.Errorf("握手失败: %w", err)
	}
	// 3、会话
	var ns struct {
		SessionID     string          `json:"sessionId"`
		ConfigOptions json.RawMessage `json:"configOptions"`
	}
	if opt.ResumeID != "" && init.AgentCapabilities.LoadSession {
		a.mu.Lock()
		a.loading = true
		a.mu.Unlock()
		err := a.call(hctx, "session/load", map[string]any{"sessionId": opt.ResumeID, "cwd": opt.Cwd, "mcpServers": []any{}}, &ns)
		a.mu.Lock()
		a.loading = false
		a.mu.Unlock()
		if err == nil {
			ns.SessionID = opt.ResumeID
		}
	}
	if ns.SessionID == "" {
		if err := a.call(hctx, "session/new", map[string]any{"cwd": opt.Cwd, "mcpServers": []any{}}, &ns); err != nil {
			p.Close()
			return nil, fmt.Errorf("创建会话失败: %w", err)
		}
	}
	a.sessionID = ns.SessionID
	// 4、模型
	model := a.selectModel(hctx, d.Name, ns.ConfigOptions)
	p.emit(ev(EvSessionID, "id", a.sessionID, "model", model))
	return a, nil
}

/**
 * selectModel：缓存可选模型，按展示名、取值切换到指定模型，返回当前模型展示名
 */
func (a *acpProc) selectModel(ctx context.Context, kind string, raw json.RawMessage) string {
	opts, current := acpModels(raw)
	if len(opts) > 0 {
		names := make([]string, len(opts))
		for i, o := range opts {
			names[i] = o.display
		}
		acpModelCache.Store(kind, names)
	}
	if a.opt.Model == "" || a.opt.Model == current {
		return current
	}
	for _, o := range opts {
		if o.display == a.opt.Model || o.value == a.opt.Model {
			if err := a.call(ctx, "session/set_config_option", map[string]any{"sessionId": a.sessionID, "configId": "model", "value": o.value}, nil); err != nil {
				a.emit(ev(EvError, "message", "切换模型失败："+err.Error()))
				return current
			}
			return o.display
		}
	}
	a.emit(ev(EvError, "message", "没有找到模型 "+a.opt.Model+"，继续使用 "+current))
	return current
}

/**
 * dispatch：分发一行消息
 *
 * 处理流程：
 * 1、响应：交给等待中的请求
 * 2、对方请求：审批请求走审批，其他返回未实现
 * 3、通知：session/update 翻译为统一事件
 */
func (a *acpProc) dispatch(line []byte) {
	var m rpcMsg
	if json.Unmarshal(line, &m) != nil {
		return
	}
	switch {
	// 1、响应
	case m.ID != nil && m.Method == "":
		a.resolve(m)
	// 2、请求
	case m.ID != nil:
		go a.handleRequest(m)
	// 3、通知
	case m.Method == "session/update":
		a.mu.Lock()
		loading := a.loading
		a.mu.Unlock()
		if !loading {
			for _, e := range a.update(m.Params) {
				a.emit(e)
			}
		}
	}
}

/**
 * handleRequest：处理对方发来的请求
 *
 * 处理流程：
 * 1、session/request_permission：先把已输出的文本收尾，再请求审批
 * 2、按审批结果选择对应的选项 ID
 * 3、其他方法返回未实现
 */
func (a *acpProc) handleRequest(m rpcMsg) {
	if m.Method != "session/request_permission" {
		// 3、未实现
		a.reply(m.ID, nil, &rpcError{Code: -32601, Message: "method not found"})
		return
	}
	// 1、审批
	var p struct {
		ToolCall struct {
			ToolCallID string         `json:"toolCallId"`
			Title      string         `json:"title"`
			Kind       string         `json:"kind"`
			RawInput   map[string]any `json:"rawInput"`
		} `json:"toolCall"`
		Options []struct {
			OptionID string `json:"optionId"`
			Kind     string `json:"kind"`
		} `json:"options"`
	}
	json.Unmarshal(m.Params, &p)
	a.flush()
	a.mu.Lock()
	ctx := a.turnCtx
	// 请求里只带编号时（如 DSH），用之前工具开始时记下的标题、类别和参数补全
	tc := p.ToolCall
	if t, ok := a.tools[tc.ToolCallID]; ok {
		if tc.Title == "" {
			tc.Title = t.title
		}
		if tc.Kind == "" {
			tc.Kind = t.kind
		}
		if tc.RawInput == nil {
			tc.RawInput = t.input
		}
	}
	a.mu.Unlock()
	if ctx == nil {
		ctx = context.Background()
	}
	if a.opt.Approver == nil {
		a.reply(m.ID, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}}, nil)
		return
	}
	d, err := a.opt.Approver.RequestApproval(ctx, ApprovalRequest{Tool: tc.Title, Kind: acpToolKind(tc.Kind, tc.RawInput), Summary: acpSummary(tc.Title, tc.RawInput), Input: tc.RawInput})
	if err != nil {
		a.reply(m.ID, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}}, nil)
		return
	}
	// 2、选项
	want := []string{"reject_once", "reject_always"}
	if d.Allow {
		want = []string{"allow_once", "allow_always"}
		if d.Always {
			want = []string{"allow_always", "allow_once"}
		}
	}
	for _, k := range want {
		for _, o := range p.Options {
			if o.Kind == k {
				a.reply(m.ID, map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": o.OptionID}}, nil)
				return
			}
		}
	}
	a.reply(m.ID, map[string]any{"outcome": map[string]any{"outcome": "cancelled"}}, nil)
}

/** update：翻译 session/update */
func (a *acpProc) update(raw json.RawMessage) []Event {
	var p struct {
		Update struct {
			SessionUpdate string          `json:"sessionUpdate"`
			Content       json.RawMessage `json:"content"`
			ToolCallID    string          `json:"toolCallId"`
			Title         string          `json:"title"`
			Kind          string          `json:"kind"`
			Status        string          `json:"status"`
			RawInput      map[string]any  `json:"rawInput"`
			Locations     []struct {
				Path string `json:"path"`
			} `json:"locations"`
		} `json:"update"`
	}
	if json.Unmarshal(raw, &p) != nil {
		return nil
	}
	u := p.Update
	switch u.SessionUpdate {
	case "agent_message_chunk":
		text := chunkText(u.Content)
		a.mu.Lock()
		a.buf.WriteString(text)
		id := fmt.Sprintf("acp-%d", a.msgSeq)
		a.mu.Unlock()
		return []Event{ev(EvDelta, "id", id, "text", text)}
	case "agent_thought_chunk":
		a.mu.Lock()
		id := fmt.Sprintf("acp-%d-t", a.msgSeq)
		a.mu.Unlock()
		return []Event{ev(EvThinking, "id", id, "text", chunkText(u.Content), "delta", true)}
	case "tool_call":
		out := a.flushEvents()
		kind := acpToolKind(u.Kind, u.RawInput)
		a.mu.Lock()
		a.tools[u.ToolCallID] = acpTool{title: u.Title, kind: u.Kind, input: u.RawInput}
		a.mu.Unlock()
		out = append(out, ev(EvToolStart, "id", u.ToolCallID, "name", u.Title, "kind", kind, "summary", acpSummary(u.Title, u.RawInput), "input", u.RawInput))
		if kind == "edit" {
			for _, l := range u.Locations {
				out = append(out, ev(EvFileWrite, "path", l.Path))
			}
		}
		if u.Status == "completed" || u.Status == "failed" {
			out = append(out, ev(EvToolEnd, "id", u.ToolCallID, "isError", u.Status == "failed"))
		}
		return out
	case "tool_call_update":
		a.mu.Lock()
		if t, ok := a.tools[u.ToolCallID]; ok {
			if u.Title != "" {
				t.title = u.Title
			}
			if u.Kind != "" {
				t.kind = u.Kind
			}
			if u.RawInput != nil {
				t.input = u.RawInput
			}
			a.tools[u.ToolCallID] = t
		}
		a.mu.Unlock()
		if u.Status == "completed" || u.Status == "failed" {
			a.mu.Lock()
			delete(a.tools, u.ToolCallID)
			a.mu.Unlock()
			return []Event{ev(EvToolEnd, "id", u.ToolCallID, "output", Truncate(toolContentText(u.Content), 8000), "isError", u.Status == "failed")}
		}
	}
	return nil
}

/** flushEvents：把已累积的回复文本收尾为 msg.done */
func (a *acpProc) flushEvents() []Event {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.buf.Len() == 0 {
		return nil
	}
	e := ev(EvDone, "id", fmt.Sprintf("acp-%d", a.msgSeq), "text", a.buf.String())
	a.buf.Reset()
	a.msgSeq++
	return []Event{e, ev(EvThinking, "id", fmt.Sprintf("acp-%d-t", a.msgSeq-1), "done", true)}
}

/** flush：收尾并发出 */
func (a *acpProc) flush() {
	for _, e := range a.flushEvents() {
		a.emit(e)
	}
}

/**
 * Send：发起一轮 session/prompt，响应到达即本轮结束
 */
func (a *acpProc) Send(_ context.Context, m Message) error {
	ctx, cancel := context.WithCancel(context.Background())
	a.mu.Lock()
	a.turnCtx, a.cancel = ctx, cancel
	sid := a.sessionID
	a.mu.Unlock()
	go func() {
		defer cancel()
		var res struct {
			StopReason string `json:"stopReason"`
		}
		err := a.call(ctx, "session/prompt", map[string]any{"sessionId": sid, "prompt": []map[string]any{{"type": "text", "text": PromptWithAttachments(m)}}}, &res)
		a.flush()
		if err != nil && !errors.Is(err, context.Canceled) {
			a.emit(ev(EvError, "message", err.Error()))
		}
		a.emit(ev(EvTurnEnd, "stopReason", res.StopReason))
	}()
	return nil
}

/** Steer：不支持 */
func (a *acpProc) Steer(context.Context, Message) error { return ErrUnsupported }

/** Interrupt：发送 session/cancel 通知 */
func (a *acpProc) Interrupt() error {
	a.mu.Lock()
	sid := a.sessionID
	a.mu.Unlock()
	return a.notify("session/cancel", map[string]any{"sessionId": sid})
}

/** chunkText：内容块中的文本 */
func chunkText(raw json.RawMessage) string {
	var c struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	json.Unmarshal(raw, &c)
	return c.Text
}

/** toolContentText：工具输出内容数组中的文本 */
func toolContentText(raw json.RawMessage) string {
	var items []struct {
		Type    string `json:"type"`
		Path    string `json:"path"`
		Content struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if json.Unmarshal(raw, &items) != nil {
		return ""
	}
	var b strings.Builder
	for _, it := range items {
		switch it.Type {
		case "content":
			b.WriteString(it.Content.Text)
		case "diff":
			b.WriteString("修改 " + it.Path)
		}
		b.WriteByte('\n')
	}
	return strings.TrimSpace(b.String())
}

/** acpToolKind：类别未标明但参数带命令时按执行命令处理 */
func acpToolKind(k string, input map[string]any) string {
	kind := acpKind(k)
	if kind == "other" {
		if c, _ := input["command"].(string); c != "" {
			return "command"
		}
	}
	return kind
}

/** acpSummary：一行摘要，执行命令时显示完整命令 */
func acpSummary(title string, input map[string]any) string {
	if c, _ := input["command"].(string); c != "" {
		return c
	}
	return title
}

/** acpKind：ACP 工具类别映射为统一类别 */
func acpKind(k string) string {
	switch k {
	case "execute":
		return "command"
	case "read":
		return "read"
	case "edit", "delete", "move":
		return "edit"
	case "search":
		return "search"
	case "fetch":
		return "web"
	}
	return "other"
}
