/**
 * Claude Code 驱动：以 stream-json 双向模式常驻运行，审批通过 MCP 审批工具回到手机。
 */
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
)

/** approveToolName：Claude 调用的审批工具全名 */
const approveToolName = "mcp__pocketdesk__approve"

/** writeTools：会修改文件的工具，用于非 git 目录生成改动清单 */
var writeTools = map[string]bool{"Write": true, "Edit": true, "MultiEdit": true, "NotebookEdit": true}

/** ClaudeDriver：Claude Code 接入 */
type ClaudeDriver struct{}

/** Kind：类型 */
func (ClaudeDriver) Kind() string { return KindClaude }

/**
 * ClaudeArgs：组装启动参数
 *
 * 处理流程：
 * 1、固定使用 stream-json 输入输出与增量消息
 * 2、按需追加模型与续聊参数
 * 3、免审批时跳过全部权限确认；否则配置了审批命令时挂上 MCP 审批工具
 */
func ClaudeArgs(opt Options) []string {
	// 1、基础参数
	args := append([]string{}, opt.Command...)
	args = append(args, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages")
	// 2、模型与续聊
	if opt.Model != "" {
		args = append(args, "--model", opt.Model)
	}
	if opt.ResumeID != "" {
		args = append(args, "--resume", opt.ResumeID)
	}
	// 3、审批
	if opt.AutoApprove {
		return append(args, "--dangerously-skip-permissions")
	}
	if len(opt.ApproveCmd) > 0 {
		cfg := map[string]any{"mcpServers": map[string]any{"pocketdesk": map[string]any{"command": opt.ApproveCmd[0], "args": opt.ApproveCmd[1:]}}}
		b, _ := json.Marshal(cfg)
		args = append(args, "--mcp-config", string(b), "--permission-prompt-tool", approveToolName)
	}
	return args
}

/** Start：启动常驻进程 */
func (d ClaudeDriver) Start(_ context.Context, opt Options) (Process, error) {
	if len(opt.Command) == 0 {
		opt.Command = []string{"claude"}
	}
	c := &claudeProc{parser: newClaudeParser()}
	p, err := startLineProc(ClaudeArgs(opt), opt.Cwd, append(EnvPath(), opt.Env...), func(lp *lineProc, line []byte) {
		for _, e := range c.parser.parse(line) {
			if e.Type == EvTurnEnd {
				c.turnEnded()
			}
			lp.emit(e)
		}
	})
	if err != nil {
		return nil, err
	}
	c.lineProc = p
	return c, nil
}

/** claudeProc：Claude 进程 */
type claudeProc struct {
	*lineProc
	parser  *claudeParser
	mu      sync.Mutex
	running bool
	reqSeq  int
	timer   *time.Timer
}

/** Send：发送一条用户消息 */
func (c *claudeProc) Send(_ context.Context, m Message) error {
	c.mu.Lock()
	c.running = true
	c.mu.Unlock()
	return c.writeJSON(map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": []map[string]any{{"type": "text", "text": PromptWithAttachments(m)}}},
	})
}

/**
 * Interrupt：先发中断控制请求，3 秒内未结束本轮再发中断信号
 */
func (c *claudeProc) Interrupt() error {
	c.mu.Lock()
	c.reqSeq++
	id := fmt.Sprintf("pd-int-%d", c.reqSeq)
	if c.timer != nil {
		c.timer.Stop()
	}
	c.timer = time.AfterFunc(3*time.Second, func() {
		c.mu.Lock()
		still := c.running
		c.mu.Unlock()
		if still {
			c.signalInterrupt()
		}
	})
	c.mu.Unlock()
	return c.writeJSON(map[string]any{"type": "control_request", "request_id": id, "request": map[string]any{"subtype": "interrupt"}})
}

/** turnEnded：本轮结束，取消兜底中断 */
func (c *claudeProc) turnEnded() {
	c.mu.Lock()
	c.running = false
	if c.timer != nil {
		c.timer.Stop()
	}
	c.mu.Unlock()
}

/** PromptWithAttachments：把附件相对路径附在提示词后面 */
func PromptWithAttachments(m Message) string {
	if len(m.Attachments) == 0 {
		return m.Text
	}
	var b strings.Builder
	b.WriteString(m.Text)
	b.WriteString("\n\n附件：")
	for _, a := range m.Attachments {
		b.WriteString("\n- ")
		b.WriteString(a)
	}
	return b.String()
}

