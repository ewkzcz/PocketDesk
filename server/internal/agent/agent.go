/**
 * Agent 适配层公共定义：统一事件、驱动接口、审批回调与启动参数。
 */
package agent

import (
	"context"
	"errors"
	"sort"
)

/** Agent 类型 */
const (
	KindClaude = "claude"
	KindCodex  = "codex"
	KindPi     = "pi"
	KindDSH    = "dsh"
)

/** Kinds：全部 Agent 类型，按展示顺序 */
var Kinds = []string{KindClaude, KindCodex, KindPi, KindDSH}

/** 统一事件类型（与手机端约定一致） */
const (
	EvDelta     = "msg.delta"
	EvDone      = "msg.done"
	EvThinking  = "thinking"
	EvToolStart = "tool.start"
	EvToolEnd   = "tool.end"
	EvUsage     = "usage"
	EvError     = "error"
	EvSessionID = "agent.session"
	EvTurnEnd   = "turn.end"
	EvFileWrite = "file.write"
)

/** ErrUnsupported：驱动不支持该操作 */
var ErrUnsupported = errors.New("该 Agent 不支持此操作")

/** Event：驱动发出的统一事件 */
type Event struct {
	Type string
	Data map[string]any
}

/** ApprovalRequest：驱动请求用户审批的内容 */
type ApprovalRequest struct {
	Tool    string         `json:"tool"`
	Kind    string         `json:"kind"`
	Summary string         `json:"summary"`
	Input   map[string]any `json:"input,omitempty"`
	Options []string       `json:"options,omitempty"`
}

/** Decision：审批结果 */
type Decision struct {
	Allow  bool
	Always bool
	Reason string
}

/** Approver：由会话管理器提供，驱动在需要审批时阻塞调用 */
type Approver interface {
	RequestApproval(ctx context.Context, req ApprovalRequest) (Decision, error)
}

/** Message：发给 Agent 的一条用户消息 */
type Message struct {
	Text        string
	Attachments []string
}

/** Options：启动一个 Agent 进程所需参数 */
type Options struct {
	Cwd        string
	Model      string
	ResumeID   string
	Approver   Approver
	Command    []string
	Env        []string
	ApproveCmd []string
	// AutoApprove：免审批，所有操作直接放行（Claude Code 跳过权限确认，Codex 不审批不进沙箱）
	AutoApprove bool
}

/** Process：一个运行中的 Agent 会话进程 */
type Process interface {
	Send(ctx context.Context, m Message) error
	Steer(ctx context.Context, m Message) error
	Interrupt() error
	Events() <-chan Event
	Done() <-chan struct{}
	Err() error
	Close() error
}

/** Driver：一种 Agent 的接入方式 */
type Driver interface {
	Kind() string
	Start(ctx context.Context, opt Options) (Process, error)
	SupportsSteer() bool
}

/** Registry：按类型查找驱动 */
type Registry struct {
	drivers map[string]Driver
}

/** NewRegistry：登记驱动 */
func NewRegistry(ds ...Driver) *Registry {
	r := &Registry{drivers: map[string]Driver{}}
	for _, d := range ds {
		r.drivers[d.Kind()] = d
	}
	return r
}

/** Get：取驱动 */
func (r *Registry) Get(kind string) (Driver, bool) {
	d, ok := r.drivers[kind]
	return d, ok
}

/** List：已登记的类型 */
func (r *Registry) List() []string {
	out := make([]string, 0, len(r.drivers))
	for k := range r.drivers {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

/** Label：Agent 展示名 */
func Label(kind string) string {
	switch kind {
	case KindClaude:
		return "Claude Code"
	case KindCodex:
		return "Codex"
	case KindPi:
		return "Pi"
	case KindDSH:
		return "DSH"
	case "terminal":
		return "终端"
	}
	return kind
}

/** Short：通知中使用的两字母缩写 */
func Short(kind string) string {
	switch kind {
	case KindClaude:
		return "CC"
	case KindCodex:
		return "CX"
	case KindPi:
		return "Pi"
	case KindDSH:
		return "DS"
	}
	return kind
}

/** ev：构造事件的便捷函数 */
func ev(t string, kv ...any) Event {
	m := map[string]any{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	return Event{Type: t, Data: m}
}
