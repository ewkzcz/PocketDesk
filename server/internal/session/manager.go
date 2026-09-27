/**
 * 会话管理器：维护每个会话的 Agent 进程与状态机，写入事件并推送，处理排队、插话、打断、恢复与改动清单。
 */
package session

import (
	"context"
	"errors"
	"fmt"
	"github.com/ewkzcz/pocketdesk/server/internal/idem"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/notify"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** 会话状态 */
const (
	StateIdle        = "idle"
	StateRunning     = "running"
	StateAwaiting    = "awaiting"
	StateInterrupted = "interrupted"
	StateError       = "error"
)

/** KindTerminal：终端会话类型 */
const KindTerminal = "terminal"

/** maxRestarts：进程连续异常退出的自动恢复上限 */
const maxRestarts = 3

/** 会话错误 */
var (
	ErrDisabled    = errors.New("电脑端已关闭 Agent 会话功能")
	ErrUnknownKind = errors.New("不支持的 Agent 类型")
	ErrClosed      = errors.New("电脑端正在退出")
	ErrNotAgent    = errors.New("该会话不是 Agent 会话")
	ErrBusy        = errors.New("会话正在执行")
	ErrNothing     = errors.New("没有可重试的消息")
)

/** Deps：管理器依赖 */
type Deps struct {
	Store      *store.Store
	Hub        *hub.Hub
	Registry   *agent.Registry
	Config     func() config.Config
	Notifier   func() notify.Notifier
	ApproveCmd func(sessionID string) []string
}

/** Manager：会话管理器 */
type Manager struct {
	d               Deps
	mu              sync.Mutex
	rts             map[string]*runtime
	pend            map[string]*pending
	approvalTimeout time.Duration
	interruptGrace  time.Duration
	now             func() time.Time
	closed          atomic.Bool
	models          *agent.ModelCache

	/** 最近处理过的消息编号，忽略网络重试造成的重复发送 */
	recent *idem.Recent
}

/** runtime：一个会话的运行时 */
type runtime struct {
	mu       sync.Mutex
	id       string
	sess     store.Session
	proc     agent.Process
	dproc    agent.Process
	dkind    string
	state    string
	queue    []Input
	last     *Input
	turn     *turn
	restarts int
}

/** turn：一轮执行的上下文 */
type turn struct {
	snap   gitSnap
	writes map[string]bool
	cwd    string
}

/** Input：一条发送请求 */
type Input struct {
	Text        string   `json:"text"`
	Attachments []string `json:"attachments"`
	Mode        string   `json:"mode"`
	Delegate    string   `json:"delegate"`
	ClientID    string   `json:"clientId"`
}

/** New：创建管理器 */
func New(d Deps) *Manager {
	if d.Notifier == nil {
		d.Notifier = func() notify.Notifier { return notify.Nop{} }
	}
	return &Manager{d: d, rts: map[string]*runtime{}, pend: map[string]*pending{}, approvalTimeout: 10 * time.Minute, interruptGrace: 10 * time.Second, now: time.Now, recent: idem.New(2000, 30*time.Minute), models: agent.NewModelCache(10 * time.Minute)}
}

/** SetTimeouts：调整审批超时与打断宽限，仅供测试 */
func (m *Manager) SetTimeouts(approval, grace time.Duration) {
	m.approvalTimeout, m.interruptGrace = approval, grace
}

/**
 * Recover：服务启动时把上次未正常结束的会话状态复位为空闲，并把遗留审批标为过期
 */
func (m *Manager) Recover(ctx context.Context) error {
	list, err := m.d.Store.Sessions(ctx)
	if err != nil {
		return err
	}
	for _, s := range list {
		if s.Kind == KindTerminal {
			continue
		}
		pend, _ := m.d.Store.PendingApprovals(ctx, s.ID)
		for _, a := range pend {
			m.d.Store.DecideApproval(ctx, a.ID, store.ApprovalExpired, "system")
			m.emit(ctx, s.ID, "approval.done", map[string]any{"id": a.ID, "status": store.ApprovalExpired})
		}
		if s.State != StateIdle {
			m.emit(ctx, s.ID, "system", map[string]any{"text": "电脑端服务已重启，会话已恢复"})
			m.setStateDirect(ctx, s.ID, StateIdle)
		}
	}
	return nil
}

/**
 * Create：新建 Agent 会话
 *
 * 处理流程：
 * 1、校验功能开关与类型
 * 2、校验工作区与工作目录
 * 3、写库并发出初始状态事件
 */
func (m *Manager) Create(ctx context.Context, kind, wsID, cwd, model string) (store.Session, error) {
	// 1、开关与类型
	if !m.d.Config().Features.Agents {
		return store.Session{}, ErrDisabled
	}
	if _, ok := m.d.Registry.Get(kind); !ok {
		return store.Session{}, ErrUnknownKind
	}
	// 2、目录
	rel, err := m.checkCwd(ctx, wsID, cwd)
	if err != nil {
		return store.Session{}, err
	}
	// 3、写库
	s, err := m.d.Store.CreateSession(ctx, store.Session{ID: security.NewID(), Kind: kind, Title: agent.Label(kind), WorkspaceID: wsID, Cwd: rel, Model: model, State: StateIdle})
	if err != nil {
		return s, err
	}
	m.emit(ctx, s.ID, "state", map[string]any{"state": StateIdle})
	return m.d.Store.Session(ctx, s.ID)
}

/** checkCwd：确认目录存在且在工作区内，返回规范化相对路径 */
func (m *Manager) checkCwd(ctx context.Context, wsID, cwd string) (string, error) {
	ws, err := m.d.Store.Workspace(ctx, wsID)
	if err != nil {
		return "", err
	}
	abs, err := workspace.Resolve(ws.RootPath, cwd)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", workspace.ErrNotDir
	}
	return workspace.CleanRel(cwd)
}

