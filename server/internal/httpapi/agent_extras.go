/**
 * Agent 扩展接口：模型供应商（CC Switch）、skill 的查看与启用、电脑上已有会话的列表与接入、聊天记录同步。
 */
package httpapi

import (
	"context"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/ccswitch"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** agentRoutes：登记扩展接口（手机与桌面端共用） */
func (s *Server) agentRoutes(h func(pattern string, fn http.HandlerFunc)) {
	h("GET /api/agents/{kind}/providers", s.providers)
	h("GET /api/agents/{kind}/skills", s.skills)
	h("GET /api/agents/{kind}/skill", s.skillContent)
	h("PUT /api/agents/{kind}/skills", s.setSkill)
	h("GET /api/external", s.externalSessions)
	h("POST /api/sessions/import", s.importSession)
	h("POST /api/sessions/{id}/sync", s.syncSession)
}

/** providers：某 Agent 在 CC Switch 中的模型供应商，不含密钥 */
func (s *Server) providers(w http.ResponseWriter, r *http.Request) {
	kind := r.PathValue("kind")
	if !ccswitch.Available() || kind != agent.KindClaude && kind != agent.KindCodex {
		writeJSON(w, 200, map[string]any{"available": false, "list": []ccswitch.Provider{}})
		return
	}
	list, err := ccswitch.List(r.Context(), kind)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"available": true, "list": list})
}

/** skillDir：查询 skill 用的目录，带会话时取会话的工作目录 */
func (s *Server) skillDir(r *http.Request) (string, error) {
	id := r.URL.Query().Get("session")
	if id == "" {
		return "", nil
	}
	sess, err := s.Store.Session(r.Context(), id)
	if err != nil {
		return "", err
	}
	ws, err := s.Store.Workspace(r.Context(), sess.WorkspaceID)
	if err != nil {
		return "", err
	}
	return workspace.Resolve(ws.RootPath, sess.Cwd)
}

/** listSkills：某 Agent 可用的 skill */
func (s *Server) listSkills(r *http.Request) ([]agent.Skill, string, error) {
	cwd, err := s.skillDir(r)
	if err != nil {
		return nil, "", err
	}
	kind := r.PathValue("kind")
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	home, _ := os.UserHomeDir()
	list, err := agent.ListSkills(ctx, kind, home, cwd, s.Cfg.Get().Agents[kind])
	if errors.Is(err, agent.ErrUnsupported) {
		return nil, cwd, errf(400, "unsupported", "这个 Agent 暂不支持 skill")
	}
	return list, cwd, err
}

/** skills：skill 列表 */
func (s *Server) skills(w http.ResponseWriter, r *http.Request) {
	list, _, err := s.listSkills(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, list)
}

/** skillContent：skill 的说明全文（SKILL.md） */
func (s *Server) skillContent(w http.ResponseWriter, r *http.Request) {
	list, _, err := s.listSkills(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	text, err := agent.ReadSkill(list, r.URL.Query().Get("path"))
	if errors.Is(err, agent.ErrNoSkill) {
		writeErr(w, r, errf(404, "not_found", err.Error()))
		return
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]string{"text": text})
}

