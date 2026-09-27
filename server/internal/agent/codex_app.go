/**
 * Codex app-server 驱动（JSON-RPC over stdio，IDE 插件使用的接口）：常驻进程、逐条审批命令与改动、线程续聊。
 */
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

/** codexApp：一个 app-server 线程 */
type codexApp struct {
	*rpcConn
	opt      Options
	mu       sync.Mutex
	threadID string
	turnID   string
	items    map[string]codexAppItem
	streamed map[string]bool
	output   map[string]*strings.Builder
	base     codexTokens
	total    codexTokens
}

/** codexAppItem：线程中的一个条目，只取用到的字段 */
type codexAppItem struct {
	Type             string `json:"type"`
	ID               string `json:"id"`
	Text             string `json:"text"`
	Command          string `json:"command"`
	Cwd              string `json:"cwd"`
	Status           string `json:"status"`
	AggregatedOutput string `json:"aggregatedOutput"`
	ExitCode         *int   `json:"exitCode"`
	CommandActions   []struct {
		Command string `json:"command"`
	} `json:"commandActions"`
	Changes []struct {
		Path string `json:"path"`
		Diff string `json:"diff"`
	} `json:"changes"`
	Summary []string `json:"summary"`
	Content []string `json:"content"`
	Server  string   `json:"server"`
	Tool    string   `json:"tool"`
	Query   string   `json:"query"`
	Message string   `json:"message"`
}

/** codexTokens：线程累计用量 */
type codexTokens struct {
	InputTokens  int64 `json:"inputTokens"`
	OutputTokens int64 `json:"outputTokens"`
}

/** threadParams：新建与恢复线程共用的参数；untrusted 表示除只读命令外都要审批，免审批时不审批也不进沙箱 */
func (c *codexApp) threadParams() map[string]any {
	p := map[string]any{"cwd": c.opt.Cwd, "approvalPolicy": "untrusted", "sandbox": "workspace-write"}
	if c.opt.AutoApprove {
		p["approvalPolicy"], p["sandbox"] = "never", "danger-full-access"
	}
	if c.opt.Model != "" {
		p["model"] = c.opt.Model
	}
	return p
}

/**
 * startCodexApp：启动 app-server 并完成握手
 *
 * 处理流程：
 * 1、启动进程，按消息类型分发
 * 2、initialize + initialized
 * 3、有线程 ID 时 thread/resume，失败或没有时 thread/start
 */
func startCodexApp(ctx context.Context, opt Options) (*codexApp, error) {
	c := &codexApp{rpcConn: newRPCConn(), opt: opt, items: map[string]codexAppItem{}, streamed: map[string]bool{}, output: map[string]*strings.Builder{}}
	// 1、启动
	argv := append(append([]string{}, opt.Command...), "app-server")
	p, err := startLineProc(argv, opt.Cwd, append(EnvPath(), opt.Env...), func(lp *lineProc, line []byte) {
		c.dispatch(line)
	})
	if err != nil {
		return nil, err
	}
	c.attach(p)
	hctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	// 2、握手
	if err := c.call(hctx, "initialize", map[string]any{"clientInfo": map[string]string{"name": "pocketdesk", "version": "1.0.0"}}, nil); err != nil {
		p.Close()
		return nil, fmt.Errorf("握手失败: %w", err)
	}
	c.notify("initialized", nil)
	// 3、线程
	var res struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
		Model string `json:"model"`
	}
	resumed := false
	if opt.ResumeID != "" {
		params := c.threadParams()
		params["threadId"] = opt.ResumeID
		resumed = c.call(hctx, "thread/resume", params, &res) == nil && res.Thread.ID != ""
	}
	if !resumed {
		if err := c.call(hctx, "thread/start", c.threadParams(), &res); err != nil {
			p.Close()
			return nil, fmt.Errorf("创建会话失败: %w", err)
		}
	}
	c.threadID = res.Thread.ID
	p.emit(ev(EvSessionID, "id", c.threadID, "model", res.Model))
	return c, nil
}

/**
 * dispatch：分发一行消息
 *
 * 处理流程：
 * 1、响应：交给等待中的请求
 * 2、对方请求：命令与改动审批，其他返回未实现
 * 3、通知：翻译为统一事件
 */
func (c *codexApp) dispatch(line []byte) {
	var m rpcMsg
	if json.Unmarshal(line, &m) != nil {
		return
	}
	switch {
	case m.ID != nil && m.Method == "":
		c.resolve(m)
	case m.ID != nil:
		go c.handleRequest(m)
	default:
		for _, e := range c.notification(m.Method, m.Params) {
			c.emit(e)
		}
	}
}

/**
 * handleRequest：命令执行与文件改动的审批
 *
 * 处理流程：
 * 1、按条目 ID 取出之前记下的命令或改动文件，组装审批内容
 * 2、阻塞等待手机上的决定
 * 3、映射为 accept / acceptForSession / decline
 */