/** claudeParser：把 stream-json 行翻译为统一事件 */
type claudeParser struct {
	msgID       string
	streamed    map[string]bool
	thinkStream bool
	// 按「消息 ID|类型」记录流式阶段出现过的内容块，完整消息到达时按顺序对应。
	// Claude Code 会把一次回复拆成每块一条的完整消息，块在完整消息里的序号与流式阶段不同
	order map[string][]string
}

/** newClaudeParser：创建解析器 */
func newClaudeParser() *claudeParser {
	return &claudeParser{streamed: map[string]bool{}, order: map[string][]string{}}
}

/** noteStream：记录流式内容块，首次出现时排进对应队列 */
func (p *claudeParser) noteStream(id, kind string) {
	if !p.streamed[id] {
		p.streamed[id] = true
		key := p.msgID + "|" + kind
		p.order[key] = append(p.order[key], id)
	}
}

/** blockID：完整消息中内容块的 ID，优先取流式阶段同类内容块的 ID */
func (p *claudeParser) blockID(msgID, kind string, i int) string {
	key := msgID + "|" + kind
	if q := p.order[key]; len(q) > 0 {
		p.order[key] = q[1:]
		if len(q) == 1 {
			delete(p.order, key)
		}
		return q[0]
	}
	return fmt.Sprintf("%s:%d", msgID, i)
}

/** claudeLine：一行输出的通用结构 */
type claudeLine struct {
	Type      string          `json:"type"`
	Subtype   string          `json:"subtype"`
	SessionID string          `json:"session_id"`
	Model     string          `json:"model"`
	Message   json.RawMessage `json:"message"`
	Event     json.RawMessage `json:"event"`
	Result    string          `json:"result"`
	IsError   bool            `json:"is_error"`
	CostUSD   float64         `json:"total_cost_usd"`
	Duration  int64           `json:"duration_ms"`
	Usage     struct {
		Input       int64 `json:"input_tokens"`
		Output      int64 `json:"output_tokens"`
		CacheRead   int64 `json:"cache_read_input_tokens"`
		CacheCreate int64 `json:"cache_creation_input_tokens"`
	} `json:"usage"`
}

/** block：消息内容块 */
type block struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     map[string]any  `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

/**
 * parse：解析一行
 *
 * 处理流程：
 * 1、system/init 取会话 ID
 * 2、stream_event 取文本与思考增量
 * 3、assistant 取完整文本、思考与工具调用
 * 4、user 取工具结果
 * 5、result 取用量、错误并结束本轮
 */
func (p *claudeParser) parse(line []byte) []Event {
	var l claudeLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil
	}
	switch l.Type {
	// 1、初始化
	case "system":
		if l.Subtype == "init" && l.SessionID != "" {
			return []Event{ev(EvSessionID, "id", l.SessionID, "model", l.Model)}
		}
	// 2、增量
	case "stream_event":
		return p.streamEvent(l.Event)
	// 3、助手消息
	case "assistant":
		return p.assistant(l.Message)
	// 4、工具结果
	case "user":
		return p.toolResults(l.Message)
	// 5、结果
	case "result":
		out := []Event{ev(EvUsage, "inputTokens", l.Usage.Input+l.Usage.CacheRead+l.Usage.CacheCreate, "outputTokens", l.Usage.Output, "costUsd", l.CostUSD, "durationMs", l.Duration)}
		if l.IsError || strings.HasPrefix(l.Subtype, "error") {
			msg := l.Result
			if msg == "" {
				msg = "执行出错：" + l.Subtype
			}
			out = append(out, ev(EvError, "message", msg))
		}
		if l.SessionID != "" {
			out = append(out, ev(EvSessionID, "id", l.SessionID))
		}
		return append(out, ev(EvTurnEnd))
	}
	return nil
}

/** streamEvent：处理增量事件 */
func (p *claudeParser) streamEvent(raw json.RawMessage) []Event {
	var e struct {
		Type    string `json:"type"`
		Index   int    `json:"index"`
		Message struct {
			ID string `json:"id"`
		} `json:"message"`
		Delta struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			Thinking string `json:"thinking"`
		} `json:"delta"`
	}
	if json.Unmarshal(raw, &e) != nil {
		return nil
	}
	switch e.Type {
	case "message_start":
		p.msgID = e.Message.ID
	case "content_block_delta":
		id := fmt.Sprintf("%s:%d", p.msgID, e.Index)
		switch e.Delta.Type {
		case "text_delta":
			p.noteStream(id, "text")
			return []Event{ev(EvDelta, "id", id, "text", e.Delta.Text)}
		case "thinking_delta":
			// 思考内容被隐藏时增量为空，不产生空白的思考块
			if e.Delta.Thinking == "" {
				return nil
			}
			p.noteStream(id, "thinking")
			return []Event{ev(EvThinking, "id", id, "text", e.Delta.Thinking, "delta", true)}
		}
	}
	return nil
}

/** assistant：处理完整的助手消息 */
func (p *claudeParser) assistant(raw json.RawMessage) []Event {
	var m struct {
		ID      string  `json:"id"`
		Content []block `json:"content"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	var out []Event
	for i, b := range m.Content {
		id := fmt.Sprintf("%s:%d", m.ID, i)
		if b.Type == "text" || b.Type == "thinking" {
			id = p.blockID(m.ID, b.Type, i)
		}
		switch b.Type {
		case "text":
			out = append(out, ev(EvDone, "id", id, "text", b.Text))
		case "thinking":
			if !p.streamed[id] && b.Thinking != "" {
				out = append(out, ev(EvThinking, "id", id, "text", b.Thinking))
			}
			if p.streamed[id] || b.Thinking != "" {
				out = append(out, ev(EvThinking, "id", id, "done", true))
			}
		case "tool_use":
			out = append(out, ev(EvToolStart, "id", b.ID, "name", b.Name, "kind", toolKind(b.Name), "summary", toolSummary(b.Name, b.Input), "input", b.Input))
			if writeTools[b.Name] {
				if fp, _ := b.Input["file_path"].(string); fp != "" {
					out = append(out, ev(EvFileWrite, "path", fp))
				} else if np, _ := b.Input["notebook_path"].(string); np != "" {
					out = append(out, ev(EvFileWrite, "path", np))
				}
			}
		}
		delete(p.streamed, id)
	}
	return out
}

