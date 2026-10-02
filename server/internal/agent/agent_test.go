/**
 * Agent 驱动端到端 mock 测试：通过假进程验证事件翻译、续聊、中断、审批与异常退出。
 */
package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

/** fakeOpts：以测试二进制作为 Agent 命令 */
func fakeOpts(t *testing.T, name string) Options {
	return Options{Cwd: t.TempDir(), Command: []string{os.Args[0]}, Env: []string{"GO_FAKE_AGENT=" + name}}
}

/** collect：收集事件直到本轮结束 */
func collect(t *testing.T, p Process) []Event {
	t.Helper()
	var evs []Event
	timeout := time.After(10 * time.Second)
	for {
		select {
		case e, ok := <-p.Events():
			if !ok {
				return evs
			}
			evs = append(evs, e)
			if e.Type == EvTurnEnd {
				return evs
			}
		case <-timeout:
			t.Fatalf("等待本轮结束超时，已收到 %v", types(evs))
		}
	}
}

/** types：事件类型列表 */
func types(evs []Event) []string {
	var s []string
	for _, e := range evs {
		s = append(s, e.Type)
	}
	return s
}

/** find：找第一个某类型事件 */
func find(evs []Event, typ string) (Event, bool) {
	for _, e := range evs {
		if e.Type == typ {
			return e, true
		}
	}
	return Event{}, false
}

func TestClaudeDriverTurn(t *testing.T) {
	opt := fakeOpts(t, "claude")
	opt.ResumeID = "old-sess"
	opt.Model = "m"
	p, err := ClaudeDriver{}.Start(context.Background(), opt)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "hello", Attachments: []string{".pocketdesk/inbox/20261001/a.png"}})
	evs := collect(t, p)
	got := strings.Join(types(evs), ",")
	want := "agent.session,msg.delta,msg.delta,msg.done,tool.start,file.write,tool.end,usage,agent.session,turn.end"
	if got != want {
		t.Fatalf("事件序列\n得到 %s\n期望 %s", got, want)
	}
	if evs[0].Data["id"] != "old-sess" {
		t.Fatal("续聊参数未传递")
	}
	done, _ := find(evs, EvDone)
	if done.Data["text"] != "你好" || done.Data["id"] != "m1:0" {
		t.Fatalf("完整消息 %+v", done.Data)
	}
	end, _ := find(evs, EvToolEnd)
	if end.Data["output"] != "ok" {
		t.Fatal("工具输出解析失败")
	}
}

func TestClaudeInterrupt(t *testing.T) {
	p, err := ClaudeDriver{}.Start(context.Background(), fakeOpts(t, "claude"))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "slow task"})
	time.Sleep(100 * time.Millisecond)
	p.Interrupt()
	evs := collect(t, p)
	if e, ok := find(evs, EvError); !ok || e.Data["message"] != "已中断" {
		t.Fatalf("中断后应报错并结束本轮: %v", types(evs))
	}
}

func TestClaudeArgsWithApproval(t *testing.T) {
	args := ClaudeArgs(Options{Command: []string{"claude"}, ApproveCmd: []string{"/bin/pd", "mcp-approve", "--session", "s1"}})
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "--permission-prompt-tool mcp__pocketdesk__approve") || !strings.Contains(joined, `"command":"/bin/pd"`) {
		t.Fatalf("审批参数缺失: %s", joined)
	}
	if strings.Contains(joined, "dangerously") {
		t.Fatal("不得默认跳过确认")
	}
}

