/**
 * 会话管理器 mock 测试：用内存假驱动覆盖状态机、排队、打断、审批、崩溃恢复与改动清单。
 */
package session

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/notify"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** mockProc：按提示词脚本产生事件的假进程 */
type mockProc struct {
	mu          sync.Mutex
	opt         agent.Options
	events      chan agent.Event
	done        chan struct{}
	once        sync.Once
	sent        []string
	interrupted int
	hang        chan struct{}
	err         error
	emu         sync.RWMutex
	closed      bool
}

func (p *mockProc) emit(t string, kv ...any) {
	m := map[string]any{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	p.emu.RLock()
	defer p.emu.RUnlock()
	if p.closed {
		return
	}
	select {
	case p.events <- agent.Event{Type: t, Data: m}:
	case <-p.done:
	}
}

/** Send：按内容执行脚本 */
func (p *mockProc) Send(_ context.Context, m agent.Message) error {
	p.mu.Lock()
	p.sent = append(p.sent, m.Text)
	p.mu.Unlock()
	go func() {
		switch {
		case strings.HasPrefix(m.Text, "approve"):
			d, _ := p.opt.Approver.RequestApproval(context.Background(), agent.ApprovalRequest{Tool: "Bash", Kind: "command", Summary: "rm -rf tmp"})
			if d.Allow {
				p.emit(agent.EvDone, "id", "a", "text", "allowed")
			} else {
				p.emit(agent.EvDone, "id", "a", "text", "denied:"+d.Reason)
			}
			p.emit(agent.EvTurnEnd)
		case m.Text == "hang":
			<-p.hang
			p.emit(agent.EvTurnEnd)
		case m.Text == "stream":
			for i := 0; i < 50; i++ {
				p.emit(agent.EvThinking, "id", "t", "text", "想", "delta", true)
			}
			for i := 0; i < 50; i++ {
				p.emit(agent.EvDelta, "id", "x", "text", "a")
			}
			p.emit(agent.EvDone, "id", "x", "text", strings.Repeat("a", 50))
			p.emit(agent.EvTurnEnd)
		case m.Text == "stuck":
		case m.Text == "crash":
			p.crash(errors.New("segfault"))
		case strings.HasPrefix(m.Text, "docx:"):
			// 用脚本生成 Word 文件：没有写文件记录，只有一条命令
			target := strings.TrimPrefix(m.Text, "docx:")
			paras := strings.Split(filepath.Base(target), "+")
			target = filepath.Dir(target) + "/out.docx"
			p.emit(agent.EvToolStart, "id", "c1", "name", "Bash", "kind", "command", "summary", "make", "input", map[string]any{"command": `python3 make.py "` + target + `"`})
			time.Sleep(30 * time.Millisecond)
			writeDocx(target, paras...)
			p.emit(agent.EvToolEnd, "id", "c1", "output", "ok")
			p.emit(agent.EvTurnEnd)
		case strings.HasPrefix(m.Text, "write:"):
			name := strings.TrimPrefix(m.Text, "write:")
			p.emit(agent.EvToolStart, "id", "t1", "name", "Write", "kind", "edit", "summary", name)
			p.emit(agent.EvFileWrite, "path", filepath.Join(p.opt.Cwd, name))
			time.Sleep(30 * time.Millisecond)
			os.WriteFile(filepath.Join(p.opt.Cwd, name), []byte("a\nb\n"), 0o644)
			p.emit(agent.EvToolEnd, "id", "t1", "output", "ok")
			p.emit(agent.EvTurnEnd)
		default:
			p.emit(agent.EvSessionID, "id", "agent-sess-1", "model", "m-default")
			p.emit(agent.EvDelta, "id", "x", "text", "re:")
			p.emit(agent.EvDone, "id", "x", "text", "re:"+m.Text)
			p.emit(agent.EvTurnEnd)
		}
	}()
	return nil
}

func (p *mockProc) Interrupt() error {
	p.mu.Lock()
	p.interrupted++
	p.mu.Unlock()
	select {
	case p.hang <- struct{}{}:
	default:
	}
	return nil
}

func (p *mockProc) crash(err error) {
	p.mu.Lock()
	p.err = err
	p.mu.Unlock()
	p.Close()
}

func (p *mockProc) Events() <-chan agent.Event { return p.events }
func (p *mockProc) Done() <-chan struct{}      { return p.done }
func (p *mockProc) Err() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.err
}
func (p *mockProc) Close() error {
	p.once.Do(func() {
		close(p.done)
		p.emu.Lock()
		p.closed = true
		close(p.events)
		p.emu.Unlock()
	})
	return nil
}

