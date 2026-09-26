/**
 * 手机端接口路由：配对、电脑信息、工作区文件、传输、会话、审批、事件通道与终端通道。
 */
package httpapi

import (
	"context"
	"net/http"
	"runtime"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/netutil"
	"github.com/ewkzcz/pocketdesk/server/internal/outbox"
	"github.com/ewkzcz/pocketdesk/server/internal/pairing"
	"github.com/ewkzcz/pocketdesk/server/internal/power"
	"github.com/ewkzcz/pocketdesk/server/internal/render"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/session"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/terminal"
	"github.com/ewkzcz/pocketdesk/server/internal/tus"
)

/** Server：接口层依赖 */
type Server struct {
	Cfg      *config.Store
	Store    *store.Store
	Identity *security.Identity
	Pairing  *pairing.Manager
	Sessions *session.Manager
	Terms    *terminal.Manager
	Hub      *hub.Hub
	Tus      *tus.Server
	Outbox   *outbox.Service
	Render   *render.Renderer
	Power    *power.Keeper
	Version  string
	DataDir  string
	AdminKey string
	LogDir   string
	Quit     func()

	touch      touchCache
	agentsMu   sync.Mutex
	agentsAt   time.Time
	agents     []agent.Installed
	pausedMu   sync.Mutex
	pausedTill time.Time
}

/** Handler：手机端 HTTPS 入口 */
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	a := func(h http.HandlerFunc) http.Handler { return s.auth(h) }
	// 配对与应急网页
	mux.HandleFunc("POST /api/pair", s.pair)
	mux.Handle("GET /{$}", s.pwa())
	mux.Handle("GET /pwa/", s.pwa())
	// 电脑与工作区
	mux.Handle("GET /api/host", a(s.host))
	mux.Handle("GET /api/ws", a(s.workspaces))
	mux.Handle("GET /api/ws/{id}/list", a(s.list))
	mux.Handle("GET /api/ws/{id}/file", a(s.readFile))
	mux.Handle("HEAD /api/ws/{id}/file", a(s.readFile))
	mux.Handle("PUT /api/ws/{id}/file", a(s.saveFile))
	mux.Handle("POST /api/ws/{id}/ops", a(s.ops))
	mux.Handle("GET /api/ws/{id}/search", a(s.search))
	mux.Handle("POST /api/ws/{id}/render", a(s.render))
	mux.Handle("GET /api/ws/{id}/pdf", a(s.pdf))
	// 传输
	mux.Handle("/files/", s.auth(s.transferGate(s.Tus)))
	mux.Handle("GET /api/outbox", a(s.outboxList))
	mux.Handle("GET /api/outbox/{id}/file", a(s.outboxFile))
	mux.Handle("POST /api/outbox/{id}/ack", a(s.outboxAck))
	mux.Handle("POST /api/assistant/messages", a(s.assistantText))
	// 会话与审批
	mux.Handle("GET /api/sessions", a(s.listSessions))
	mux.Handle("POST /api/sessions", a(s.createSession))
	mux.Handle("GET /api/sessions/{id}", a(s.getSession))
	mux.Handle("PATCH /api/sessions/{id}", a(s.patchSession))
	mux.Handle("DELETE /api/sessions/{id}", a(s.deleteSession))
	mux.Handle("GET /api/sessions/{id}/events", a(s.events))
	mux.Handle("POST /api/sessions/{id}/messages", a(s.sendMessage))
	mux.Handle("POST /api/sessions/{id}/interrupt", a(s.interrupt))
	mux.Handle("POST /api/sessions/{id}/retry", a(s.retry))
	mux.Handle("GET /api/sessions/{id}/diff", a(s.diff))
	mux.Handle("POST /api/approvals/{id}", a(s.decide))
	mux.Handle("GET /api/agents/{kind}/models", a(s.models))
	mux.Handle("GET /api/agents/{kind}/history", a(s.history))
	mux.Handle("POST /api/logs", a(s.exportLogs))
	// 实时通道
	mux.Handle("GET /ws", a(s.eventSocket))
	mux.Handle("GET /term/{id}", a(s.termSocket))
	return guard(mux)
}

/** installedAgents：已安装 Agent，结果缓存 5 分钟 */
func (s *Server) installedAgents() []agent.Installed {
	s.agentsMu.Lock()
	defer s.agentsMu.Unlock()
	if s.agents == nil || time.Since(s.agentsAt) > 5*time.Minute {
		s.agents = agent.Detect(s.Cfg.Get().Agents)
		s.agentsAt = time.Now()
	}
	return s.agents
}

/** host：电脑信息与功能开关 */
func (s *Server) host(w http.ResponseWriter, r *http.Request) {
	cfg := s.Cfg.Get()
	writeJSON(w, 200, map[string]any{
		"name":        cfg.HostName,
		"os":          runtime.GOOS,
		"arch":        runtime.GOARCH,
		"version":     s.Version,
		"apiVersion":  APIVersion,
		"fingerprint": s.Identity.Fingerprint,
		"agents":      s.installedAgents(),
		"features":    cfg.Features,
		"addresses":   netutil.Private(),
		"port":        cfg.Port,
		"deviceId":    deviceOf(r).ID,
	})
}

/**
 * pair：提交配对码，等待电脑端确认后返回设备令牌（最长等待 2 分钟）
 */
func (s *Server) pair(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code     string `json:"code"`
		Name     string `json:"name"`
		Platform string `json:"platform"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	res, err := s.Pairing.Submit(ctx, in.Code, in.Name, in.Platform)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.Store.Audit(r.Context(), res.DeviceID, "device.pair", map[string]string{"name": in.Name, "platform": in.Platform})
	writeJSON(w, 200, map[string]any{"token": res.Token, "deviceId": res.DeviceID, "host": map[string]string{"name": s.Cfg.Get().HostName, "fingerprint": s.Identity.Fingerprint}})
}

/** paused：电脑端是否暂停了传输 */
func (s *Server) paused() bool {
	s.pausedMu.Lock()
	defer s.pausedMu.Unlock()
	return time.Now().Before(s.pausedTill)
}

/** PauseTransfers：暂停或恢复所有传输，暂停期间手机会自动重试 */
func (s *Server) PauseTransfers(on bool) {
	s.pausedMu.Lock()
	defer s.pausedMu.Unlock()
	if on {
		s.pausedTill = time.Now().Add(24 * time.Hour)
	} else {
		s.pausedTill = time.Time{}
	}
	s.Hub.PublishGlobal("host.status", map[string]any{"transfersPaused": on})
}

/** TransfersPaused：供桌面端显示 */
func (s *Server) TransfersPaused() bool { return s.paused() }

/** transferGate：传输暂停时返回 503，传输中维持防休眠 */
func (s *Server) transferGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.paused() && r.Method != http.MethodOptions && r.Method != http.MethodHead {
			w.Header().Set("Retry-After", "60")
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"code": "paused", "message": "电脑端已暂停传输"})
			return
		}
		if s.Power != nil {
			s.Power.Touch()
		}
		next.ServeHTTP(w, r)
	})
}