func TestCodexDriverResumeAndFailure(t *testing.T) {
	p, err := CodexDriver{}.Start(context.Background(), fakeOpts(t, "codex"))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "list"})
	evs := collect(t, p)
	if strings.Join(types(evs), ",") != "agent.session,tool.start,tool.end,tool.end,file.write,msg.done,usage,turn.end" {
		t.Fatalf("事件序列 %v", types(evs))
	}
	if d, _ := find(evs, EvDone); d.Data["text"] != "echo:list" {
		t.Fatalf("提示词未经标准输入传递 %+v", d.Data)
	}
	p.Send(context.Background(), Message{Text: "fail please"})
	evs = collect(t, p)
	if e, ok := find(evs, EvError); !ok || e.Data["message"] != "模型错误" {
		t.Fatalf("失败轮 %v", types(evs))
	}
	if args := CodexArgs(Options{Command: []string{"codex"}}, "thread-1"); !strings.Contains(strings.Join(args, " "), "resume thread-1 -") {
		t.Fatalf("续聊参数 %v", args)
	}
}

func TestCodexInterruptEndsTurn(t *testing.T) {
	p, _ := CodexDriver{}.Start(context.Background(), fakeOpts(t, "codex"))
	defer p.Close()
	p.Send(context.Background(), Message{Text: "slow"})
	if err := p.Send(context.Background(), Message{Text: "again"}); err == nil {
		t.Fatal("上一轮未结束时应拒绝")
	}
	time.Sleep(200 * time.Millisecond)
	p.Interrupt()
	evs := collect(t, p)
	if _, ok := find(evs, EvTurnEnd); !ok {
		t.Fatal("中断后应结束本轮")
	}
}

func TestPiDriverEvents(t *testing.T) {
	p, err := PiDriver{}.Start(context.Background(), fakeOpts(t, "pi"))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "go"})
	evs := collect(t, p)
	if s, _ := find(evs, EvSessionID); s.Data["id"] != "/tmp/pi.jsonl" {
		t.Fatal("未取得会话文件")
	}
	if _, ok := find(evs, EvFileWrite); !ok {
		t.Fatal("写文件记录缺失")
	}
}

/** fakeApprover：记录审批请求并返回预设结果 */
type fakeApprover struct {
	mu   sync.Mutex
	reqs []ApprovalRequest
	d    Decision
}

func (f *fakeApprover) RequestApproval(_ context.Context, r ApprovalRequest) (Decision, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reqs = append(f.reqs, r)
	return f.d, nil
}

func TestACPDriverApproval(t *testing.T) {
	ap := &fakeApprover{d: Decision{Allow: true, Always: true}}
	opt := fakeOpts(t, "acp")
	opt.Approver = ap
	p, err := ACPDriver{Name: KindDSH}.Start(context.Background(), opt)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "clean"})
	evs := collect(t, p)
	if len(ap.reqs) != 1 || ap.reqs[0].Kind != "command" || ap.reqs[0].Summary != "rm -rf tmp" || ap.reqs[0].Input["command"] != "rm -rf tmp" {
		t.Fatalf("审批请求应按编号补全命令 %+v", ap.reqs)
	}
	if st, _ := find(evs, EvToolStart); st.Data["kind"] != "command" || st.Data["summary"] != "rm -rf tmp" {
		t.Fatalf("工具开始应识别为执行命令 %+v", st.Data)
	}
	end, _ := find(evs, EvToolEnd)
	if end.Data["output"] != "always" {
		t.Fatalf("总是允许应选择 allow_always，实际 %v", end.Data["output"])
	}
	var dones []string
	for _, e := range evs {
		if e.Type == EvDone {
			dones = append(dones, e.Data["text"].(string))
		}
	}
	if strings.Join(dones, "|") != "先看看|完成" {
		t.Fatalf("文本分段收尾 %v", dones)
	}
	// 工具前后的思考各成一段；编号带进程标识，重启后不会与以前的消息重复
	thinks := map[string]bool{}
	var firstDone string
	for _, e := range evs {
		if e.Type == EvThinking && e.Data["delta"] == true {
			thinks[e.Data["id"].(string)] = true
		}
		if e.Type == EvDone && firstDone == "" {
			firstDone = e.Data["id"].(string)
		}
	}
	if len(thinks) != 2 {
		t.Fatalf("思考应按工具调用分段 %v", thinks)
	}
	time.Sleep(2 * time.Millisecond)
	p2, err := ACPDriver{Name: KindDSH}.Start(context.Background(), opt)
	if err != nil {
		t.Fatal(err)
	}
	defer p2.Close()
	p2.Send(context.Background(), Message{Text: "clean"})
	if d, _ := find(collect(t, p2), EvDone); d.Data["id"] == firstDone {
		t.Fatalf("重启后的消息编号不应重复 %v", firstDone)
	}
}