/** mockDriver：记录每次启动的参数 */
type mockDriver struct {
	kind   string
	mu     sync.Mutex
	starts []agent.Options
	procs  []*mockProc
	fail   bool
}

func (d *mockDriver) Kind() string { return d.kind }
func (d *mockDriver) Start(_ context.Context, opt agent.Options) (agent.Process, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.fail {
		return nil, errors.New("找不到命令")
	}
	d.starts = append(d.starts, opt)
	p := &mockProc{opt: opt, events: make(chan agent.Event, 64), done: make(chan struct{}), hang: make(chan struct{})}
	d.procs = append(d.procs, p)
	return p, nil
}

/** sentList：已发送消息的副本 */
func (p *mockProc) sentList() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.sent...)
}

/** interruptCount：中断次数 */
func (p *mockProc) interruptCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.interrupted
}

/** startList：启动参数副本 */
func (d *mockDriver) startList() []agent.Options {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]agent.Options(nil), d.starts...)
}

/** setFail：设置启动失败 */
func (d *mockDriver) setFail(v bool) {
	d.mu.Lock()
	d.fail = v
	d.mu.Unlock()
}

func (d *mockDriver) last() *mockProc {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.procs[len(d.procs)-1]
}

/** fixture：测试环境 */
type fixture struct {
	m      *Manager
	st     *store.Store
	hub    *hub.Hub
	claude *mockDriver
	pi     *mockDriver
	codex  *mockDriver
	root   string
	cfg    config.Config
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	f := &fixture{st: st, hub: hub.New(), claude: &mockDriver{kind: "claude"}, pi: &mockDriver{kind: "pi"}, codex: &mockDriver{kind: "codex"}, root: t.TempDir(), cfg: config.Default()}
	st.SaveWorkspace(context.Background(), store.Workspace{ID: "w1", Name: "w", RootPath: f.root})
	os.MkdirAll(filepath.Join(f.root, "sub"), 0o755)
	f.m = New(Deps{Store: st, Hub: f.hub, Registry: agent.NewRegistry(f.claude, f.pi, f.codex), Config: func() config.Config { return f.cfg }})
	t.Cleanup(f.m.Shutdown)
	return f
}