/** absCwd：会话工作目录的绝对路径 */
func (m *Manager) absCwd(ctx context.Context, s store.Session) (string, error) {
	ws, err := m.d.Store.Workspace(ctx, s.WorkspaceID)
	if err != nil {
		return "", err
	}
	return workspace.Resolve(ws.RootPath, s.Cwd)
}

/** runtime：取或创建运行时 */
func (m *Manager) runtime(ctx context.Context, id string) (*runtime, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if rt, ok := m.rts[id]; ok {
		return rt, nil
	}
	s, err := m.d.Store.Session(ctx, id)
	if err != nil {
		return nil, err
	}
	if s.Kind == KindTerminal {
		return nil, ErrNotAgent
	}
	rt := &runtime{id: id, sess: s, state: StateIdle}
	m.rts[id] = rt
	return rt, nil
}

/**
 * Send：发送消息
 *
 * 处理流程：
 * 1、校验开关，重发的同一条消息直接返回，首条消息时用内容生成标题
 * 2、执行中：支持插话且要求插话时立即送达，否则排队
 * 3、空闲：记录用户消息并开始新一轮
 */
func (m *Manager) Send(ctx context.Context, id string, in Input) error {
	// 1、开关与标题
	if !m.d.Config().Features.Agents {
		return ErrDisabled
	}
	if strings.TrimSpace(in.Text) == "" && len(in.Attachments) == 0 {
		return errors.New("消息不能为空")
	}
	// 消息一旦开始处理就完整执行，不随手机断开连接而中途取消
	ctx = context.WithoutCancel(ctx)
	rt, err := m.runtime(ctx, id)
	if err != nil {
		return err
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	// 同一条消息因网络超时被重发时直接视为成功
	if in.ClientID != "" && m.recent.Has(id+"\x00"+in.ClientID) {
		return nil
	}
	if in.Delegate == rt.sess.Kind {
		in.Delegate = ""
	}
	if in.Delegate != "" {
		if _, ok := m.d.Registry.Get(in.Delegate); !ok {
			return ErrUnknownKind
		}
	}
	if rt.sess.Title == agent.Label(rt.sess.Kind) && in.Text != "" {
		title := agent.Label(rt.sess.Kind) + " · " + snippet(in.Text, 16)
		if s, err := m.d.Store.UpdateSession(ctx, id, store.SessionPatch{Title: &title}); err == nil {
			rt.sess = s
		}
	}
	busy := rt.state == StateRunning || rt.state == StateAwaiting || rt.state == StateInterrupted
	// 2、执行中
	if busy {
		if in.Mode == "steer" && rt.proc != nil && rt.dproc == nil {
			if d, _ := m.d.Registry.Get(rt.sess.Kind); d.SupportsSteer() {
				if err := m.emitUser(ctx, rt, in, false); err != nil {
					return err
				}
				return rt.proc.Steer(ctx, agent.Message{Text: in.Text, Attachments: in.Attachments})
			}
		}
		if err := m.emitUser(ctx, rt, in, true); err != nil {
			return err
		}
		rt.queue = append(rt.queue, in)
		return nil
	}
	// 3、空闲
	if err := m.emitUser(ctx, rt, in, false); err != nil {
		return err
	}
	m.startTurn(ctx, rt, in)
	return nil
}

/** emitUser：记录用户消息事件 */
func (m *Manager) emitUser(ctx context.Context, rt *runtime, in Input, queued bool) error {
	if err := m.emit(ctx, rt.id, "msg.user", map[string]any{"text": in.Text, "attachments": in.Attachments, "queued": queued, "mode": in.Mode, "delegate": in.Delegate, "clientId": in.ClientID}); err != nil {
		return err
	}
	// 记录成功后才登记编号，失败时手机重发会重新处理
	m.recent.Add(rt.id + "\x00" + in.ClientID)
	return nil
}

/**
 * startTurn：开始一轮（调用方持有 rt.mu）
 *
 * 处理流程：
 * 1、解析工作目录并记录改动快照
 * 2、确保进程已启动（委托给其他 Agent 时单独启动）
 * 3、状态切到执行中并发送消息
 */
func (m *Manager) startTurn(ctx context.Context, rt *runtime, in Input) {
	ctx = context.WithoutCancel(ctx)
	last := in
	rt.last = &last
	// 1、目录与快照
	cwd, err := m.absCwd(ctx, rt.sess)
	if err != nil {
		m.emit(ctx, rt.id, "error", map[string]any{"message": "工作目录不可用：" + err.Error(), "retryable": false})
		m.setState(ctx, rt, StateIdle)
		return
	}
	rt.turn = &turn{snap: snapshot(ctx, cwd), writes: map[string]bool{}, cwd: cwd}
	// 2、进程
	var proc agent.Process
	if in.Delegate != "" {
		proc, err = m.startProc(ctx, rt, in.Delegate, cwd, "", "")
		if err == nil {
			rt.dproc, rt.dkind = proc, in.Delegate
		}
	} else {
		if rt.proc == nil {
			rt.proc, err = m.startProc(ctx, rt, rt.sess.Kind, cwd, rt.sess.AgentSessionID, rt.sess.Model)
		}
		proc = rt.proc
	}
	if err != nil {
		m.emit(ctx, rt.id, "error", map[string]any{"message": "启动失败：" + err.Error(), "retryable": true})
		m.setState(ctx, rt, StateIdle)
		rt.turn = nil
		return
	}
	// 3、发送
	m.setState(ctx, rt, StateRunning)
	if err := proc.Send(ctx, agent.Message{Text: in.Text, Attachments: in.Attachments}); err != nil {
		m.emit(ctx, rt.id, "error", map[string]any{"message": "发送失败：" + err.Error(), "retryable": true})
		m.finishTurn(ctx, rt, proc)
	}
}

/** startProc：启动驱动进程并开始转发事件 */
func (m *Manager) startProc(ctx context.Context, rt *runtime, kind, cwd, resume, model string) (agent.Process, error) {
	d, ok := m.d.Registry.Get(kind)
	if !ok {
		return nil, ErrUnknownKind
	}
	cfg := m.d.Config()
	opt := agent.Options{Cwd: cwd, Model: model, ResumeID: resume, Command: cfg.Agents[kind], Approver: &sessionApprover{m: m, sid: rt.id}}
	if kind == agent.KindClaude && m.d.ApproveCmd != nil {
		opt.ApproveCmd = m.d.ApproveCmd(rt.id)
	}
	p, err := d.Start(ctx, opt)
	if err != nil {
		return nil, err
	}
	tag := ""
	if kind != rt.sess.Kind {
		tag = kind
	}
	go m.pump(rt, p, tag)
	return p, nil
}

/**
 * pump：转发一个进程的全部事件，结束后处理退出
 *
 * 处理流程：
 * 1、同一段回复或思考的连续流式片段合并后再写库推送（最多等 coalesceWait 或攒满 coalesceMax），
 *    避免每个词一条事件撑大数据库、挤占手机端首屏
 * 2、其他事件到达前先发出已合并的片段，保证顺序不变
 * 3、事件通道关闭后处理退出
 */
func (m *Manager) pump(rt *runtime, p agent.Process, tag string) {
	ctx := context.Background()
	var pend *agent.Event
	var timer *time.Timer
	var tick <-chan time.Time
	flush := func() {
		if pend != nil {
			m.handle(ctx, rt, p, tag, *pend)
			pend = nil
		}
		if timer != nil {
			timer.Stop()
			timer, tick = nil, nil
		}
	}
	events := p.Events()
	for events != nil {
		select {
		case e, ok := <-events:
			if !ok {
				events = nil
				flush()
				break
			}
			// 1、流式片段
			if k := deltaKey(e); k != "" {
				if pend != nil && deltaKey(*pend) == k {
					text, _ := pend.Data["text"].(string)
					add, _ := e.Data["text"].(string)
					pend.Data["text"] = text + add
					if len(text)+len(add) >= coalesceMax {
						flush()
					}
					continue
				}
				flush()
				data := make(map[string]any, len(e.Data))
				for k, v := range e.Data {
					data[k] = v
				}
				pend = &agent.Event{Type: e.Type, Data: data}
				timer = time.NewTimer(coalesceWait)
				tick = timer.C
				continue
			}
			// 2、其他事件
			flush()
			m.handle(ctx, rt, p, tag, e)
		case <-tick:
			timer, tick = nil, nil
			flush()
		}
	}
	// 3、退出
	<-p.Done()
	m.onExit(ctx, rt, p)
}

/** 流式片段合并的等待时长与长度上限 */
const (
	coalesceWait = 120 * time.Millisecond
	coalesceMax  = 4096
)

/** deltaKey：可合并的流式片段返回类型与 ID 组成的键，其他事件返回空 */
func deltaKey(e agent.Event) string {
	id, _ := e.Data["id"].(string)
	switch {
	case e.Type == agent.EvDelta:
		return "d:" + id
	case e.Type == agent.EvThinking && e.Data["delta"] == true:
		return "t:" + id
	}
	return ""
}

/**
 * handle：处理一条驱动事件
 *
 * 处理流程：
 * 1、会话 ID：保存用于续聊（委托进程除外）
 * 2、写文件记录：加入本轮改动
 * 3、本轮结束：生成改动清单并处理排队
 * 4、其他：附加来源后写库推送
 */
func (m *Manager) handle(ctx context.Context, rt *runtime, p agent.Process, tag string, e agent.Event) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	switch e.Type {
	// 1、会话 ID
	case agent.EvSessionID:
		if tag != "" || p != rt.proc {
			return
		}
		id, _ := e.Data["id"].(string)
		if id != "" && id != rt.sess.AgentSessionID {
			if s, err := m.d.Store.UpdateSession(ctx, rt.id, store.SessionPatch{AgentSessionID: &id}); err == nil {
				rt.sess = s
			}
		}
		if model, _ := e.Data["model"].(string); model != "" && rt.sess.Model == "" {
			if s, err := m.d.Store.UpdateSession(ctx, rt.id, store.SessionPatch{Model: &model}); err == nil {
				rt.sess = s
				m.emit(ctx, rt.id, "session.model", map[string]any{"model": model})
			}
		}
	// 2、写文件
	case agent.EvFileWrite:
		if rt.turn != nil {
			if p, _ := e.Data["path"].(string); p != "" {
				rt.turn.writes[p] = true
			}
		}
	// 3、本轮结束
	case agent.EvTurnEnd:
		if p == rt.proc || p == rt.dproc {
			m.finishTurn(ctx, rt, p)
		}
	// 4、其他
	default:
		if tag != "" {
			e.Data["agent"] = tag
		}
		m.emit(ctx, rt.id, e.Type, e.Data)
	}
}

