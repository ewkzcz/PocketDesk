/**
 * Codex 驱动：优先用 app-server（可逐条审批）；不可用时退回 exec --json，每轮运行一次，靠线程 ID 续聊，沙箱限制为工作区可写。
 */
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"
)

/** CodexDriver：Codex 接入 */
type CodexDriver struct{}

/** Kind：类型 */
func (CodexDriver) Kind() string { return KindCodex }

/** SupportsSteer：不支持插话 */
func (CodexDriver) SupportsSteer() bool { return false }

/**
 * Start：启动会话
 *
 * 处理流程：
 * 1、确认命令存在
 * 2、优先启动 app-server 常驻进程
 * 3、app-server 不可用（旧版本）时退回 exec 模式：只保存参数，每次发送消息时再启动子进程
 */
func (CodexDriver) Start(ctx context.Context, opt Options) (Process, error) {
	// 1、命令
	if len(opt.Command) == 0 {
		opt.Command = []string{"codex"}
	}
	if _, err := LookPath(opt.Command[0]); err != nil {
		return nil, fmt.Errorf("找不到 %s，请确认已安装", opt.Command[0])
	}
	// 2、app-server
	app, err := startCodexApp(ctx, opt)
	if err == nil {
		return app, nil
	}
	slog.Warn("Codex app-server 不可用，改用 exec 模式", "err", err)
	// 3、exec
	return &codexProc{opt: opt, threadID: opt.ResumeID, events: make(chan Event, 256), done: make(chan struct{})}, nil
}

/**
 * CodexArgs：组装一轮的参数
 *
 * 处理流程：
 * 1、exec --json，跳过 git 检查，沙箱为工作区可写
 * 2、按需追加模型
 * 3、有线程 ID 时走 resume 子命令
 * 4、提示词从标准输入读取
 */
func CodexArgs(opt Options, threadID string) []string {
	// 1、基础
	args := append([]string{}, opt.Command...)
	args = append(args, "exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write")
	// 2、模型
	if opt.Model != "" {
		args = append(args, "--model", opt.Model)
	}
	// 3、续聊
	if threadID != "" {
		args = append(args, "resume", threadID)
	}
	// 4、标准输入
	return append(args, "-")
}

/** codexProc：跨多轮的 Codex 会话 */
type codexProc struct {
	opt      Options
	mu       sync.Mutex
	threadID string
	cur      *lineProc
	curEnded bool
	events   chan Event
	done     chan struct{}
	closed   bool
	once     sync.Once
}

/**
 * Send：启动一轮
 *
 * 处理流程：
 * 1、同一时间只允许一轮
 * 2、启动子进程并写入提示词
 * 3、转发解析后的事件，子进程结束时补齐结束事件
 */
func (c *codexProc) Send(_ context.Context, m Message) error {
	// 1、互斥：上一轮已发出结束事件时，等待其进程退出后再开始
	c.mu.Lock()
	if c.cur != nil && c.curEnded {
		prev := c.cur
		c.mu.Unlock()
		select {
		case <-prev.Done():
		case <-time.After(5 * time.Second):
			prev.Close()
			<-prev.Done()
		}
		// 等待收尾协程清空当前轮，结束时保持持锁
		for i := 0; ; i++ {
			c.mu.Lock()
			if c.cur != prev || i >= 100 {
				break
			}
			c.mu.Unlock()
			time.Sleep(5 * time.Millisecond)
		}
	}
	if c.closed {
		c.mu.Unlock()
		return errors.New("会话已关闭")
	}
	if c.cur != nil {
		c.mu.Unlock()
		return errors.New("上一轮尚未结束")
	}
	// 2、启动
	parser := &codexParser{}
	lp, err := startLineProc(CodexArgs(c.opt, c.threadID), c.opt.Cwd, append(EnvPath(), c.opt.Env...), func(lp *lineProc, line []byte) {
		for _, e := range parser.parse(line) {
			if e.Type == EvSessionID {
				c.mu.Lock()
				c.threadID, _ = e.Data["id"].(string)
				c.mu.Unlock()
			}
			if e.Type == EvTurnEnd {
				c.mu.Lock()
				c.curEnded = true
				c.mu.Unlock()
			}
			c.forward(e)
		}
	})
	if err != nil {
		c.mu.Unlock()
		return err
	}
	c.cur = lp
	c.curEnded = false
	c.mu.Unlock()
	if err := lp.writeJSONRaw(PromptWithAttachments(m)); err != nil {
		lp.Close()
	}
	lp.stdin.Close()
	// 3、收尾
	go func() {
		for range lp.Events() {
		}
		<-lp.Done()
		// 先清空当前轮，再补发结束事件，保证收到结束事件后可以立即开始下一轮
		c.mu.Lock()
		c.cur = nil
		c.mu.Unlock()
		if !parser.ended {
			if err := lp.Err(); err != nil {
				c.forward(ev(EvError, "message", "进程异常退出："+err.Error()))
			}
			c.forward(ev(EvTurnEnd))
		}
	}()
	return nil
}

/** forward：转发事件，会话关闭后丢弃 */
func (c *codexProc) forward(e Event) {
	select {
	case <-c.done:
	case c.events <- e:
	}
}