/** waitState：等待会话进入某状态 */
func (f *fixture) waitState(t *testing.T, id, st string) {
	t.Helper()
	for i := 0; i < 300; i++ {
		if f.m.State(id) == st {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("状态未变为 %s，当前 %s", st, f.m.State(id))
}

/** events：全部事件类型 */
func (f *fixture) events(t *testing.T, id string) []store.Event {
	evs, err := f.st.EventsAfter(context.Background(), id, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	return evs
}

/** hasEvent：是否存在满足条件的事件 */
func hasEvent(evs []store.Event, typ, contains string) bool {
	for _, e := range evs {
		if e.Type == typ && strings.Contains(string(e.Data), contains) {
			return true
		}
	}
	return false
}

func TestCreateValidates(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	if _, err := f.m.Create(ctx, "nope", "w1", ".", ""); !errors.Is(err, ErrUnknownKind) {
		t.Fatal("未知类型应拒绝")
	}
	if _, err := f.m.Create(ctx, "claude", "w1", "../x", ""); err == nil {
		t.Fatal("越界目录应拒绝")
	}
	if _, err := f.m.Create(ctx, "claude", "w1", "missing", ""); err == nil {
		t.Fatal("不存在的目录应拒绝")
	}
	s, err := f.m.Create(ctx, "claude", "w1", "sub", "")
	if err != nil || s.Cwd != "sub" || s.Title != "Claude Code" || s.LastSeq != 1 {
		t.Fatalf("创建 %+v %v", s, err)
	}
	f.cfg.Features.Agents = false
	if _, err := f.m.Create(ctx, "claude", "w1", ".", ""); !errors.Is(err, ErrDisabled) {
		t.Fatal("关闭开关后应拒绝")
	}
	if err := f.m.Send(ctx, s.ID, Input{Text: "x"}); !errors.Is(err, ErrDisabled) {
		t.Fatal("关闭开关后发送应拒绝")
	}
}

func TestSendTurnAndResume(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	sub := f.hub.Subscribe("d", 100)
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	if err := f.m.Send(ctx, s.ID, Input{Text: "你好世界"}); err != nil {
		t.Fatal(err)
	}
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	evs := f.events(t, s.ID)
	var types []string
	for i, e := range evs {
		types = append(types, e.Type)
		if e.Seq != int64(i+1) {
			t.Fatal("序号不连续")
		}
	}
	want := "state,msg.user,state,session.model,msg.delta,msg.done,state"
	if strings.Join(types, ",") != want {
		t.Fatalf("事件\n得到 %s\n期望 %s", strings.Join(types, ","), want)
	}
	got, _ := f.st.Session(ctx, s.ID)
	if got.AgentSessionID != "agent-sess-1" || got.Title != "Claude Code · 你好世界" || got.Preview != "re:你好世界" || got.Model != "m-default" {
		t.Fatalf("会话字段 %+v", got)
	}
	if len(sub.C) != len(evs) {
		t.Fatalf("推送数 %d 事件数 %d", len(sub.C), len(evs))
	}
	f.m.Update(ctx, s.ID, Patch{Model: strPtr("opus")})
	f.m.Send(ctx, s.ID, Input{Text: "again"})
	f.waitState(t, s.ID, StateIdle)
	if st := f.claude.startList(); len(st) != 2 || st[1].ResumeID != "agent-sess-1" || st[1].Model != "opus" {
		t.Fatalf("换模型后应带会话 ID 重启: %+v", st)
	}
}

func strPtr(s string) *string { return &s }

func TestQueueWhileRunning(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "hang"})
	f.waitState(t, s.ID, StateRunning)
	f.m.Send(ctx, s.ID, Input{Text: "second"})
	if !hasEvent(f.events(t, s.ID), "msg.user", `"queued":true`) {
		t.Fatal("执行中的消息应标记排队")
	}
	f.claude.last().hang <- struct{}{}
	for i := 0; i < 200 && len(f.claude.last().sentList()) < 2; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	f.waitState(t, s.ID, StateIdle)
	if sent := f.claude.last().sentList(); len(sent) != 2 || sent[1] != "second" {
		t.Fatalf("排队消息应自动发送: %v", sent)
	}
}

func TestInterruptClearsQueueAndDeniesApprovals(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "hang"})
	f.waitState(t, s.ID, StateRunning)
	f.m.Send(ctx, s.ID, Input{Text: "queued"})
	if err := f.m.Interrupt(ctx, s.ID); err != nil {
		t.Fatal(err)
	}
	f.waitState(t, s.ID, StateIdle)
	p := f.claude.last()
	if p.interruptCount() != 1 || len(p.sentList()) != 1 {
		t.Fatalf("打断后不应发送排队消息: %+v", p.sentList())
	}
	evs := f.events(t, s.ID)
	if !hasEvent(evs, "state", StateInterrupted) || !hasEvent(evs, "system", "已打断") {
		t.Fatal("缺少打断事件")
	}
	if err := f.m.Interrupt(ctx, s.ID); err != nil {
		t.Fatal("空闲时打断应无害")
	}
}

func TestInterruptForceClosesStuckProcess(t *testing.T) {
	f := newFixture(t)
	f.m.SetTimeouts(time.Minute, 30*time.Millisecond)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "stuck"})
	f.waitState(t, s.ID, StateRunning)
	f.m.Interrupt(ctx, s.ID)
	f.waitState(t, s.ID, StateIdle)
	select {
	case <-f.claude.last().Done():
	default:
		t.Fatal("超过宽限应强制结束进程")
	}
}

