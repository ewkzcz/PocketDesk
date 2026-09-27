/**
 * 会话接口：列表、新建（Agent 或终端）、修改、事件补拉、发送消息、打断、重试、改动、审批、模型与历史会话。
 */
package httpapi

import (
	"net/http"
	"os"
	"strconv"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/session"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/terminal"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** listSessions：全部会话，置顶优先 */
func (s *Server) listSessions(w http.ResponseWriter, r *http.Request) {
	list, err := s.Store.Sessions(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, list)
}

/**
 * createSession：新建会话
 *
 * 处理流程：
 * 1、终端类型交给终端管理器
 * 2、Agent 类型交给会话管理器，带旧会话 ID 时用于续聊
 * 3、记录审计
 */
func (s *Server) createSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Kind           string `json:"kind"`
		WorkspaceID    string `json:"workspaceId"`
		Cwd            string `json:"cwd"`
		Model          string `json:"model"`
		AgentSessionID string `json:"agentSessionId"`
		Cols           int    `json:"cols"`
		Rows           int    `json:"rows"`
		Command        string `json:"command"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	var sess store.Session
	var err error
	// 1、终端
	if in.Kind == terminal.Kind {
		sess, err = s.Terms.Create(r.Context(), terminal.Options{WorkspaceID: in.WorkspaceID, Cwd: in.Cwd, Cols: in.Cols, Rows: in.Rows, Command: in.Command})
	} else {
		// 2、Agent
		sess, err = s.Sessions.Create(r.Context(), in.Kind, in.WorkspaceID, in.Cwd, in.Model)
		if err == nil && in.AgentSessionID != "" {
			sess, err = s.Store.UpdateSession(r.Context(), sess.ID, store.SessionPatch{AgentSessionID: &in.AgentSessionID})
		}
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 3、审计
	s.audit(r, "session.create", map[string]any{"id": sess.ID, "kind": sess.Kind, "ws": sess.WorkspaceID, "cwd": sess.Cwd, "command": in.Command})
	s.Hub.PublishGlobal("session.created", sess)
	writeJSON(w, 201, sess)
}

/** getSession：单个会话 */
func (s *Server) getSession(w http.ResponseWriter, r *http.Request) {
	sess, err := s.Store.Session(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, sess)
}

/** patchSession：改名、置顶、切换模型或目录 */
func (s *Server) patchSession(w http.ResponseWriter, r *http.Request) {
	var p session.Patch
	if err := readJSON(r, &p); err != nil {
		writeErr(w, r, err)
		return
	}
	id := r.PathValue("id")
	var sess store.Session
	var err error
	if id == AssistantID {
		sess, err = s.Store.UpdateSession(r.Context(), id, store.SessionPatch{Pinned: p.Pinned})
	} else {
		sess, err = s.Sessions.Update(r.Context(), id, p)
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.Hub.PublishGlobal("session.updated", sess)
	writeJSON(w, 200, sess)
}

/** deleteSession：结束终端会话（Agent 会话只在手机上删除记录，电脑上保留） */
func (s *Server) deleteSession(w http.ResponseWriter, r *http.Request) {
	sess, err := s.Store.Session(r.Context(), r.PathValue("id"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if sess.Kind != terminal.Kind {
		writeErr(w, r, errf(400, "not_terminal", "只能结束终端会话"))
		return
	}
	if err := s.Terms.Close(sess.ID); err != nil && err != terminal.ErrNotFound {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "terminal.close", map[string]string{"id": sess.ID})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** events：按序号补拉（after）或向前加载（before） */
func (s *Server) events(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	id := r.PathValue("id")
	if _, err := s.Store.Session(r.Context(), id); err != nil {
		writeErr(w, r, err)
		return
	}
	var evs []store.Event
	var err error
	if b := q.Get("before"); b != "" {
		before, _ := strconv.ParseInt(b, 10, 64)
		evs, err = s.Store.EventsBefore(r.Context(), id, before, limit)
	} else {
		after, _ := strconv.ParseInt(q.Get("after"), 10, 64)
		evs, err = s.Store.EventsAfter(r.Context(), id, after, limit)
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, evs)
}

/** sendMessage：发送消息（含附件路径），提示词写入审计 */
func (s *Server) sendMessage(w http.ResponseWriter, r *http.Request) {
	var in session.Input
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	id := r.PathValue("id")
	if err := s.Sessions.Send(r.Context(), id, in); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "message.send", map[string]any{"session": id, "text": in.Text, "attachments": in.Attachments, "mode": in.Mode, "delegate": in.Delegate})
	writeJSON(w, 202, map[string]bool{"ok": true})
}

/** interrupt：打断 */
func (s *Server) interrupt(w http.ResponseWriter, r *http.Request) {
	if err := s.Sessions.Interrupt(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "session.interrupt", map[string]string{"session": r.PathValue("id")})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** retry：重试上一条 */
func (s *Server) retry(w http.ResponseWriter, r *http.Request) {
	if err := s.Sessions.Retry(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 202, map[string]bool{"ok": true})
}

/** diff：累计改动清单或单个文件差异 */
func (s *Server) diff(w http.ResponseWriter, r *http.Request) {
	p := r.URL.Query().Get("path")
	res, err := s.Sessions.Diff(r.Context(), r.PathValue("id"), p)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	if text, ok := res.(string); ok {
		writeJSON(w, 200, map[string]string{"path": p, "diff": text})
		return
	}
	writeJSON(w, 200, res)
}

/** decide：审批 */
func (s *Server) decide(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Action string `json:"action"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.Sessions.Decide(r.Context(), r.PathValue("id"), in.Action, deviceOf(r).ID); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "approval.decide", map[string]string{"id": r.PathValue("id"), "action": in.Action})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** models：某 Agent 可选模型 */
func (s *Server) models(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, s.Sessions.Models(r.Context(), r.PathValue("kind")))
}

/**
 * history：电脑上某目录已有的 Agent 会话（/resume）
 *
 * 处理流程：
 * 1、解析工作区与目录为绝对路径
 * 2、扫描当前用户的会话记录
 */
func (s *Server) history(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	// 1、目录
	ws, err := s.Store.Workspace(r.Context(), q.Get("workspaceId"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	cwd, err := workspace.Resolve(ws.RootPath, q.Get("cwd"))
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 2、扫描
	home, _ := os.UserHomeDir()
	writeJSON(w, 200, agent.ListHistory(r.PathValue("kind"), home, cwd, 30))
}