/** Steer：不支持 */
func (c *codexProc) Steer(context.Context, Message) error { return ErrUnsupported }

/** Interrupt：向当前子进程发中断信号 */
func (c *codexProc) Interrupt() error {
	c.mu.Lock()
	cur := c.cur
	c.mu.Unlock()
	if cur == nil {
		return nil
	}
	return cur.signalInterrupt()
}

/** Events：事件通道 */
func (c *codexProc) Events() <-chan Event { return c.events }

/** Done：会话关闭信号 */
func (c *codexProc) Done() <-chan struct{} { return c.done }

/** Err：多轮模式没有常驻进程错误 */
func (c *codexProc) Err() error { return nil }

/** Close：结束当前轮并关闭会话 */
func (c *codexProc) Close() error {
	c.once.Do(func() {
		c.mu.Lock()
		c.closed = true
		cur := c.cur
		c.mu.Unlock()
		if cur != nil {
			cur.Close()
		}
		close(c.done)
	})
	return nil
}

/** writeJSONRaw：写入原始文本（不做 JSON 编码） */
func (p *lineProc) writeJSONRaw(s string) error {
	p.wmu.Lock()
	defer p.wmu.Unlock()
	_, err := p.stdin.Write([]byte(s))
	return err
}

/** codexParser：解析 exec --json 输出 */
type codexParser struct {
	ended bool
}

/** codexItem：exec 输出中的条目 */
type codexItem struct {
	ID               string `json:"id"`
	Type             string `json:"type"`
	Text             string `json:"text"`
	Command          string `json:"command"`
	AggregatedOutput string `json:"aggregated_output"`
	ExitCode         *int   `json:"exit_code"`
	Status           string `json:"status"`
	Server           string `json:"server"`
	Tool             string `json:"tool"`
	Query            string `json:"query"`
	Message          string `json:"message"`
	Changes          []struct {
		Path string `json:"path"`
		Kind string `json:"kind"`
	} `json:"changes"`
}

/**
 * parse：解析一行
 *
 * 处理流程：
 * 1、thread.started 取线程 ID
 * 2、item.started 产生工具开始
 * 3、item.completed 产生回复、思考、工具结束与改动记录
 * 4、turn.completed / turn.failed 产生用量、错误并结束本轮
 */
func (p *codexParser) parse(line []byte) []Event {
	var l struct {
		Type     string    `json:"type"`
		ThreadID string    `json:"thread_id"`
		Item     codexItem `json:"item"`
		Message  string    `json:"message"`
		Usage    struct {
			Input  int64 `json:"input_tokens"`
			Cached int64 `json:"cached_input_tokens"`
			Output int64 `json:"output_tokens"`
		} `json:"usage"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(line, &l) != nil {
		return nil
	}
	it := l.Item
	switch l.Type {
	// 1、线程
	case "thread.started":
		return []Event{ev(EvSessionID, "id", l.ThreadID)}
	// 2、开始
	case "item.started":
		switch it.Type {
		case "command_execution":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "Shell", "kind", "command", "summary", it.Command)}
		case "file_change":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "Edit", "kind", "edit", "summary", changePaths(it))}
		case "mcp_tool_call":
			return []Event{ev(EvToolStart, "id", it.ID, "name", it.Server+"."+it.Tool, "kind", "other", "summary", it.Server+"."+it.Tool)}
		case "web_search":
			return []Event{ev(EvToolStart, "id", it.ID, "name", "WebSearch", "kind", "web", "summary", it.Query)}
		}
	// 3、完成
	case "item.completed":
		switch it.Type {
		case "agent_message":
			return []Event{ev(EvDone, "id", it.ID, "text", it.Text)}
		case "reasoning":
			return []Event{ev(EvThinking, "id", it.ID, "text", it.Text), ev(EvThinking, "id", it.ID, "done", true)}
		case "command_execution":
			failed := it.Status == "failed" || (it.ExitCode != nil && *it.ExitCode != 0)
			return []Event{ev(EvToolEnd, "id", it.ID, "output", Truncate(it.AggregatedOutput, 8000), "isError", failed)}
		case "file_change":
			out := []Event{ev(EvToolEnd, "id", it.ID, "output", changePaths(it), "isError", it.Status == "failed")}
			for _, c := range it.Changes {
				out = append(out, ev(EvFileWrite, "path", c.Path))
			}
			return out
		case "mcp_tool_call", "web_search":
			return []Event{ev(EvToolEnd, "id", it.ID, "isError", it.Status == "failed")}
		case "error":
			return []Event{ev(EvError, "message", it.Message)}
		}
	// 4、结束
	case "turn.completed":
		p.ended = true
		return []Event{ev(EvUsage, "inputTokens", l.Usage.Input, "outputTokens", l.Usage.Output), ev(EvTurnEnd)}
	case "turn.failed":
		p.ended = true
		return []Event{ev(EvError, "message", l.Error.Message), ev(EvTurnEnd)}
	case "error":
		return []Event{ev(EvError, "message", l.Message)}
	}
	return nil
}

/** changePaths：改动文件列表摘要 */
func changePaths(it codexItem) string {
	var ps []string
	for _, c := range it.Changes {
		ps = append(ps, c.Path)
	}
	return strings.Join(ps, ", ")
}