func TestApprovalAllowAlwaysAndRule(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "approve 1"})
	f.waitState(t, s.ID, StateAwaiting)
	pend, _ := f.st.PendingApprovals(ctx, s.ID)
	if len(pend) != 1 {
		t.Fatal("应登记一条审批")
	}
	if got, _ := f.st.Session(ctx, s.ID); !strings.HasPrefix(got.Preview, "待确认：") {
		t.Fatalf("摘要应为待确认: %s", got.Preview)
	}
	if err := f.m.Decide(ctx, pend[0].ID, "bogus", "d1"); !errors.Is(err, ErrBadAction) {
		t.Fatal("非法动作应拒绝")
	}
	if err := f.m.Decide(ctx, pend[0].ID, ActionAlways, "d1"); err != nil {
		t.Fatal(err)
	}
	f.waitState(t, s.ID, StateIdle)
	if !hasEvent(f.events(t, s.ID), "msg.done", "allowed") {
		t.Fatal("允许后 Agent 应继续")
	}
	if err := f.m.Decide(ctx, pend[0].ID, ActionDeny, "d1"); !errors.Is(err, store.ErrAlreadyDecided) {
		t.Fatalf("重复审批应拒绝: %v", err)
	}
	f.m.Send(ctx, s.ID, Input{Text: "approve 2"})
	f.waitState(t, s.ID, StateIdle)
	if p, _ := f.st.PendingApprovals(ctx, s.ID); len(p) != 0 {
		t.Fatal("总是允许后同类操作不应再审批")
	}
}

func TestApprovalTimeoutDenies(t *testing.T) {
	f := newFixture(t)
	f.m.SetTimeouts(50*time.Millisecond, time.Second)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "approve"})
	f.waitState(t, s.ID, StateAwaiting)
	f.waitState(t, s.ID, StateIdle)
	evs := f.events(t, s.ID)
	if !hasEvent(evs, "approval.done", store.ApprovalExpired) || !hasEvent(evs, "msg.done", "10 分钟未处理") {
		t.Fatal("超时应按拒绝处理")
	}
}

func TestCrashRecoveryAndLimit(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	for i := 1; i <= 3; i++ {
		f.m.Send(ctx, s.ID, Input{Text: "crash"})
		for j := 0; j < 300 && len(f.claude.startList()) < i+1; j++ {
			time.Sleep(5 * time.Millisecond)
		}
		f.waitState(t, s.ID, StateIdle)
	}
	if !hasEvent(f.events(t, s.ID), "system", "会话已恢复") {
		t.Fatal("应提示会话已恢复")
	}
	f.m.Send(ctx, s.ID, Input{Text: "crash"})
	f.waitState(t, s.ID, StateError)
	if !hasEvent(f.events(t, s.ID), "error", "连续失败") {
		t.Fatal("超过上限应报错")
	}
	if err := f.m.Retry(ctx, s.ID); err != nil {
		t.Fatal(err)
	}
	f.waitState(t, s.ID, StateIdle)
}

func TestStartFailureAndRetry(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	if err := f.m.Retry(ctx, s.ID); !errors.Is(err, ErrNothing) {
		t.Fatal("没有历史消息时重试应报错")
	}
	f.claude.setFail(true)
	f.m.Send(ctx, s.ID, Input{Text: "hi"})
	f.waitState(t, s.ID, StateIdle)
	if !hasEvent(f.events(t, s.ID), "error", "找不到命令") {
		t.Fatal("启动失败应报错")
	}
	f.claude.setFail(false)
	if err := f.m.Retry(ctx, s.ID); err != nil {
		t.Fatal(err)
	}
	f.waitState(t, s.ID, StateIdle)
	if !hasEvent(f.events(t, s.ID), "msg.done", "re:hi") {
		t.Fatal("重试应重新发送上一条")
	}
	if err := f.m.Send(ctx, s.ID, Input{}); err == nil {
		t.Fatal("空消息应拒绝")
	}
}