/** setSkill：启用或停用 skill */
func (s *Server) setSkill(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Path    string `json:"path"`
		Enabled bool   `json:"enabled"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	list, cwd, err := s.listSkills(r)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	var name string
	for _, sk := range list {
		if sk.Path == in.Path {
			name = sk.Name
		}
	}
	if name == "" {
		writeErr(w, r, errf(404, "not_found", agent.ErrNoSkill.Error()))
		return
	}
	kind := r.PathValue("kind")
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	home, _ := os.UserHomeDir()
	if err := agent.SetSkill(ctx, kind, home, cwd, s.Cfg.Get().Agents[kind], name, in.Path, in.Enabled); err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "skill.set", map[string]any{"kind": kind, "name": name, "enabled": in.Enabled})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** externalItem：电脑上的一条会话，附带所在工作区与已接入的聊天 */
type externalItem struct {
	agent.External
	// WorkspaceID、RelCwd：目录所在的工作区与相对路径，不在任何工作区时为空
	WorkspaceID string `json:"workspaceId"`
	RelCwd      string `json:"relCwd"`
	// Session：已经接入过的聊天 ID，再次选择时直接打开它
	Session string `json:"session"`
}

/** findWorkspace：包含某目录的工作区（取最深的一个）与相对路径 */
func findWorkspace(list []store.Workspace, dir string) (store.Workspace, string, bool) {
	var best store.Workspace
	bestRel, found := "", false
	for _, w := range list {
		root := filepath.Clean(w.RootPath)
		rel, err := filepath.Rel(root, filepath.Clean(dir))
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
			continue
		}
		if !found || len(root) > len(filepath.Clean(best.RootPath)) {
			best, bestRel, found = w, filepath.ToSlash(rel), true
		}
	}
	return best, bestRel, found
}

/**
 * externalSessions：电脑上最近的 Claude Code 与 Codex 会话（不限目录）
 *
 * 处理流程：
 * 1、扫描本机会话记录
 * 2、标出所在工作区，以及已经在 PocketDesk 里接入过的聊天
 */
func (s *Server) externalSessions(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 60
	}
	// 1、扫描
	home, _ := os.UserHomeDir()
	list := agent.ListExternal(home, []string{agent.KindClaude, agent.KindCodex}, limit)
	// 2、工作区与已接入
	wss, err := s.Store.Workspaces(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	sessions, err := s.Store.Sessions(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	known := map[string]string{}
	for _, x := range sessions {
		if x.AgentSessionID != "" {
			known[x.Kind+"\x00"+x.AgentSessionID] = x.ID
		}
	}
	out := make([]externalItem, 0, len(list))
	for _, e := range list {
		it := externalItem{External: e, Session: known[e.Kind+"\x00"+e.ID]}
		if ws, rel, ok := findWorkspace(wss, e.Cwd); ok {
			it.WorkspaceID, it.RelCwd = ws.ID, rel
		}
		out = append(out, it)
	}
	writeJSON(w, 200, out)
}

/**
 * importSession：接着电脑上的会话聊
 *
 * 处理流程：
 * 1、已经接入过的直接返回原聊天
 * 2、找到目录所在的工作区；不在任何工作区时提示先把目录加为工作区
 * 3、新建聊天并导入电脑上最近的对话
 */
func (s *Server) importSession(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Kind           string `json:"kind"`
		AgentSessionID string `json:"agentSessionId"`
		Cwd            string `json:"cwd"`
		// Title：电脑上原会话的标题，用作聊天名称
		Title string `json:"title"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	if in.Kind != agent.KindClaude && in.Kind != agent.KindCodex || in.AgentSessionID == "" || !filepath.IsAbs(in.Cwd) {
		writeErr(w, r, errf(400, "bad_request", "参数不正确"))
		return
	}
	// 1、已接入
	sessions, err := s.Store.Sessions(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	for _, x := range sessions {
		if x.Kind == in.Kind && x.AgentSessionID == in.AgentSessionID {
			s.Sessions.Sync(r.Context(), x.ID)
			writeJSON(w, 200, x)
			return
		}
	}
	// 2、工作区
	wss, err := s.Store.Workspaces(r.Context())
	if err != nil {
		writeErr(w, r, err)
		return
	}
	ws, rel, ok := findWorkspace(wss, in.Cwd)
	if !ok {
		writeErr(w, r, errf(409, "no_workspace", "这个会话的目录还不是工作区"))
		return
	}
	// 3、接入
	sess, err := s.Sessions.Import(r.Context(), in.Kind, in.AgentSessionID, ws.ID, rel, in.Title)
	if errors.Is(err, agent.ErrNoTranscript) {
		writeErr(w, r, errf(404, "not_found", err.Error()))
		return
	}
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "session.import", map[string]any{"id": sess.ID, "kind": sess.Kind, "agentSession": in.AgentSessionID, "cwd": in.Cwd})
	s.Hub.PublishGlobal("session.created", sess)
	writeJSON(w, 201, sess)
}

/** syncSession：补上电脑上新增的对话（打开聊天时调用） */
func (s *Server) syncSession(w http.ResponseWriter, r *http.Request) {
	if err := s.Sessions.Sync(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}