func TestACPResumeSuppressesReplay(t *testing.T) {
	opt := fakeOpts(t, "acp")
	opt.ResumeID = "acp-old"
	p, err := ACPDriver{Name: KindDSH}.Start(context.Background(), opt)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	e := <-p.Events()
	if e.Type != EvSessionID || e.Data["id"] != "acp-old" {
		t.Fatalf("加载旧会话后第一条应为会话 ID，实际 %+v", e)
	}
}

func TestACPInterrupt(t *testing.T) {
	block := make(chan struct{})
	ap := approverFunc(func() Decision { <-block; return Decision{} })
	opt := fakeOpts(t, "acp")
	opt.Approver = ap
	p, _ := ACPDriver{Name: KindDSH}.Start(context.Background(), opt)
	defer p.Close()
	p.Send(context.Background(), Message{Text: "x"})
	time.Sleep(200 * time.Millisecond)
	p.Interrupt()
	evs := collect(t, p)
	close(block)
	if e, _ := find(evs, EvTurnEnd); e.Data["stopReason"] != "cancelled" {
		t.Fatalf("取消原因 %+v", e.Data)
	}
}

/** approverFunc：函数式审批 */
type approverFunc func() Decision

func (f approverFunc) RequestApproval(context.Context, ApprovalRequest) (Decision, error) {
	return f(), nil
}

func TestProcessCrashReportsStderr(t *testing.T) {
	p, err := ClaudeDriver{}.Start(context.Background(), fakeOpts(t, "crash"))
	if err != nil {
		t.Fatal(err)
	}
	<-p.Done()
	if p.Err() == nil || !strings.Contains(p.Err().Error(), "fatal: boom") {
		t.Fatalf("应带上标准错误尾部: %v", p.Err())
	}
}

func TestMissingBinary(t *testing.T) {
	_, err := ClaudeDriver{}.Start(context.Background(), Options{Command: []string{"pd-no-such-binary-xyz"}})
	if err == nil || !strings.Contains(err.Error(), "找不到") {
		t.Fatalf("缺少命令应友好报错: %v", err)
	}
	if _, err := (CodexDriver{}).Start(context.Background(), Options{Command: []string{"pd-no-such-binary-xyz"}}); err == nil {
		t.Fatal("Codex 缺少命令应报错")
	}
}