func (c *codexApp) handleRequest(m rpcMsg) {
	var p struct {
		ItemID  string `json:"itemId"`
		Command string `json:"command"`
		Cwd     string `json:"cwd"`
		Reason  string `json:"reason"`
	}
	json.Unmarshal(m.Params, &p)
	// 1、审批内容
	var req ApprovalRequest
	c.mu.Lock()
	it := c.items[p.ItemID]
	c.mu.Unlock()
	switch m.Method {
	case "item/commandExecution/requestApproval":
		if p.Command == "" {
			p.Command = it.Command
		}
		cmd := codexCommand(p.Command, it)
		req = ApprovalRequest{Tool: "Shell", Kind: "command", Summary: cmd, Input: map[string]any{"command": cmd, "cwd": p.Cwd, "reason": p.Reason}}
	case "item/fileChange/requestApproval":
		paths := codexPaths(it, c.opt.Cwd)
		req = ApprovalRequest{Tool: "Edit", Kind: "edit", Summary: strings.Join(paths, ", "), Input: map[string]any{"paths": paths, "reason": p.Reason}}
	default:
		c.reply(m.ID, nil, &rpcError{Code: -32601, Message: "method not found"})
		return
	}
	if c.opt.Approver == nil {
		c.reply(m.ID, map[string]string{"decision": "decline"}, nil)
		return
	}
	// 2、等待决定
	d, err := c.opt.Approver.RequestApproval(context.Background(), req)
	// 3、映射
	decision := "decline"
	if err == nil && d.Allow {
		decision = "accept"
		if d.Always {
			decision = "acceptForSession"
		}
	}
	c.reply(m.ID, map[string]string{"decision": decision}, nil)
}

/**
 * notification：翻译通知
 *
 * 处理流程：
 * 1、回复文字与思考的流式片段
 * 2、条目开始：工具开始，记下命令与改动供审批使用
 * 3、条目完成：回复收尾、思考收尾、工具结束与改动记录
 * 4、用量、错误与本轮结束
 */
func (c *codexApp) notification(method string, raw json.RawMessage) []Event {
	var p struct {
		ItemID     string       `json:"itemId"`
		Delta      string       `json:"delta"`
		Item       codexAppItem `json:"item"`
		WillRetry  bool         `json:"willRetry"`
		TokenUsage struct {
			Total codexTokens `json:"total"`
		} `json:"tokenUsage"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
		Turn struct {
			ID     string `json:"id"`
			Status string `json:"status"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		} `json:"turn"`
	}
	if json.Unmarshal(raw, &p) != nil {
		return nil
	}
	it := p.Item
	switch method {
	// 1、流式片段
	case "item/agentMessage/delta":
		c.mu.Lock()
		c.streamed[p.ItemID] = true
		c.mu.Unlock()
		return []Event{ev(EvDelta, "id", p.ItemID, "text", p.Delta)}
	case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
		c.mu.Lock()
		c.streamed[p.ItemID] = true
		c.mu.Unlock()
		return []Event{ev(EvThinking, "id", p.ItemID, "text", p.Delta, "delta", true)}
	case "item/commandExecution/outputDelta":
		c.mu.Lock()
		b := c.output[p.ItemID]
		if b == nil {
			b = &strings.Builder{}
			c.output[p.ItemID] = b
		}
		if b.Len() < 64<<10 {
			b.WriteString(p.Delta)
		}
		c.mu.Unlock()
	// 2、条目开始
	case "item/started":
		c.mu.Lock()
		c.items[it.ID] = it
		c.mu.Unlock()
		switch it.Type {
		case "commandExecution":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "Shell", "kind", "command", "summary", codexCommand(it.Command, it), "input", map[string]any{"command": codexCommand(it.Command, it)})}
		case "fileChange":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "Edit", "kind", "edit", "summary", strings.Join(codexPaths(it, c.opt.Cwd), ", "))}
		case "mcpToolCall":
			return []Event{ev(EvToolStart, "id", it.ID, "name", it.Server+"."+it.Tool, "kind", "other", "summary", it.Server+"."+it.Tool)}
		case "webSearch":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "WebSearch", "kind", "web", "summary", it.Query)}
		}
	// 3、条目完成
	case "item/completed":
		return c.completed(it)
	// 4、用量、错误、结束
	case "turn/started":
		c.mu.Lock()
		c.turnID = p.Turn.ID
		c.base = c.total
		c.mu.Unlock()
	case "thread/tokenUsage/updated":
		c.mu.Lock()
		c.total = p.TokenUsage.Total
		c.mu.Unlock()
	case "error":
		if !p.WillRetry && p.Error.Message != "" {
			return []Event{ev(EvError, "message", p.Error.Message)}
		}
	case "turn/completed":
		c.mu.Lock()
		in, out := c.total.InputTokens-c.base.InputTokens, c.total.OutputTokens-c.base.OutputTokens
		c.turnID = ""
		c.items = map[string]codexAppItem{}
		c.streamed = map[string]bool{}
		c.output = map[string]*strings.Builder{}
		c.mu.Unlock()
		evs := []Event{ev(EvUsage, "inputTokens", in, "outputTokens", out)}
		if p.Turn.Status == "failed" && p.Turn.Error != nil {
			evs = append(evs, ev(EvError, "message", p.Turn.Error.Message))
		}
		return append(evs, ev(EvTurnEnd, "stopReason", p.Turn.Status))
	}
	return nil
}