func TestDiffSummaryGitAndPlain(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("未安装 git")
	}
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", "sub", "")
	f.m.Send(ctx, s.ID, Input{Text: "write:plain.txt"})
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	if !hasEvent(f.events(t, s.ID), "diff.summary", `"path":"plain.txt"`) || !hasEvent(f.events(t, s.ID), "diff.summary", `"added":2`) {
		t.Fatalf("非 git 目录应按写文件记录生成清单并统计行数: %s", lastData(f.events(t, s.ID), "diff.summary"))
	}
	var sum struct {
		Files []FileChange `json:"files"`
	}
	json.Unmarshal([]byte(lastData(f.events(t, s.ID), "diff.summary")), &sum)
	if len(sum.Files) != 1 || sum.Files[0].Ref == "" {
		t.Fatalf("应带差异编号: %+v", sum.Files)
	}
	if d, err := f.m.Diff(ctx, s.ID, "", sum.Files[0].Ref); err != nil || !strings.Contains(d.(string), "+a\n+b") {
		t.Fatalf("按编号取差异 %v %v", d, err)
	}
	if all, _ := f.m.Diff(ctx, s.ID, "", ""); !strings.Contains(toJSON(all), "plain.txt") {
		t.Fatalf("非 git 目录的累计改动应取各轮清单 %v", all)
	}
	repo := filepath.Join(f.root, "repo")
	os.MkdirAll(repo, 0o755)
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", repo, "-c", "user.email=t@t", "-c", "user.name=t"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v %s", err, out)
		}
	}
	run("init", "-q")
	os.WriteFile(filepath.Join(repo, "old.txt"), []byte("1\n"), 0o644)
	os.WriteFile(filepath.Join(repo, "keep.txt"), []byte("k\n"), 0o644)
	run("add", ".")
	run("commit", "-qm", "init")
	os.WriteFile(filepath.Join(repo, "keep.txt"), []byte("k\nchanged before turn\n"), 0o644)
	g, _ := f.m.Create(ctx, "claude", "w1", "repo", "")
	f.m.Send(ctx, g.ID, Input{Text: "write:new.txt"})
	f.waitState(t, g.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	evs := f.events(t, g.ID)
	if !hasEvent(evs, "diff.summary", `"path":"new.txt"`) || hasEvent(evs, "diff.summary", "keep.txt") {
		t.Fatalf("git 清单应只含本轮改动: %s", lastData(evs, "diff.summary"))
	}
	all, err := f.m.Diff(ctx, g.ID, "", "")
	if err != nil || !strings.Contains(toJSON(all), "keep.txt") {
		t.Fatalf("累计改动应含之前的修改: %v %v", all, err)
	}
	d, err := f.m.Diff(ctx, g.ID, "new.txt", "")
	if err != nil || !strings.Contains(d.(string), "+a") {
		t.Fatalf("新文件差异 %v %v", d, err)
	}
	d, _ = f.m.Diff(ctx, g.ID, "keep.txt", "")
	if !strings.Contains(d.(string), "+changed before turn") {
		t.Fatalf("已跟踪文件差异 %v", d)
	}
	if _, err := f.m.Diff(ctx, g.ID, "../../etc/passwd", ""); err == nil {
		t.Fatal("越界路径应拒绝")
	}
}

func TestUpdateCwdAndRecover(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	if _, err := f.m.Update(ctx, s.ID, Patch{Cwd: strPtr("../..")}); err == nil {
		t.Fatal("切到工作区外应拒绝")
	}
	got, err := f.m.Update(ctx, s.ID, Patch{Cwd: strPtr("sub"), Pinned: boolPtr(true)})
	if err != nil || got.Cwd != "sub" || !got.Pinned {
		t.Fatalf("修改失败 %+v %v", got, err)
	}
	st := StateRunning
	f.st.UpdateSession(ctx, s.ID, store.SessionPatch{State: &st})
	f.st.CreateApproval(ctx, store.Approval{ID: "old", SessionID: s.ID, Request: []byte("{}")})
	if err := f.m.Recover(ctx); err != nil {
		t.Fatal(err)
	}
	got, _ = f.st.Session(ctx, s.ID)
	a, _ := f.st.Approval(ctx, "old")
	if got.State != StateIdle || a.Status != store.ApprovalExpired {
		t.Fatalf("重启恢复 %+v %+v", got, a)
	}
}