func TestApprovalMCPServer(t *testing.T) {
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"ls"}}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"bogus"}`,
	}, "\n") + "\n"
	var buf bytes.Buffer
	var mu sync.Mutex
	w := writerFunc(func(b []byte) (int, error) { mu.Lock(); defer mu.Unlock(); return buf.Write(b) })
	err := ServeApprovalMCP(context.Background(), strings.NewReader(in), w, func(_ context.Context, tool string, input map[string]any) (map[string]any, error) {
		if tool != "Bash" || input["command"] != "ls" {
			t.Errorf("参数 %s %v", tool, input)
		}
		return ClaudeBehavior(Decision{Allow: true}, input), nil
	})
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 4 {
		t.Fatalf("应答数 %d: %s", len(lines), buf.String())
	}
	byID := map[string]map[string]any{}
	for _, l := range lines {
		var m map[string]any
		json.Unmarshal([]byte(l), &m)
		byID[string(mustJSON(m["id"]))] = m
	}
	if byID["1"]["result"].(map[string]any)["protocolVersion"] != "2025-06-18" {
		t.Fatal("协议版本应回显")
	}
	text := byID["3"]["result"].(map[string]any)["content"].([]any)[0].(map[string]any)["text"].(string)
	if !strings.Contains(text, `"behavior":"allow"`) || !strings.Contains(text, `"updatedInput"`) {
		t.Fatalf("审批结果 %s", text)
	}
	if byID["4"]["error"] == nil {
		t.Fatal("未知方法应报错")
	}
	if d := ClaudeBehavior(Decision{}, nil); d["behavior"] != "deny" || d["message"] == "" {
		t.Fatal("拒绝结果格式")
	}
}

/** writerFunc：函数式写入器 */
type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(b []byte) (int, error) { return f(b) }

/** mustJSON：序列化 */
func mustJSON(v any) []byte { b, _ := json.Marshal(v); return b }

func TestTruncateAndLabels(t *testing.T) {
	if Truncate("中文字符", 4) != "中…" {
		t.Fatalf("截断 %q", Truncate("中文字符", 4))
	}
	if Label(KindCodex) != "Codex" || Short(KindDSH) != "DS" || Label("terminal") != "终端" {
		t.Fatal("名称映射")
	}
	r := NewRegistry(ClaudeDriver{}, PiDriver{})
	if _, ok := r.Get(KindPi); !ok || len(r.List()) != 2 {
		t.Fatal("注册表")
	}
	if PromptWithAttachments(Message{Text: "看图", Attachments: []string{"a.png"}}) != "看图\n\n附件：\n- a.png" {
		t.Fatal("附件拼接")
	}
	_ = io.EOF
}

func TestDetect(t *testing.T) {
	list := Detect(map[string][]string{KindClaude: {"pd-no-such-binary-xyz"}, KindCodex: {os.Args[0]}})
	if len(list) != 4 || list[0].Installed || !list[1].Installed {
		t.Fatalf("探测结果 %+v", list)
	}
}

/** approverSeq：按顺序返回预设决定，并记录请求 */
type approverSeq struct {
	mu   sync.Mutex
	ds   []Decision
	reqs []ApprovalRequest
}

func (a *approverSeq) RequestApproval(_ context.Context, r ApprovalRequest) (Decision, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.reqs = append(a.reqs, r)
	d := a.ds[0]
	a.ds = a.ds[1:]
	return d, nil
}

func TestCodexAppApprovals(t *testing.T) {
	for _, tc := range []struct {
		name      string
		edit      Decision
		wantWrite bool
	}{{"允许改动", Decision{Allow: true}, true}, {"拒绝改动", Decision{}, false}} {
		t.Run(tc.name, func(t *testing.T) {
			ap := &approverSeq{ds: []Decision{{Allow: true, Always: true}, tc.edit}}
			opt := fakeOpts(t, "codexapp")
			opt.Approver = ap
			p, err := CodexDriver{}.Start(context.Background(), opt)
			if err != nil {
				t.Fatal(err)
			}
			defer p.Close()
			p.Send(context.Background(), Message{Text: "clean"})
			evs := collect(t, p)
			if s, _ := find(evs, EvSessionID); s.Data["id"] != "th-new" || s.Data["model"] != "gpt-x" {
				t.Fatalf("线程 %+v", s.Data)
			}
			// 审批请求按条目 ID 补全命令与改动文件
			if len(ap.reqs) != 2 || ap.reqs[0].Kind != "command" || ap.reqs[0].Summary != "rm -rf tmp" || ap.reqs[1].Kind != "edit" || ap.reqs[1].Summary != "b.txt" {
				t.Fatalf("审批请求 %+v", ap.reqs)
			}
			if st, _ := find(evs, EvToolStart); st.Data["summary"] != "rm -rf tmp" {
				t.Fatalf("工具开始 %+v", st.Data)
			}
			if end, _ := find(evs, EvToolEnd); end.Data["output"] != "acceptForSession" {
				t.Fatalf("总是允许应回复 acceptForSession，实际 %v", end.Data["output"])
			}
			if _, ok := find(evs, EvFileWrite); ok != tc.wantWrite {
				t.Fatalf("改动记录 %v，期望 %v", ok, tc.wantWrite)
			}
			if u, _ := find(evs, EvUsage); u.Data["inputTokens"] != int64(10) || u.Data["outputTokens"] != int64(5) {
				t.Fatalf("用量 %+v", u.Data)
			}
			if d, _ := find(evs, EvDone); d.Data["text"] != "完成" {
				t.Fatalf("回复 %+v", d.Data)
			}
		})
	}
}

func TestCodexAppResume(t *testing.T) {
	for resume, want := range map[string]string{"th-old": "th-old", "gone": "th-new"} {
		opt := fakeOpts(t, "codexapp")
		opt.ResumeID = resume
		p, err := CodexDriver{}.Start(context.Background(), opt)
		if err != nil {
			t.Fatal(err)
		}
		if e := <-p.Events(); e.Type != EvSessionID || e.Data["id"] != want {
			t.Fatalf("续聊 %s 应得到线程 %s，实际 %+v", resume, want, e)
		}
		p.Close()
	}
}

func TestCodexAppInterrupt(t *testing.T) {
	p, err := CodexDriver{}.Start(context.Background(), fakeOpts(t, "codexapp"))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.Send(context.Background(), Message{Text: "slow"})
	time.Sleep(100 * time.Millisecond)
	if err := p.Interrupt(); err != nil {
		t.Fatal(err)
	}
	evs := collect(t, p)
	if e, _ := find(evs, EvTurnEnd); e.Data["stopReason"] != "interrupted" {
		t.Fatalf("打断 %+v", e.Data)
	}
}

func TestPiApprovalExtension(t *testing.T) {
	for _, tc := range []struct {
		d    Decision
		want string
	}{{Decision{Allow: true}, "true/a1/allow"}, {Decision{}, "true/a1/deny"}} {
		ap := &fakeApprover{d: tc.d}
		opt := fakeOpts(t, "pi")
		opt.Approver = ap
		p, err := PiDriver{}.Start(context.Background(), opt)
		if err != nil {
			t.Fatal(err)
		}
		p.Send(context.Background(), Message{Text: "danger"})
		evs := collect(t, p)
		p.Close()
		if len(ap.reqs) != 1 || ap.reqs[0].Kind != "command" || ap.reqs[0].Summary != "rm -rf tmp" || ap.reqs[0].Input["command"] != "rm -rf tmp" {
			t.Fatalf("审批请求 %+v", ap.reqs)
		}
		// 其他扩展的对话被取消，审批按决定回复
		if end, _ := find(evs, EvToolEnd); end.Data["output"] != tc.want {
			t.Fatalf("扩展收到的回复 %v，期望 %s", end.Data["output"], tc.want)
		}
	}
}

func TestParsePiModels(t *testing.T) {
	out := "provider     model          context\nanthropic    claude-x       1M\n劲风-API  gpt-y   400K\n\n"
	if got := strings.Join(parsePiModels([]byte(out)), ","); got != "anthropic/claude-x,劲风-API/gpt-y" {
		t.Fatalf("解析 %s", got)
	}
}

func TestACPModelSelect(t *testing.T) {
	acpModelCache.Delete(KindDSH)
	if _, err := (ACPDriver{Name: KindDSH}).Models(context.Background(), nil); err == nil {
		t.Fatal("还没建过会话时应拿不到列表")
	}
	for model, want := range map[string]string{"": "ds/flash", "ds/pro": "ds/pro", "ds/none": "ds/flash"} {
		opt := fakeOpts(t, "acp")
		opt.Model = model
		p, err := ACPDriver{Name: KindDSH}.Start(context.Background(), opt)
		if err != nil {
			t.Fatal(err)
		}
		var sid Event
		var errs []string
		for e := range p.Events() {
			if e.Type == EvError {
				errs = append(errs, e.Data["message"].(string))
			}
			if e.Type == EvSessionID {
				sid = e
				break
			}
		}
		p.Close()
		if sid.Data["model"] != want {
			t.Fatalf("指定 %q 后当前模型 %v，期望 %s（错误 %v）", model, sid.Data["model"], want, errs)
		}
		if (model == "ds/none") != (len(errs) == 1) {
			t.Fatalf("找不到模型时应提示一次，实际 %v", errs)
		}
	}
	list, err := (ACPDriver{Name: KindDSH}).Models(context.Background(), nil)
	if err != nil || strings.Join(list, ",") != "ds/flash,ds/pro" {
		t.Fatalf("可选模型 %v %v", list, err)
	}
}

func TestModelCache(t *testing.T) {
	c := NewModelCache(time.Minute)
	acpModelCache.Delete("x")
	if got := c.Get(context.Background(), ACPDriver{Name: "x"}, nil, []string{"fb"}); len(got) != 1 || got[0] != "fb" {
		t.Fatalf("查询失败应退回 %v", got)
	}
	acpModelCache.Store("x", []string{"m1"})
	if got := c.Get(context.Background(), ACPDriver{Name: "x"}, nil, nil); len(got) != 1 || got[0] != "m1" {
		t.Fatalf("查询结果 %v", got)
	}
	acpModelCache.Store("x", []string{"m2"})
	if got := c.Get(context.Background(), ACPDriver{Name: "x"}, nil, nil); got[0] != "m1" {
		t.Fatalf("缓存期内不应重新查询 %v", got)
	}
}

func TestClaudeFinalBlockMatchesStream(t *testing.T) {
	// 与真实抓包一致：思考块（序号 0）内容被隐藏不产生增量，正文以序号 1 流式输出；
	// 随后每块单独一条完整消息，正文在完整消息里的序号为 0
	p := newClaudeParser()
	lines := []string{
		`{"type":"stream_event","event":{"type":"message_start","message":{"id":"M"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"do"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"ne"}}}`,
		`{"type":"assistant","message":{"id":"M","content":[{"type":"thinking","thinking":""}]}}`,
		`{"type":"assistant","message":{"id":"M","content":[{"type":"text","text":"done"}]}}`,
		// 下一次请求：思考与正文都流式，完整消息一次带两块
		`{"type":"stream_event","event":{"type":"message_start","message":{"id":"N"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"好"}}}`,
		`{"type":"assistant","message":{"id":"N","content":[{"type":"thinking","thinking":"想"},{"type":"text","text":"好"}]}}`,
	}
	ids := map[string][]string{}
	for _, l := range lines {
		for _, e := range p.parse([]byte(l)) {
			ids[e.Type] = append(ids[e.Type], e.Data["id"].(string))
		}
	}
	if strings.Join(ids[EvDelta], ",") != "M:1,M:1,N:1" || strings.Join(ids[EvDone], ",") != "M:1,N:1" {
		t.Fatalf("正文增量 %v 与完整回复 %v 的 ID 应一致", ids[EvDelta], ids[EvDone])
	}
	for _, id := range ids[EvThinking] {
		if id != "N:0" {
			t.Fatalf("思考块 ID %v", ids[EvThinking])
		}
	}
}

func TestAutoApproveArgs(t *testing.T) {
	c := strings.Join(ClaudeArgs(Options{Command: []string{"claude"}, AutoApprove: true, ApproveCmd: []string{"pd", "mcp"}}), " ")
	if !strings.Contains(c, "--dangerously-skip-permissions") || strings.Contains(c, "--permission-prompt-tool") {
		t.Fatalf("Claude Code 免审批参数 %s", c)
	}
	if c := strings.Join(ClaudeArgs(Options{Command: []string{"claude"}, ApproveCmd: []string{"pd", "mcp"}}), " "); strings.Contains(c, "--dangerously") || !strings.Contains(c, "--permission-prompt-tool") {
		t.Fatalf("普通会话参数 %s", c)
	}
	x := strings.Join(CodexArgs(Options{Command: []string{"codex"}, AutoApprove: true}, ""), " ")
	if !strings.Contains(x, "--dangerously-bypass-approvals-and-sandbox") || strings.Contains(x, "--sandbox") {
		t.Fatalf("Codex 免审批参数 %s", x)
	}
	app := &codexApp{opt: Options{AutoApprove: true}}
	if p := app.threadParams(); p["approvalPolicy"] != "never" || p["sandbox"] != "danger-full-access" {
		t.Fatalf("Codex app-server 免审批参数 %v", p)
	}
}

/** 写文件工具结果中的原文会作为改动前内容上报，新建文件原文为空 */
func TestClaudeOriginalFile(t *testing.T) {
	p := newClaudeParser()
	evs := p.parse([]byte(`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"tool_use_result":{"filePath":"/a/b.txt","originalFile":"old\n","structuredPatch":[]}}`))
	e, ok := find(evs, EvFileWrite)
	if !ok || e.Data["original"] != "old\n" || e.Data["existed"] != true {
		t.Fatalf("应上报原文 %+v", evs)
	}
	evs = p.parse([]byte(`{"type":"user","message":{"content":[]},"tool_use_result":{"type":"create","filePath":"/a/n.txt","originalFile":null}}`))
	if e, ok := find(evs, EvFileWrite); !ok || e.Data["existed"] != false {
		t.Fatalf("新建文件 %+v", evs)
	}
	if evs := p.parse([]byte(`{"type":"user","message":{"content":[]},"tool_use_result":{"stdout":"x"}}`)); len(evs) != 0 {
		t.Fatalf("非写文件结果不应上报 %+v", evs)
	}
}

/** Claude skill 列表读取说明，停用写入 skillOverrides 且保留其他设置，启用时去掉 */
func TestClaudeSkills(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "skills", "demo")
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte("---\nname: demo\ndescription: \"演示用\"\n---\n正文"), 0o644)
	os.WriteFile(filepath.Join(home, ".claude", "settings.json"), []byte(`{"env":{"A":"1"}}`), 0o644)
	list, err := ListSkills(context.Background(), KindClaude, home, "", nil)
	if err != nil || len(list) != 1 || list[0].Name != "demo" || list[0].Description != "演示用" || !list[0].Enabled {
		t.Fatalf("列表 %+v %v", list, err)
	}
	if err := SetSkill(context.Background(), KindClaude, home, "", nil, "demo", list[0].Path, false); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	if !strings.Contains(string(b), `"demo": "off"`) || !strings.Contains(string(b), `"A": "1"`) {
		t.Fatalf("停用后设置 %s", b)
	}
	list, _ = ListSkills(context.Background(), KindClaude, home, "", nil)
	if list[0].Enabled {
		t.Fatal("应显示为停用")
	}
	SetSkill(context.Background(), KindClaude, home, "", nil, "demo", list[0].Path, true)
	b, _ = os.ReadFile(filepath.Join(home, ".claude", "settings.json"))
	if strings.Contains(string(b), "skillOverrides") {
		t.Fatalf("启用后应去掉覆盖项 %s", b)
	}
	if text, err := ReadSkill(list, list[0].Path); err != nil || !strings.Contains(text, "正文") {
		t.Fatal("应能读取说明")
	}
	if _, err := ReadSkill(list, "/etc/passwd"); err != ErrNoSkill {
		t.Fatal("不在列表里的文件不能读取")
	}
	if got := SkillPrompt(KindClaude, []SkillRef{{Name: "demo"}}, "做事"); got != "/demo 做事" {
		t.Fatalf("单个 skill 应以斜杠指令调用 %q", got)
	}
}