/** toolResults：处理工具结果 */
func (p *claudeParser) toolResults(raw json.RawMessage) []Event {
	var m struct {
		Content json.RawMessage `json:"content"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return nil
	}
	var blocks []block
	if json.Unmarshal(m.Content, &blocks) != nil {
		return nil
	}
	var out []Event
	for _, b := range blocks {
		if b.Type == "tool_result" {
			out = append(out, ev(EvToolEnd, "id", b.ToolUseID, "output", Truncate(contentText(b.Content), 8000), "isError", b.IsError))
		}
	}
	return out
}

/** contentText：工具结果可能是字符串或内容块数组 */
func contentText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var parts []block
	if json.Unmarshal(raw, &parts) == nil {
		var b strings.Builder
		for _, x := range parts {
			if x.Type == "text" {
				if b.Len() > 0 {
					b.WriteByte('\n')
				}
				b.WriteString(x.Text)
			}
		}
		return b.String()
	}
	return string(raw)
}

/** toolKind：工具归类，手机端据此选图标 */
func toolKind(name string) string {
	switch name {
	case "Bash", "BashOutput", "KillShell", "KillBash":
		return "command"
	case "Read", "NotebookRead":
		return "read"
	case "Write", "Edit", "MultiEdit", "NotebookEdit":
		return "edit"
	case "Grep", "Glob", "LS":
		return "search"
	case "WebFetch", "WebSearch":
		return "web"
	}
	return "other"
}

/** toolSummary：工具调用的一行摘要 */
func toolSummary(name string, in map[string]any) string {
	str := func(k string) string { s, _ := in[k].(string); return s }
	switch name {
	case "Bash":
		return str("command")
	case "Read", "Write", "Edit", "MultiEdit":
		return name + " " + str("file_path")
	case "NotebookEdit", "NotebookRead":
		return name + " " + str("notebook_path")
	case "Grep", "Glob":
		return name + " " + str("pattern")
	case "WebFetch":
		return "WebFetch " + str("url")
	case "WebSearch":
		return "WebSearch " + str("query")
	}
	return name
}

/** Truncate：按字节截断并补省略号，保证不切断 UTF-8 */
func Truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && (s[n]&0xC0) == 0x80 {
		n--
	}
	return s[:n] + "…"
}
