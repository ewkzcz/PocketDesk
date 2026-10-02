/**
 * 会话管理器：维护每个会话的 Agent 进程与状态机，写入事件并推送，处理排队、打断、恢复与改动清单。
 */
package session

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
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
	// Home：Agent 会话记录所在的用户主目录，测试时替换
	Home func() string
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
	// base：本轮写过的文件在改动前的内容（按绝对路径），用于统计行数和查看差异
	base map[string]*baseline
	// patch：Agent 自带的差异文本，改动前内容没记下时使用
	patch map[string]string
	// probes：命令里提到的文件，本轮结束时看是否有变化
	probes map[string]bool
	// dir：非 git 目录在本轮开始时的文件状态（文件太多时为空）
	dir  map[string]string
	home string
}

/** Input：一条发送请求 */
type Input struct {
	Text        string   `json:"text"`
	Attachments []string `json:"attachments"`
	ClientID    string   `json:"clientId"`
}

/** New：创建管理器 */
func New(d Deps) *Manager {
	if d.Notifier == nil {
		d.Notifier = func() notify.Notifier { return notify.Nop{} }
	}
	if d.Home == nil {
		d.Home = func() string {
			h, _ := os.UserHomeDir()
			return h
		}
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
	return m.CreateWith(ctx, NewSession{Kind: kind, WorkspaceID: wsID, Cwd: cwd, Model: model})
}

/** NewSession：新建会话的参数 */
type NewSession struct {
	Kind        string
	WorkspaceID string
	Cwd         string
	Model       string
	// AutoApprove：免审批会话
	AutoApprove bool
}

/** CreateWith：按参数新建会话 */
func (m *Manager) CreateWith(ctx context.Context, n NewSession) (store.Session, error) {
	kind, wsID, cwd, model := n.Kind, n.WorkspaceID, n.Cwd, n.Model
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
	s, err := m.d.Store.CreateSession(ctx, store.Session{ID: security.NewID(), Kind: kind, Title: agent.Label(kind), WorkspaceID: wsID, Cwd: rel, Model: model, State: StateIdle, AutoApprove: n.AutoApprove})
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
 * 2、执行中：排队，本轮结束后再发送
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
	if rt.sess.Title == agent.Label(rt.sess.Kind) && in.Text != "" {
		title := agent.Label(rt.sess.Kind) + " · " + snippet(in.Text, 16)
		if s, err := m.d.Store.UpdateSession(ctx, id, store.SessionPatch{Title: &title}); err == nil {
			rt.sess = s
		}
	}
	busy := rt.state == StateRunning || rt.state == StateAwaiting || rt.state == StateInterrupted
	// 2、执行中
	if busy {
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
	if err := m.emit(ctx, rt.id, "msg.user", map[string]any{"text": in.Text, "attachments": in.Attachments, "queued": queued, "clientId": in.ClientID}); err != nil {
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
 * 2、确保进程已启动
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
	rt.turn = &turn{snap: snapshot(ctx, cwd), writes: map[string]bool{}, cwd: cwd, base: map[string]*baseline{}, patch: map[string]string{}, probes: map[string]bool{}, home: m.d.Home()}
	if !rt.turn.snap.repo {
		rt.turn.dir = dirSnapshot(cwd)
	}
	// 2、进程
	if rt.proc == nil {
		rt.proc, err = m.startProc(ctx, rt, rt.sess.Kind, cwd, rt.sess.AgentSessionID, rt.sess.Model)
	}
	proc := rt.proc
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
	opt := agent.Options{Cwd: cwd, Model: model, ResumeID: resume, Command: cfg.Agents[kind], Approver: &sessionApprover{m: m, sid: rt.id, auto: rt.sess.AutoApprove}, AutoApprove: rt.sess.AutoApprove}
	if kind == agent.KindClaude && m.d.ApproveCmd != nil && !rt.sess.AutoApprove {
		opt.ApproveCmd = m.d.ApproveCmd(rt.id)
	}
	p, err := d.Start(ctx, opt)
	if err != nil {
		return nil, err
	}
	go m.pump(rt, p)
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
func (m *Manager) pump(rt *runtime, p agent.Process) {
	ctx := context.Background()
	var pend *agent.Event
	var timer *time.Timer
	var tick <-chan time.Time
	flush := func() {
		if pend != nil {
			m.handle(ctx, rt, p, *pend)
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
			m.handle(ctx, rt, p, e)
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
 * 1、会话 ID：保存用于续聊
 * 2、写文件记录：加入本轮改动
 * 3、本轮结束：生成改动清单并处理排队
 * 4、其他：写库推送
 * 写文件与改动前内容的记录只用于本轮改动清单，不推送
 */
func (m *Manager) handle(ctx context.Context, rt *runtime, p agent.Process, e agent.Event) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	switch e.Type {
	// 1、会话 ID
	case agent.EvSessionID:
		if p != rt.proc {
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
	case agent.EvFileWrite, agent.EvFileBase:
		if rt.turn != nil {
			if p, _ := e.Data["path"].(string); p != "" {
				if e.Type == agent.EvFileWrite {
					rt.turn.writes[p] = true
				}
				rt.turn.noteBase(absWrite(rt.turn.cwd, p), e.Data)
			}
		}
	// 3、本轮结束
	case agent.EvTurnEnd:
		if p == rt.proc {
			m.finishTurn(ctx, rt, p)
		}
	// 4、其他；执行命令前记下命令里提到的文件，找出命令生成或修改的文件
	default:
		if e.Type == agent.EvToolStart && rt.turn != nil {
			if cmd := commandText(e.Data["input"]); cmd != "" {
				rt.turn.probe(cmd)
			}
		}
		m.emit(ctx, rt.id, e.Type, e.Data)
	}
}

/**
 * finishTurn：本轮收尾（调用方持有 rt.mu）
 *
 * 处理流程：
 * 1、生成并推送改动清单
 * 2、状态回到空闲，清零异常计数
 * 3、推送完成通知
 * 4、排队中有消息则自动发送下一条
 */
func (m *Manager) finishTurn(ctx context.Context, rt *runtime, p agent.Process) {
	// 1、改动清单
	if rt.turn != nil {
		files, git := m.turnChanges(ctx, rt.id, rt.turn)
		if len(files) > 0 {
			m.emit(ctx, rt.id, "diff.summary", map[string]any{"files": files, "git": git})
			preview := fmt.Sprintf("已完成：改动了 %d 个文件", len(files))
			m.d.Store.UpdateSession(ctx, rt.id, store.SessionPatch{Preview: &preview})
		}
		rt.turn = nil
	}
	// 2、状态
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

/**
 * turnChanges：本轮改动清单
 *
 * 处理流程：
 * 1、git 仓库用快照对比，再补上仓库之外的写文件记录；否则用写文件记录；再补上命令生成或修改的文件
 * 2、记下了改动前内容的文件，按前后内容重新统计行数并保存差异，没有实际变化的写文件记录去掉
 */
func (m *Manager) turnChanges(ctx context.Context, sid string, t *turn) ([]FileChange, bool) {
	// 1、清单
	var out []FileChange
	if t.snap.repo {
		out = append(changedSince(ctx, t.snap), outsideWrites(t.snap.root, t.writes, t.cwd)...)
	} else {
		for p := range t.writes {
			rel := p
			if filepath.IsAbs(p) {
				if r, err := filepath.Rel(t.cwd, p); err == nil && !strings.HasPrefix(r, "..") {
					rel = filepath.ToSlash(r)
				}
			}
			abs := absWrite(t.cwd, p)
			status := "modified"
			if _, err := os.Stat(abs); err != nil {
				status = "deleted"
			}
			out = append(out, FileChange{Path: rel, Abs: abs, Status: status})
		}
	}
	out = append(out, t.commandChanges(out)...)
	// 2、行数与差异
	kept := out[:0]
	for i, fc := range out {
		if keep := m.measure(ctx, sid, t, &fc, i); keep {
			kept = append(kept, fc)
		}
	}
	sortChanges(kept)
	return kept, t.snap.repo
}

/**
 * onExit：进程退出处理
 *
 * 处理流程：
 * 1、不是当前进程（已被替换）只做清理
 * 2、空闲时退出：清空进程，下次发送时再启动
 * 3、打断后被强制结束：回到空闲
 * 4、执行中异常退出：未超过上限则用会话 ID 重启并提示已恢复，否则进入出错状态
 */
func (m *Manager) onExit(ctx context.Context, rt *runtime, p agent.Process) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	// 1、非当前进程
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
		still := rt.state == StateInterrupted && rt.proc == p
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

/** Diff：本会话工作目录的累计改动或单个文件差异；带编号时返回那一轮保存的差异 */
func (m *Manager) Diff(ctx context.Context, id, path, ref string) (any, error) {
	if ref != "" {
		text, err := m.d.Store.Diff(ctx, id, ref)
		if errors.Is(err, store.ErrNotFound) {
			return nil, ErrNoDiff
		}
		return text, err
	}
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
	if !git {
		files = m.recorded(ctx, id)
	}
	if files == nil {
		files = []FileChange{}
	}
	return map[string]any{"files": files, "git": git}, nil
}

/**
 * recorded：不是 git 仓库时，本会话累计改动取各轮改动清单，同一文件以最近一轮为准
 */
func (m *Manager) recorded(ctx context.Context, id string) []FileChange {
	evs, err := m.d.Store.EventsOfType(ctx, id, "diff.summary")
	if err != nil {
		return nil
	}
	latest := map[string]FileChange{}
	for _, e := range evs {
		var d struct {
			Files []FileChange `json:"files"`
		}
		if json.Unmarshal(e.Data, &d) != nil {
			continue
		}
		for _, f := range d.Files {
			latest[f.Path] = f
		}
	}
	out := make([]FileChange, 0, len(latest))
	for _, f := range latest {
		out = append(out, f)
	}
	sortChanges(out)
	return out
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

/** baseline：本轮第一次写某文件之前的内容 */
type baseline struct {
	text    string
	existed bool
	// skip：太大或不是文本，不做逐行对比
	skip bool
	// firm：来自 Agent 工具结果里的原文，比事前读取更可靠，不再被覆盖
	firm bool
	// office：Word、PowerPoint、Excel 文件，text 为取出的文字内容
	office bool
	// sig：修改时间与大小，用于判断二进制文件有没有变化
	sig string
}

/** maxBaseline：参与逐行对比的文件大小上限 */
const maxBaseline = 2 << 20

/**
 * noteBase：记下文件改动前的内容
 *
 * 处理流程：
 * 1、Agent 自带差异文本时保存，作为兜底
 * 2、工具结果带原文时以原文为准（仅限本轮第一次写这个文件）
 * 3、否则第一次出现时立即读取磁盘上的内容
 */
func (t *turn) noteBase(abs string, data map[string]any) {
	// 1、差异文本
	if p, _ := data["patch"].(string); p != "" {
		if _, ok := t.patch[abs]; !ok {
			t.patch[abs] = p
		}
	}
	cur := t.base[abs]
	// 2、工具结果原文
	if orig, ok := data["original"].(string); ok {
		if cur == nil || !cur.firm {
			existed, _ := data["existed"].(bool)
			t.base[abs] = &baseline{text: orig, existed: existed, firm: true, skip: len(orig) > maxBaseline}
		}
		return
	}
	// 3、读取磁盘
	if cur == nil {
		t.base[abs] = readBaseline(abs)
	}
}

/** readBaseline：读取文件当前内容，不存在记为新建；Office 文件取文字内容，过大或其他二进制只记修改时间与大小 */
func readBaseline(abs string) *baseline {
	info, err := os.Stat(abs)
	if err != nil {
		return &baseline{}
	}
	sig := sigOf(abs)
	if isOffice(abs) && info.Size() <= maxOffice {
		if text, ok := officeText(abs); ok {
			return &baseline{text: text, existed: true, office: true, sig: sig}
		}
	}
	if info.IsDir() || info.Size() > maxBaseline {
		return &baseline{existed: true, skip: true, sig: sig}
	}
	b, err := os.ReadFile(abs)
	if err != nil || isBinary(b) {
		return &baseline{existed: true, skip: true, sig: sig}
	}
	return &baseline{text: string(b), existed: true, sig: sig}
}

/** isBinary：前 8KB 含零字节视为二进制 */
func isBinary(b []byte) bool {
	n := len(b)
	if n > 8192 {
		n = 8192
	}
	for _, c := range b[:n] {
		if c == 0 {
			return true
		}
	}
	return false
}

/**
 * measure：按改动前后内容统计一个文件的增删行数并保存差异，返回是否保留在清单里
 *
 * 处理流程：
 * 1、Office 文件：对比取出的文字内容
 * 2、其他二进制文件：只标记为二进制改动
 * 3、文本文件：与改动前内容逐行对比；工具结果原文与当前内容一致且只来自写文件记录时去掉
 * 4、没有改动前内容但 Agent 给了差异文本：按差异文本统计
 * 5、保存差异文本并带上编号，手机点开时按编号读取
 */
func (m *Manager) measure(ctx context.Context, sid string, t *turn, fc *FileChange, i int) bool {
	abs := fc.Abs
	if abs == "" {
		return true
	}
	var text string
	b := t.base[abs]
	// 新出现的文件没有改动前内容，按空文件对比
	if b == nil && fc.Status == "added" {
		b = &baseline{}
	}
	name := fc.Path
	if filepath.IsAbs(name) {
		name = filepath.Base(name)
	}
	switch {
	// 1、Office 文件对比文字内容，文字没变但文件变了（例如只改了格式）记为二进制改动
	case b != nil && (b.office || !b.existed && isOffice(abs)):
		now := readBaseline(abs)
		if now.existed && !now.office {
			fc.Binary, fc.Added, fc.Removed = true, 0, 0
			return true
		}
		fc.Added, fc.Removed, text = unifiedDiff(filepath.ToSlash(name)+"（文字内容）", b.text, now.text, b.existed, now.existed)
		if !now.existed {
			fc.Status = "deleted"
		} else if !b.existed {
			fc.Status = "added"
		}
		if text == "" {
			fc.Binary = true
			return b.sig != now.sig || !b.firm
		}
	// 2、其他二进制文件只记录有变化
	case b != nil && b.skip:
		fc.Binary, fc.Added, fc.Removed = true, 0, 0
		if sigOf(abs) == "" {
			fc.Status = "deleted"
		}
		return true
	// 3、文本前后对比
	case b != nil:
		now := readBaseline(abs)
		if now.skip || now.office {
			fc.Binary, fc.Added, fc.Removed = true, 0, 0
			return true
		}
		fc.Added, fc.Removed, text = unifiedDiff(filepath.ToSlash(name), b.text, now.text, b.existed, now.existed)
		if text == "" {
			// 原文可靠且来自写文件记录时去掉；git 看到的改动（例如先改后还原）与事后才读到的内容保留原样
			return !b.firm || t.snap.repo && !filepath.IsAbs(fc.Path)
		}
		switch {
		case !b.existed && now.existed:
			fc.Status = "added"
		case b.existed && !now.existed:
			fc.Status = "deleted"
		}
	// 4、Agent 差异
	case t.patch[abs] != "":
		text = t.patch[abs]
		fc.Added, fc.Removed = 0, 0
		for _, l := range strings.Split(text, "\n") {
			switch {
			case strings.HasPrefix(l, "+++") || strings.HasPrefix(l, "---"):
			case strings.HasPrefix(l, "+"):
				fc.Added++
			case strings.HasPrefix(l, "-"):
				fc.Removed++
			}
		}
	default:
		return true
	}
	// 5、保存
	if len(text) > 512<<10 {
		text = text[:512<<10] + "\n…"
	}
	ref := fmt.Sprintf("%d-%d", m.now().UnixMilli(), i)
	if err := m.d.Store.SaveDiff(ctx, sid, ref, text); err == nil {
		fc.Ref = ref
	}
	return true
}

/**
 * commandChanges：命令生成或修改的文件（清单里还没有的）
 *
 * 处理流程：
 * 1、命令里提到的文件：修改时间或大小有变化即计入
 * 2、非 git 工作目录：与本轮开始时的文件状态对比，新出现、变化与消失的文件计入
 */
func (t *turn) commandChanges(have []FileChange) []FileChange {
	present := map[string]bool{}
	for _, fc := range have {
		present[canon(fc.Abs)] = true
	}
	cwd := t.cwd
	if r, err := filepath.EvalSymlinks(cwd); err == nil {
		cwd = r
	}
	var out []FileChange
	add := func(abs, status string) {
		if present[abs] {
			return
		}
		present[abs] = true
		path := abs
		if r, err := filepath.Rel(cwd, abs); err == nil && r != ".." && !strings.HasPrefix(r, ".."+string(filepath.Separator)) {
			path = filepath.ToSlash(r)
		}
		out = append(out, FileChange{Path: path, Abs: abs, Status: status})
	}
	status := func(existed bool, now string) string {
		switch {
		case now == "":
			return "deleted"
		case !existed:
			return "added"
		}
		return "modified"
	}
	// 1、命令里提到的文件
	probes := make([]string, 0, len(t.probes))
	for p := range t.probes {
		probes = append(probes, p)
	}
	sort.Strings(probes)
	for _, p := range probes {
		b := t.base[p]
		if now := sigOf(p); b != nil && now != b.sig {
			add(p, status(b.existed, now))
		}
	}
	// 2、工作目录
	if t.dir == nil {
		return out
	}
	now := dirSnapshot(t.cwd)
	if now == nil {
		return out
	}
	var paths []string
	for p := range now {
		paths = append(paths, p)
	}
	for p := range t.dir {
		if _, ok := now[p]; !ok {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	for _, p := range paths {
		before, existed := t.dir[p]
		if after := now[p]; after != before {
			add(p, status(existed, after))
		}
	}
	return out
}
