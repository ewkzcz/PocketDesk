/**
 * 审批：登记请求、推送审批卡片、等待手机决定或 10 分钟超时按拒绝处理，支持「本会话总是允许此类操作」。
 */
package session

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** 审批动作 */
const (
	ActionAllow  = "allow"
	ActionDeny   = "deny"
	ActionAlways = "always"
)

/** ErrBadAction：未知的审批动作 */
var ErrBadAction = errors.New("未知的审批动作")

/** pending：等待中的审批 */
type pending struct {
	sessionID string
	pattern   string
	ch        chan agent.Decision
}

/** sessionApprover：把驱动的审批请求绑定到会话 */
type sessionApprover struct {
	m    *Manager
	sid  string
	auto bool
}

/** RequestApproval：实现 agent.Approver；免审批会话直接放行 */
func (a *sessionApprover) RequestApproval(ctx context.Context, req agent.ApprovalRequest) (agent.Decision, error) {
	if a.auto {
		return agent.Decision{Allow: true}, nil
	}
	return a.m.requestApproval(ctx, a.sid, req)
}

/** rulePattern：「此类操作」按工具类别归类，类别未知时按工具名 */
func rulePattern(req agent.ApprovalRequest) string {
	if req.Kind != "" && req.Kind != "other" {
		return "kind:" + req.Kind
	}
	return "tool:" + req.Tool
}

/**
 * requestApproval：请求审批并阻塞等待
 *
 * 处理流程：
 * 1、命中「总是允许」规则直接放行
 * 2、登记审批、推送卡片与通知，状态切到待审批
 * 3、等待决定、上下文取消或超时（超时按拒绝）
 * 4、没有其他待审批时状态回到执行中
 */
func (m *Manager) requestApproval(ctx context.Context, sid string, req agent.ApprovalRequest) (agent.Decision, error) {
	pattern := rulePattern(req)
	// 1、规则
	rules, _ := m.d.Store.Rules(ctx, sid)
	for _, r := range rules {
		if r == pattern {
			return agent.Decision{Allow: true}, nil
		}
	}
	// 2、登记
	raw, _ := json.Marshal(req)
	a, err := m.d.Store.CreateApproval(context.WithoutCancel(ctx), store.Approval{ID: security.NewID(), SessionID: sid, Request: raw})
	if err != nil {
		return agent.Decision{}, err
	}
	p := &pending{sessionID: sid, pattern: pattern, ch: make(chan agent.Decision, 1)}
	m.mu.Lock()
	m.pend[a.ID] = p
	m.mu.Unlock()
	expires := m.now().Add(m.approvalTimeout)
	rt, err := m.runtime(ctx, sid)
	if err != nil {
		return agent.Decision{}, err
	}
	rt.mu.Lock()
	m.emit(ctx, sid, "approval.request", map[string]any{"id": a.ID, "tool": req.Tool, "kind": req.Kind, "summary": req.Summary, "input": trimInput(req.Input), "expiresAt": expires.UnixMilli()})
	if rt.state == StateRunning {
		m.setState(ctx, rt, StateAwaiting)
	}
	sess := rt.sess
	rt.mu.Unlock()
	m.notify(ctx, sess, "会话需要审批", a.ID)
	// 3、等待
	timer := time.NewTimer(m.approvalTimeout)
	defer timer.Stop()
	var d agent.Decision
	select {
	case d = <-p.ch:
	case <-ctx.Done():
		d = agent.Decision{Reason: "请求已取消"}
		if !m.closePending(context.WithoutCancel(ctx), a.ID, store.ApprovalDenied, "system") {
			d = <-p.ch
		}
	case <-timer.C:
		d = agent.Decision{Reason: "10 分钟未处理，已按拒绝处理"}
		if !m.closePending(context.WithoutCancel(ctx), a.ID, store.ApprovalExpired, "system") {
			d = <-p.ch
		}
	}
	// 4、状态
	m.afterDecision(context.WithoutCancel(ctx), sid)
	return d, nil
}