/**
 * finishTurn：本轮收尾（调用方持有 rt.mu）
 *
 * 处理流程：
 * 1、生成并推送改动清单
 * 2、关闭委托进程，状态回到空闲，清零异常计数
 * 3、推送完成通知
 * 4、排队中有消息则自动发送下一条
 */
func (m *Manager) finishTurn(ctx context.Context, rt *runtime, p agent.Process) {
	// 1、改动清单
	if rt.turn != nil {
		files, git := m.turnChanges(ctx, rt.turn)
		if len(files) > 0 {
			m.emit(ctx, rt.id, "diff.summary", map[string]any{"files": files, "git": git})
			preview := fmt.Sprintf("已完成：改动了 %d 个文件", len(files))
			m.d.Store.UpdateSession(ctx, rt.id, store.SessionPatch{Preview: &preview})
		}
		rt.turn = nil
	}
	// 2、状态
	if p != nil && p == rt.dproc {
		rt.dproc.Close()
		rt.dproc, rt.dkind = nil, ""
	}
	wasInterrupted := rt.state == StateInterrupted
	m.denyPending(ctx, rt.id, "本轮已结束")
	m.setState(ctx, rt, StateIdle)
	if !wasInterrupted {
		rt.restarts = 0
	}
	// 3、通知
	if !wasInterrupted {
		m.notify(ctx, rt.sess.Kind, "会话已完成")
	}
	// 4、排队
	if len(rt.queue) > 0 && !wasInterrupted {
		next := rt.queue[0]
		rt.queue = rt.queue[1:]
		m.emit(ctx, rt.id, "system", map[string]any{"text": "开始处理排队消息"})
		m.startTurn(ctx, rt, next)
	}
}