func boolPtr(b bool) *bool { return &b }

func lastData(evs []store.Event, typ string) string {
	for i := len(evs) - 1; i >= 0; i-- {
		if evs[i].Type == typ {
			return string(evs[i].Data)
		}
	}
	return ""
}

func toJSON(v any) string {
	b, _ := jsonMarshal(v)
	return string(b)
}

func TestSnippet(t *testing.T) {
	if snippet("a\n b   c", 10) != "a b c" || snippet("一二三四五", 3) != "一二三…" {
		t.Fatal("摘要截断")
	}
	if p, ok := previewFor("error", map[string]any{"message": "x"}); !ok || p != "出错：x" {
		t.Fatal("错误摘要")
	}
	if _, ok := previewFor("msg.delta", nil); ok {
		t.Fatal("增量不应更新摘要")
	}
}

/** jsonMarshal：测试用序列化 */
func jsonMarshal(v any) ([]byte, error) { return json.Marshal(v) }

func TestStreamDeltasCoalesced(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	f.m.Send(ctx, s.ID, Input{Text: "stream"})
	f.waitState(t, s.ID, StateIdle)
	var order []string
	thinking, text := "", ""
	for _, e := range f.events(t, s.ID) {
		var d struct {
			Text string `json:"text"`
		}
		json.Unmarshal(e.Data, &d)
		switch e.Type {
		case "thinking":
			thinking += d.Text
		case "msg.delta":
			text += d.Text
		}
		if len(order) == 0 || order[len(order)-1] != e.Type {
			order = append(order, e.Type)
		}
	}
	// 连续片段合并成少量事件，内容与顺序不变
	if thinking != strings.Repeat("想", 50) || text != strings.Repeat("a", 50) {
		t.Fatalf("合并后内容不对：%q %q", thinking, text)
	}
	if strings.Join(order, ",") != "state,msg.user,state,thinking,msg.delta,msg.done,state" {
		t.Fatalf("顺序 %v", order)
	}
	n := 0
	for _, e := range f.events(t, s.ID) {
		if e.Type == "thinking" || e.Type == "msg.delta" {
			n++
		}
	}
	if n > 4 {
		t.Fatalf("100 个片段应合并为少量事件，实际 %d 条", n)
	}
}

func TestAutoApproveSessionSkipsApprovals(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, err := f.m.CreateWith(ctx, NewSession{Kind: "claude", WorkspaceID: "w1", Cwd: ".", AutoApprove: true})
	if err != nil || !s.AutoApprove {
		t.Fatalf("创建 %+v %v", s, err)
	}
	f.m.Send(ctx, s.ID, Input{Text: "approve"})
	f.waitState(t, s.ID, StateIdle)
	for _, e := range f.events(t, s.ID) {
		if e.Type == "approval.request" {
			t.Fatal("免审批会话不应出现审批卡片")
		}
		if e.Type == "msg.done" && !strings.Contains(string(e.Data), "allowed") {
			t.Fatalf("应自动放行：%s", e.Data)
		}
	}
}

