/**
 * Agent 扩展接口：模型供应商（CC Switch）。
 */
package httpapi

import (
	"net/http"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/ccswitch"
)

/** agentRoutes：登记扩展接口（手机与桌面端共用） */
func (s *Server) agentRoutes(h func(pattern string, fn http.HandlerFunc)) {
	h("GET /api/agents/{kind}/providers", s.providers)
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