/** turnChanges：git 仓库用快照对比，否则用写文件记录 */
func (m *Manager) turnChanges(ctx context.Context, t *turn) ([]FileChange, bool) {
	if t.snap.repo {
		return changedSince(ctx, t.snap), true
	}
	var out []FileChange
	for p := range t.writes {
		rel := p
		if filepath.IsAbs(p) {
			if r, err := filepath.Rel(t.cwd, p); err == nil && !strings.HasPrefix(r, "..") {
				rel = filepath.ToSlash(r)
			}
		}
		out = append(out, FileChange{Path: rel, Status: "modified"})
	}
	sortChanges(out)
	return out, false
}

/**
 * onExit：进程退出处理
 *
 * 处理流程：
 * 1、不是当前进程（已被替换或委托进程）只做清理
 * 2、空闲时退出：清空进程，下次发送时再启动
 * 3、打断后被强制结束：回到空闲
 * 4、执行中异常退出：未超过上限则用会话 ID 重启并提示已恢复，否则进入出错状态
 */
func (m *Manager) onExit(ctx context.Context, rt *runtime, p agent.Process) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	// 1、非当前进程
	if p == rt.dproc {
		if rt.state == StateRunning || rt.state == StateAwaiting || rt.state == StateInterrupted {
			if err := p.Err(); err != nil {
				m.emit(ctx, rt.id, "error", map[string]any{"message": "进程异常退出：" + err.Error(), "retryable": true})
			}
			m.finishTurn(ctx, rt, p)
		}
		return
	}
	if p != rt.proc {
		return
	}
	rt.proc = nil
	switch rt.state {
	// 2、空闲
	case StateIdle, StateError:
		return
	// 3、打断
	case StateInterrupted:
		m.finishTurn(ctx, rt, nil)
		return
	}
	// 4、异常退出
	rt.restarts++
	msg := "进程意外退出"
	if err := p.Err(); err != nil {
		msg += "：" + err.Error()
	}
	m.denyPending(ctx, rt.id, "进程已退出")
	rt.turn = nil
	if rt.restarts > maxRestarts {
		m.emit(ctx, rt.id, "error", map[string]any{"message": msg + "，连续失败 3 次，已停止自动恢复", "retryable": true})
		m.setState(ctx, rt, StateError)
		return
	}
	cwd, err := m.absCwd(ctx, rt.sess)
	if err == nil {
		rt.proc, err = m.startProc(ctx, rt, rt.sess.Kind, cwd, rt.sess.AgentSessionID, rt.sess.Model)
	}
	if err != nil {
		m.emit(ctx, rt.id, "error", map[string]any{"message": msg + "，恢复失败：" + err.Error(), "retryable": true})
		m.setState(ctx, rt, StateError)
		return
	}
	m.emit(ctx, rt.id, "error", map[string]any{"message": msg, "retryable": true})
	m.emit(ctx, rt.id, "system", map[string]any{"text": "会话已恢复"})
	m.setState(ctx, rt, StateIdle)
}