/** 接着电脑上的会话聊：导入最近的对话，电脑上又聊了几句后发消息前补上，手机这边的轮次不重复导入 */
func TestImportAndSyncTranscript(t *testing.T) {
	f := newFixture(t)
	home := t.TempDir()
	f.m.d.Home = func() string { return home }
	f.m.syncSettle = 10 * time.Millisecond
	ctx := context.Background()
	dir := filepath.Join(home, ".claude", "projects", "-x")
	os.MkdirAll(dir, 0o755)
	log := filepath.Join(dir, "abc-123.jsonl")
	line := func(typ, content string) string {
		return `{"type":"` + typ + `","timestamp":"2026-10-01T10:00:00Z","message":{"content":` + content + `}}` + "\n"
	}
	os.WriteFile(log, []byte(line("user", `"电脑上问的问题"`)+
		line("assistant", `[{"type":"text","text":"电脑上的回答"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]`)+
		line("user", `[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]`)+
		line("user", `"<command-name>/clear</command-name>"`)), 0o644)
	if _, err := f.m.Import(ctx, "claude", "missing", "w1", ".", ""); err == nil {
		t.Fatal("没有记录的会话应报错")
	}
	s, err := f.m.Import(ctx, "claude", "abc-123", "w1", ".", "电脑上问的问题")
	if err != nil {
		t.Fatal(err)
	}
	evs := f.events(t, s.ID)
	if !hasEvent(evs, "msg.user", "电脑上问的问题") || !hasEvent(evs, "msg.done", "电脑上的回答") || !hasEvent(evs, "tool.end", "a.txt") || hasEvent(evs, "msg.user", "command-name") {
		t.Fatalf("导入内容不对：%v", evs)
	}
	if s.AgentSessionID != "abc-123" || s.LogOffset == 0 || s.Title != "Claude Code · 电脑上问的问题" {
		t.Fatalf("应绑定原会话并记下位置：%+v", s)
	}
	// 电脑上又聊了一句
	fh, _ := os.OpenFile(log, os.O_APPEND|os.O_WRONLY, 0)
	fh.WriteString(line("user", `"电脑上追问"`) + line("assistant", `[{"type":"text","text":"电脑上追答"}]`))
	fh.Close()
	f.m.Send(ctx, s.ID, Input{Text: "手机接着问"})
	f.waitState(t, s.ID, StateIdle)
	evs = f.events(t, s.ID)
	if !hasEvent(evs, "msg.done", "电脑上追答") || !hasEvent(evs, "system", "电脑上新增") {
		t.Fatal("发消息前应补上电脑上新增的对话")
	}
	// 手机这轮写进记录的内容不应再被当成电脑上新增的对话
	fh, _ = os.OpenFile(log, os.O_APPEND|os.O_WRONLY, 0)
	fh.WriteString(line("user", `"手机接着问"`))
	fh.Close()
	time.Sleep(50 * time.Millisecond)
	before := len(f.events(t, s.ID))
	f.m.Sync(ctx, s.ID)
	if len(f.events(t, s.ID)) != before {
		t.Fatal("手机自己的轮次不应重复导入")
	}
}

/** fakeNotifier：记录推送 */
type fakeNotifier struct {
	mu   sync.Mutex
	msgs []notify.Msg
}

func (n *fakeNotifier) Notify(_ context.Context, m notify.Msg) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.msgs = append(n.msgs, m)
	return nil
}

func (n *fakeNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.msgs)
}

/** 只有电脑桌面端在线时照常推送并带上打开会话的地址；手机在线或关闭提醒时不推送 */
func TestNotifyRules(t *testing.T) {
	f := newFixture(t)
	n := &fakeNotifier{}
	f.m.d.Notifier = func() notify.Notifier { return n }
	ctx := context.Background()
	s, _ := f.m.Create(ctx, "claude", "w1", ".", "")
	desk := f.hub.Subscribe(hub.DesktopDevice, 8)
	f.m.Send(ctx, s.ID, Input{Text: "hi"})
	f.waitState(t, s.ID, StateIdle)
	for i := 0; i < 100 && n.count() == 0; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if n.count() != 1 || n.msgs[0].Click != "pocketdesk://open?session="+s.ID || n.msgs[0].Title != "CC 会话已完成" {
		t.Fatalf("桌面端在线时应照常推送 %+v", n.msgs)
	}
	f.hub.Unsubscribe(desk)
	phone := f.hub.Subscribe("phone-1", 64)
	f.m.Send(ctx, s.ID, Input{Text: "again"})
	f.waitState(t, s.ID, StateIdle)
	f.hub.Unsubscribe(phone)
	muted := true
	f.m.Update(ctx, s.ID, Patch{Muted: &muted})
	f.m.Send(ctx, s.ID, Input{Text: "third"})
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(30 * time.Millisecond)
	if n.count() != 1 {
		t.Fatalf("手机在线或关闭提醒时不应推送 %+v", n.msgs)
	}
}

