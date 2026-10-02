/**
 * Agent 扩展接口：模型供应商（CC Switch）、skill 的查看与启用。
 */
package httpapi

import (
	"context"
	"errors"
	"net/http"
	"os"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/ccswitch"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** agentRoutes：登记扩展接口（手机与桌面端共用） */
func (s *Server) agentRoutes(h func(pattern string, fn http.HandlerFunc)) {
	h("GET /api/agents/{kind}/providers", s.providers)
	h("GET /api/agents/{kind}/skills", s.skills)
	h("GET /api/agents/{kind}/skill", s.skillContent)
	h("PUT /api/agents/{kind}/skills", s.setSkill)
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