/**
 * Interrupt：打断当前执行
 *
 * 处理流程：
 * 1、非执行状态直接返回
 * 2、切到已打断，清空排队并拒绝待审批
 * 3、向进程发中止指令，超过宽限仍未结束则强制结束
 */
func (m *Manager) Interrupt(ctx context.Context, id string) error {
	rt, err := m.runtime(ctx, id)
	if err != nil {
		return err
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	// 1、状态
	if rt.state != StateRunning && rt.state != StateAwaiting {
		return nil
	}
	// 2、切换
	m.setState(ctx, rt, StateInterrupted)
	rt.queue = nil
	m.denyPending(ctx, rt.id, "用户已打断")
	m.emit(ctx, rt.id, "system", map[string]any{"text": "已打断"})
	// 3、中止
	p := rt.proc
	if rt.dproc != nil {
		p = rt.dproc
	}
	if p == nil {
		m.setState(ctx, rt, StateIdle)
		return nil
	}
	if err := p.Interrupt(); err != nil {
		slog.Warn("发送中止指令失败", "err", err)
	}
	grace := m.interruptGrace
	time.AfterFunc(grace, func() {
		rt.mu.Lock()
		still := rt.state == StateInterrupted && (rt.proc == p || rt.dproc == p)
		rt.mu.Unlock()
		if still {
			p.Close()
		}
	})
	return nil
}

/** Retry：重新发送上一条消息 */
func (m *Manager) Retry(ctx context.Context, id string) error {
	rt, err := m.runtime(ctx, id)
	if err != nil {
		return err
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if rt.state == StateRunning || rt.state == StateAwaiting || rt.state == StateInterrupted {
		return ErrBusy
	}
	if rt.last == nil {
		return ErrNothing
	}
	if rt.state == StateError {
		rt.restarts = 0
	}
	in := *rt.last
	m.emitUser(ctx, rt, in, false)
	m.startTurn(ctx, rt, in)
	return nil
}

/** Patch：会话可修改项 */
type Patch struct {
	Title  *string `json:"title"`
	Pinned *bool   `json:"pinned"`
	Model  *string `json:"model"`
	Cwd    *string `json:"cwd"`
}

/**
 * Update：修改会话
 *
 * 处理流程：
 * 1、切换目录时校验在工作区内
 * 2、写库；模型或目录变化且空闲时关闭进程，下一轮按新参数启动
 */
func (m *Manager) Update(ctx context.Context, id string, p Patch) (store.Session, error) {
	cur, err := m.d.Store.Session(ctx, id)
	if err != nil {
		return cur, err
	}
	// 1、目录
	sp := store.SessionPatch{Title: p.Title, Pinned: p.Pinned, Model: p.Model}
	if p.Cwd != nil {
		rel, err := m.checkCwd(ctx, cur.WorkspaceID, *p.Cwd)
		if err != nil {
			return cur, err
		}
		sp.Cwd = &rel
	}
	// 2、写库与进程
	if cur.Kind == KindTerminal {
		return m.d.Store.UpdateSession(ctx, id, sp)
	}
	rt, err := m.runtime(ctx, id)
	if err != nil {
		return cur, err
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if (p.Model != nil || p.Cwd != nil) && (rt.state == StateRunning || rt.state == StateAwaiting) {
		return cur, ErrBusy
	}
	s, err := m.d.Store.UpdateSession(ctx, id, sp)
	if err != nil {
		return s, err
	}
	rt.sess = s
	if (p.Model != nil || p.Cwd != nil) && rt.proc != nil {
		old := rt.proc
		rt.proc = nil
		old.Close()
	}
	if p.Model != nil {
		m.emit(ctx, id, "session.model", map[string]any{"model": s.Model})
	}
	if p.Cwd != nil {
		m.emit(ctx, id, "system", map[string]any{"text": "工作目录已切换到 " + displayCwd(s.Cwd)})
	}
	return s, nil
}

/** Diff：本会话工作目录的累计改动或单个文件差异 */
func (m *Manager) Diff(ctx context.Context, id, path string) (any, error) {
	s, err := m.d.Store.Session(ctx, id)
	if err != nil {
		return nil, err
	}
	cwd, err := m.absCwd(ctx, s)
	if err != nil {
		return nil, err
	}
	if path != "" {
		return fileDiff(ctx, cwd, path)
	}
	files, git := cumulative(ctx, cwd)
	if files == nil {
		files = []FileChange{}
	}
	return map[string]any{"files": files, "git": git}, nil
}

/** Shutdown：关闭全部进程 */
func (m *Manager) Shutdown() {
	m.closed.Store(true)
	m.mu.Lock()
	rts := make([]*runtime, 0, len(m.rts))
	for _, rt := range m.rts {
		rts = append(rts, rt)
	}
	m.mu.Unlock()
	for _, rt := range rts {
		rt.mu.Lock()
		if rt.proc != nil {
			rt.proc.Close()
		}
		if rt.dproc != nil {
			rt.dproc.Close()
		}
		rt.mu.Unlock()
	}
}

/** State：会话当前状态 */
func (m *Manager) State(id string) string {
	m.mu.Lock()
	rt, ok := m.rts[id]
	m.mu.Unlock()
	if !ok {
		return StateIdle
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.state
}

/** setState：切换状态并推送（调用方持有 rt.mu） */
func (m *Manager) setState(ctx context.Context, rt *runtime, st string) {
	if rt.state == st {
		return
	}
	rt.state = st
	m.setStateDirect(ctx, rt.id, st)
}

/** setStateDirect：写库并推送状态事件 */
func (m *Manager) setStateDirect(ctx context.Context, id, st string) {
	m.d.Store.UpdateSession(ctx, id, store.SessionPatch{State: &st})
	m.emit(ctx, id, "state", map[string]any{"state": st})
}

/**
 * emit：写入事件并推送
 *
 * 处理流程：
 * 1、追加事件得到序号
 * 2、按事件类型更新会话摘要
 * 3、广播给在线连接（与写库在同一把会话锁内，推送顺序与序号一致）
 */
func (m *Manager) emit(ctx context.Context, id, typ string, data map[string]any) error {
	if m.closed.Load() {
		return ErrClosed
	}
	// 已被接受的操作必须记录完整，不随手机断开连接而取消
	ctx = context.WithoutCancel(ctx)
	// 1、3、写库并在同一把会话锁内按序号广播
	_, err := m.d.Store.AppendEventThen(ctx, id, typ, data, func(e store.Event) {
		if m.d.Hub != nil {
			m.d.Hub.Publish(hub.Message{Session: id, Seq: e.Seq, Type: e.Type, Data: e.Data, CreatedAt: e.CreatedAt})
		}
	})
	if err != nil {
		slog.Warn("写入事件失败", "session", id, "type", typ, "err", err)
		return err
	}
	// 2、摘要
	if pv, ok := previewFor(typ, data); ok {
		m.d.Store.UpdateSession(ctx, id, store.SessionPatch{Preview: &pv})
	}
	return nil
}

/** notify：没有在线连接时发推送，内容不含正文 */
func (m *Manager) notify(ctx context.Context, kind, what string) {
	if m.d.Hub != nil && m.d.Hub.Count() > 0 {
		return
	}
	n := m.d.Notifier()
	title := agent.Short(kind) + " " + what
	go func() {
		c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
		defer cancel()
		if err := n.Notify(c, title, "PocketDesk"); err != nil {
			slog.Warn("推送失败", "err", err)
		}
	}()
}

/** previewFor：会话列表摘要 */
func previewFor(typ string, data map[string]any) (string, bool) {
	str := func(k string) string { s, _ := data[k].(string); return s }
	switch typ {
	case "msg.user":
		return "你：" + snippet(str("text"), 60), true
	case "msg.done":
		if t := str("text"); t != "" {
			return snippet(t, 60), true
		}
	case "approval.request":
		return "待确认：" + snippet(str("summary"), 50), true
	case "error":
		return "出错：" + snippet(str("message"), 50), true
	}
	return "", false
}

/** snippet：单行化并截断到 n 个字符 */
func snippet(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n]) + "…"
}

/** displayCwd：工作目录展示名 */
func displayCwd(c string) string {
	if c == "." || c == "" {
		return "工作区根目录"
	}
	return c
}

/**
 * Models：某 Agent 的可选模型；配置文件里写了列表时以配置为准，否则向 Agent 实时查询
 */
func (m *Manager) Models(ctx context.Context, kind string) []string {
	cfg := m.d.Config()
	if list := cfg.Models[kind]; len(list) > 0 {
		return list
	}
	d, ok := m.d.Registry.Get(kind)
	if !ok {
		return []string{}
	}
	qctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	return m.models.Get(qctx, d, cfg.Agents[kind], []string{})
}