/** completed：条目完成时的事件 */
func (c *codexApp) completed(it codexAppItem) []Event {
	c.mu.Lock()
	streamed := c.streamed[it.ID]
	var buffered string
	if b := c.output[it.ID]; b != nil {
		buffered = b.String()
	}
	c.mu.Unlock()
	switch it.Type {
	case "agentMessage":
		return []Event{ev(EvDone, "id", it.ID, "text", it.Text)}
	case "reasoning":
		var out []Event
		if text := strings.TrimSpace(strings.Join(append(it.Summary, it.Content...), "\n")); !streamed && text != "" {
			out = append(out, ev(EvThinking, "id", it.ID, "text", text))
		}
		return append(out, ev(EvThinking, "id", it.ID, "done", true))
	case "commandExecution":
		output := it.AggregatedOutput
		if output == "" {
			output = buffered
		}
		failed := it.Status == "failed" || it.Status == "declined" || (it.ExitCode != nil && *it.ExitCode != 0)
		return []Event{ev(EvToolEnd, "id", it.ID, "output", Truncate(output, 8000), "isError", failed)}
	case "fileChange":
		out := []Event{ev(EvToolEnd, "id", it.ID, "output", strings.Join(codexPaths(it, c.opt.Cwd), ", "), "isError", it.Status != "completed")}
		if it.Status == "completed" {
			for _, ch := range it.Changes {
				out = append(out, ev(EvFileWrite, "path", ch.Path))
			}
		}
		return out
	case "mcpToolCall", "webSearch":
		return []Event{ev(EvToolEnd, "id", it.ID, "isError", it.Status == "failed")}
	case "error":
		return []Event{ev(EvError, "message", it.Message)}
	}
	return nil
}

/** Send：发起一轮 turn/start，结束由 turn/completed 通知 */
func (c *codexApp) Send(ctx context.Context, m Message) error {
	c.mu.Lock()
	tid := c.threadID
	c.mu.Unlock()
	cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	var res struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	params := map[string]any{"threadId": tid, "input": []map[string]any{{"type": "text", "text": PromptWithAttachments(m)}}}
	if err := c.call(cctx, "turn/start", params, &res); err != nil {
		return err
	}
	c.mu.Lock()
	if c.turnID == "" {
		c.turnID = res.Turn.ID
	}
	c.mu.Unlock()
	return nil
}

/** Steer：按驱动约定不插话，执行中的消息排队到本轮结束 */
func (c *codexApp) Steer(context.Context, Message) error { return ErrUnsupported }

/** Interrupt：turn/interrupt */
func (c *codexApp) Interrupt() error {
	c.mu.Lock()
	tid, turn := c.threadID, c.turnID
	c.mu.Unlock()
	if turn == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return c.call(ctx, "turn/interrupt", map[string]any{"threadId": tid, "turnId": turn}, nil)
}

/** shellWrap：app-server 给出的命令外面包着一层登录 shell */
var shellWrap = regexp.MustCompile(`^/bin/(?:ba|z)?sh -lc '(.*)'$`)

/** codexCommand：展示用命令，优先取解析后的动作，其次去掉 shell 外壳 */
func codexCommand(raw string, it codexAppItem) string {
	var acts []string
	for _, a := range it.CommandActions {
		if a.Command != "" {
			acts = append(acts, a.Command)
		}
	}
	if len(acts) > 0 {
		return strings.Join(acts, " && ")
	}
	if m := shellWrap.FindStringSubmatch(raw); m != nil {
		return strings.ReplaceAll(m[1], `'\''`, `'`)
	}
	return raw
}

/** codexPaths：改动文件，工作目录内的显示为相对路径（工作目录经过符号链接时两种写法都认） */
func codexPaths(it codexAppItem, cwd string) []string {
	var roots []string
	if cwd != "" {
		roots = append(roots, cwd)
		if real, err := filepath.EvalSymlinks(cwd); err == nil && real != cwd {
			roots = append(roots, real)
		}
	}
	var out []string
	for _, ch := range it.Changes {
		p := ch.Path
		for _, r := range roots {
			if rel, err := filepath.Rel(r, p); err == nil && !strings.HasPrefix(rel, "..") && !filepath.IsAbs(rel) {
				p = filepath.ToSlash(rel)
				break
			}
		}
		out = append(out, p)
	}
	return out
}
