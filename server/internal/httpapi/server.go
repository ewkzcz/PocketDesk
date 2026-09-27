/**
 * 手机端接口路由：配对、电脑信息、工作区文件、传输、会话、审批、事件通道与终端通道。
 */
package httpapi

import (
	"context"
	"github.com/ewkzcz/pocketdesk/server/internal/idem"
	"net/http"
	"strings"
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
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/session"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/terminal"
	"github.com/ewkzcz/pocketdesk/server/internal/tus"
)

/** Server：接口层依赖 */
type Server struct {
	/** 文件传输助手最近处理过的消息编号，textMu 保证同一编号只处理一次 */
	recentText idem.Recent
	textMu     sync.Mutex

	Cfg      *config.Store
	Store    *store.Store
	Identity *security.Identity
	Pairing  *pairing.Manager
	Sessions *session.Manager
	Terms    *terminal.Manager
	Hub      *hub.Hub
	Tus      *tus.Server
	Outbox   *outbox.Service
	Power    *power.Keeper
	Version  string
	DataDir  string
	AdminKey string
	LogDir   string
	Quit     func()

	/** Opener：在电脑上打开或定位文件，为空时用系统默认方式（测试时替换） */
	Opener func(path string, reveal bool) error

	touch      touchCache
	agentsMu   sync.Mutex
	agentsAt   time.Time
	agents     []agent.Installed
	pausedMu   sync.Mutex
	pausedTill time.Time
	phone      phoneBridge
}

/** Handler：手机端 HTTPS 入口 */
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	// 配对与应急网页
	mux.HandleFunc("POST /api/pair", s.pair)
	mux.Handle("GET /{$}", s.pwa())
	mux.Handle("GET /pwa/", s.pwa())
	// 断点续传上传
	mux.Handle("/files/", s.auth(s.transferGate(s.Tus)))
	s.deviceRoutes(mux, "", func(h http.HandlerFunc) http.Handler { return s.auth(h) })
	return guard(mux)
}

/**
 * deviceRoutes：手机与桌面端共用的接口，两端逻辑保持一致
 *
 * 手机以配对令牌访问；桌面端在管理入口下以「电脑」身份访问同一组接口（prefix 为 /admin/p）。
 */
func (s *Server) deviceRoutes(mux *http.ServeMux, prefix string, a func(http.HandlerFunc) http.Handler) {
	h := func(pattern string, fn http.HandlerFunc) {
		method, path, _ := strings.Cut(pattern, " ")
		mux.Handle(method+" "+prefix+path, a(fn))
	}
	// 电脑与工作区
	h("GET /api/host", s.host)
	h("GET /api/ws", s.workspaces)
	h("POST /api/ws", s.addWorkspace)
	h("PUT /api/ws/default", s.setDefaultWorkspace)
	h("DELETE /api/ws/{id}", s.removeWorkspace)
	h("GET /api/dirs", s.dirs)
	h("PUT /api/dirs", s.setDirs)
	h("GET /api/ws/{id}/list", s.list)
	h("GET /api/ws/{id}/file", s.readFile)
	h("HEAD /api/ws/{id}/file", s.readFile)
	h("PUT /api/ws/{id}/file", s.saveFile)
	h("POST /api/ws/{id}/ops", s.ops)
	h("GET /api/ws/{id}/search", s.search)
	// 传输
	h("GET /api/phone/blob/{id}", s.phoneBlobGet)
	h("PUT /api/phone/blob/{id}", s.phoneBlobPut)
	h("GET /api/outbox", s.outboxList)
	h("GET /api/outbox/{id}/file", s.outboxFile)
	h("POST /api/outbox/{id}/ack", s.outboxAck)
	h("POST /api/assistant/messages", s.assistantText)
	// 会话与审批
	h("GET /api/sessions", s.listSessions)
	h("POST /api/sessions", s.createSession)
	h("GET /api/sessions/{id}", s.getSession)
	h("PATCH /api/sessions/{id}", s.patchSession)
	h("DELETE /api/sessions/{id}", s.deleteSession)
	h("GET /api/sessions/{id}/events", s.events)
	h("POST /api/sessions/{id}/messages", s.sendMessage)
	h("POST /api/sessions/{id}/interrupt", s.interrupt)
	h("POST /api/sessions/{id}/retry", s.retry)
	h("GET /api/sessions/{id}/diff", s.diff)
	h("POST /api/approvals/{id}", s.decide)
	h("GET /api/agents/{kind}/models", s.models)
	h("GET /api/agents/{kind}/history", s.history)
	h("POST /api/logs", s.exportLogs)
	// 实时通道
	h("GET /ws", s.eventSocket)
	h("GET /term/{id}", s.termSocket)
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