/** writeDocx：写一个只有正文段落的 Word 文件 */
func writeDocx(p string, paras ...string) {
	f, _ := os.Create(p)
	zw := zip.NewWriter(f)
	w, _ := zw.Create("word/document.xml")
	w.Write([]byte(`<w:document xmlns:w="w"><w:body>`))
	for _, x := range paras {
		w.Write([]byte(`<w:p><w:r><w:t>` + x + `</w:t></w:r></w:p>`))
	}
	w.Write([]byte(`</w:body></w:document>`))
	zw.Close()
	f.Close()
}

/** 命令生成、修改工作区外的 Word 文件：按文字内容统计增删并可查看差异；脚本改动工作目录里的文件也能发现 */
func TestCommandChangesOffice(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	desk := t.TempDir()
	old := skipRoots
	skipRoots = []string{"/dev/"}
	t.Cleanup(func() { skipRoots = old })
	s, _ := f.m.Create(ctx, "claude", "w1", "sub", "")
	sum := func() []FileChange {
		var d struct {
			Files []FileChange `json:"files"`
		}
		json.Unmarshal([]byte(lastData(f.events(t, s.ID), "diff.summary")), &d)
		return d.Files
	}
	f.m.Send(ctx, s.ID, Input{Text: "docx:" + filepath.Join(desk, "标题+第一段")})
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	got := sum()
	if len(got) != 1 || got[0].Path != canon(filepath.Join(desk, "out.docx")) || got[0].Status != "added" || got[0].Added != 2 || got[0].Ref == "" {
		t.Fatalf("新建 docx %+v", got)
	}
	f.m.Send(ctx, s.ID, Input{Text: "docx:" + filepath.Join(desk, "标题+改过的段落+新增段落")})
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	got = sum()
	if len(got) != 1 || got[0].Status != "modified" || got[0].Added != 2 || got[0].Removed != 1 {
		t.Fatalf("修改 docx %+v", got)
	}
	d, _ := f.m.Diff(ctx, s.ID, "", got[0].Ref)
	if !strings.Contains(d.(string), "-第一段") || !strings.Contains(d.(string), "+新增段落") {
		t.Fatalf("文字差异 %v", d)
	}
	// 脚本在工作目录里生成文件（命令里没写文件名）
	f.m.Send(ctx, s.ID, Input{Text: "docx:" + filepath.Join(f.root, "sub", "仅工作目录")})
	f.waitState(t, s.ID, StateIdle)
	time.Sleep(20 * time.Millisecond)
	if got = sum(); len(got) != 1 || got[0].Path != "out.docx" || got[0].Status != "added" {
		t.Fatalf("工作目录里的新文件 %+v", got)
	}
}

func TestPresetInstruction(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	s, err := f.m.CreateWith(ctx, NewSession{Kind: "claude", WorkspaceID: "w1", Cwd: ".", Instruction: "你是翻译官", Preset: `{"id":"translate"}`})
	if err != nil {
		t.Fatal(err)
	}
	if s.Instruction != "你是翻译官" || s.Preset != `{"id":"translate"}` {
		t.Fatalf("模板字段没有保存: %+v", s)
	}
	n := "新提示词"
	got, err := f.m.Update(ctx, s.ID, Patch{Instruction: &n})
	if err != nil || got.Instruction != n {
		t.Fatalf("修改模板提示词失败: %v %+v", err, got)
	}
	if withInstruction("", "你好") != "你好" {
		t.Fatal("没有模板时应原样发送")
	}
	if !strings.HasPrefix(withInstruction("甲", "乙"), "甲") || !strings.HasSuffix(withInstruction("甲", "乙"), "乙") {
		t.Fatal("模板提示词应放在用户输入前面")
	}
}