/** afterDecision：会话没有待审批时从待审批回到执行中 */
func (m *Manager) afterDecision(ctx context.Context, sid string) {
	m.mu.Lock()
	left := 0
	for _, p := range m.pend {
		if p.sessionID == sid {
			left++
		}
	}
	rt := m.rts[sid]
	m.mu.Unlock()
	if left > 0 || rt == nil {
		return
	}
	rt.mu.Lock()
	if rt.state == StateAwaiting {
		m.setState(ctx, rt, StateRunning)
	}
	rt.mu.Unlock()
}

/**
 * closePending：以指定状态关闭一个待审批（超时、取消、打断），已被他处处理时返回 false
 */
func (m *Manager) closePending(ctx context.Context, id, status, by string) bool {
	m.mu.Lock()
	p, ok := m.pend[id]
	delete(m.pend, id)
	m.mu.Unlock()
	if !ok {
		return false
	}
	if err := m.d.Store.DecideApproval(ctx, id, status, by); err == nil {
		m.emit(ctx, p.sessionID, "approval.done", map[string]any{"id": id, "status": status})
	}
	select {
	case p.ch <- agent.Decision{Reason: "已拒绝"}:
	default:
	}
	return true
}

/** denyPending：拒绝某会话全部待审批（调用方可持有 rt.mu） */
func (m *Manager) denyPending(ctx context.Context, sid, reason string) {
	m.mu.Lock()
	var ids []string
	for id, p := range m.pend {
		if p.sessionID == sid {
			ids = append(ids, id)
		}
	}
	m.mu.Unlock()
	sort.Strings(ids)
	for _, id := range ids {
		m.closePending(ctx, id, store.ApprovalDenied, "system")
	}
}

/**
 * Decide：手机上的审批决定
 *
 * 处理流程：
 * 1、校验动作，找到等待中的审批
 * 2、写库（只生效一次），总是允许时保存规则
 * 3、推送结果并唤醒等待方
 */
func (m *Manager) Decide(ctx context.Context, id, action, deviceID string) error {
	// 1、校验
	status := store.ApprovalDenied
	switch action {
	case ActionAllow, ActionAlways:
		status = store.ApprovalAllowed
	case ActionDeny:
	default:
		return ErrBadAction
	}
	m.mu.Lock()
	p, ok := m.pend[id]
	if ok {
		delete(m.pend, id)
	}
	m.mu.Unlock()
	if !ok {
		if _, err := m.d.Store.Approval(ctx, id); err != nil {
			return err
		}
		return store.ErrAlreadyDecided
	}
	// 2、写库
	if err := m.d.Store.DecideApproval(ctx, id, status, deviceID); err != nil {
		return err
	}
	if action == ActionAlways {
		m.d.Store.AddRule(ctx, p.sessionID, p.pattern)
	}
	// 3、推送与唤醒
	m.emit(ctx, p.sessionID, "approval.done", map[string]any{"id": id, "status": status, "always": action == ActionAlways})
	p.ch <- agent.Decision{Allow: status == store.ApprovalAllowed, Always: action == ActionAlways}
	return nil
}

/** ApproveForClaude：MCP 审批工具转来的请求，返回 Claude 约定格式 */
func (m *Manager) ApproveForClaude(ctx context.Context, sid, tool string, input map[string]any) (map[string]any, error) {
	kind, summary := agent.SummarizeClaudeTool(tool, input)
	d, err := m.requestApproval(ctx, sid, agent.ApprovalRequest{Tool: tool, Kind: kind, Summary: summary, Input: input})
	if err != nil {
		return nil, err
	}
	return agent.ClaudeBehavior(d, input), nil
}

/** trimInput：审批卡片中的参数，过长的字符串截断 */
func trimInput(in map[string]any) map[string]any {
	if in == nil {
		return nil
	}
	out := make(map[string]any, len(in))
	for k, v := range in {
		if s, ok := v.(string); ok {
			out[k] = agent.Truncate(s, 4000)
			continue
		}
		out[k] = v
	}
	return out
}

/** sortChanges：按路径排序 */
func sortChanges(fs []FileChange) {
	sort.Slice(fs, func(i, j int) bool { return fs[i].Path < fs[j].Path })
}
