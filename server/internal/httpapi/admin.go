/**
 * 桌面端管理接口：只监听本机回环地址，凭本机密钥访问；提供配对窗口、设置窗口所需数据与操作。
 */
package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/netutil"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** adminCookie：管理页凭证 Cookie 名 */
const adminCookie = "pd_admin"

/** AdminHandler：管理入口 */
func (s *Server) AdminHandler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("GET /{$}", s.adminPage())
	mux.Handle("GET /admin/", s.adminPage())
	mux.HandleFunc("GET /admin/api/state", s.adminState)
	mux.HandleFunc("POST /admin/api/pair/start", s.adminPairStart)
	mux.HandleFunc("POST /admin/api/pair/cancel", s.adminPairCancel)
	mux.HandleFunc("POST /admin/api/pair/{id}", s.adminPairDecide)
	mux.HandleFunc("POST /admin/api/workspaces", s.adminSaveWorkspace)
	mux.HandleFunc("DELETE /admin/api/workspaces/{id}", s.adminDeleteWorkspace)
	mux.HandleFunc("DELETE /admin/api/devices/{id}", s.adminRevokeDevice)
	mux.HandleFunc("PATCH /admin/api/config", s.adminConfig)
	mux.HandleFunc("POST /admin/api/send", s.adminSend)
	mux.HandleFunc("POST /admin/api/approve", s.adminApprove)
	mux.HandleFunc("GET /admin/api/audit", s.adminAudit)
	mux.HandleFunc("POST /admin/api/open", s.adminOpen)
	mux.HandleFunc("POST /admin/api/transfers/pause", s.adminPause)
	mux.HandleFunc("POST /admin/api/quit", s.adminQuit)
	return s.adminGuard(mux)
}

/**
 * adminGuard：管理入口防护
 *
 * 处理流程：
 * 1、只接受回环来源，Host 必须是 localhost 或 127.0.0.1（防 DNS 重绑定）
 * 2、URL 带正确密钥时写入 Cookie 并跳转去掉密钥
 * 3、其余请求须带 Cookie 或 X-PD-Key 头
 */
func (s *Server) adminGuard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// 1、来源与 Host
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		h := r.Host
		if hh, _, err := net.SplitHostPort(h); err == nil {
			h = hh
		}
		if h != "127.0.0.1" && h != "localhost" {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		// 2、密钥换 Cookie
		if k := r.URL.Query().Get("k"); k != "" {
			if !security.EqualConstant(k, s.AdminKey) {
				http.Error(w, "forbidden", http.StatusForbidden)
				return
			}
			http.SetCookie(w, &http.Cookie{Name: adminCookie, Value: s.AdminKey, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
			q := r.URL.Query()
			q.Del("k")
			r.URL.RawQuery = q.Encode()
			http.Redirect(w, r, r.URL.String(), http.StatusFound)
			return
		}
		// 3、凭证
		key := r.Header.Get("X-PD-Key")
		if c, err := r.Cookie(adminCookie); err == nil && key == "" {
			key = c.Value
		}
		if !security.EqualConstant(key, s.AdminKey) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`<!doctype html><meta charset="utf-8"><title>PocketDesk</title><body style="font-family:system-ui;padding:40px;color:#1a1a1a">请从菜单或命令 <code>pocketdesk open</code> 打开此页面。</body>`))
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

/**
 * adminState：面板与设置窗口的全部数据
 */
func (s *Server) adminState(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	devices, _ := s.Store.Devices(ctx)
	wss, _ := s.Store.Workspaces(ctx)
	cfg := s.Cfg.Get()
	online := s.Hub.Devices()
	type dev struct {
		store.Device
		Online bool `json:"online"`
	}
	ds := make([]dev, 0, len(devices))
	for _, d := range devices {
		ds = append(ds, dev{Device: d, Online: online[d.ID]})
	}
	type wsView struct {
		store.Workspace
		Warning string `json:"warning"`
	}
	ws := make([]wsView, 0, len(wss))
	for _, x := range wss {
		ws = append(ws, wsView{Workspace: x, Warning: protectedWarning(x)})
	}
	code, exp, ok := s.Pairing.Current()
	pair := map[string]any{"active": ok}
	if ok {
		pair["code"] = code
		pair["expiresAt"] = exp.UnixMilli()
	}
	writeJSON(w, 200, map[string]any{
		"host":            map[string]any{"name": cfg.HostName, "os": runtime.GOOS, "version": s.Version, "fingerprint": s.Identity.Fingerprint, "port": cfg.Port},
		"addresses":       netutil.Private(),
		"devices":         ds,
		"workspaces":      ws,
		"config":          cfg,
		"agents":          s.installedAgents(),
		"pair":            pair,
		"pending":         s.Pairing.Pending(),
		"transfersPaused": s.paused(),
		"dataDir":         s.DataDir,
	})
}

/** protectedWarning：macOS 受保护目录下的工作区给出提示 */
func protectedWarning(w store.Workspace) string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	home, _ := os.UserHomeDir()
	for dir, label := range map[string]string{"Documents": "文稿", "Desktop": "桌面", "Downloads": "下载"} {
		if strings.HasPrefix(w.RootPath, filepath.Join(home, dir)) {
			return "「" + w.Name + "」位于「" + label + "」目录下，首次访问时 macOS 会弹出授权提示。建议把工作区放在 ~/Workspace 这类非受保护目录。"
		}
	}
	return ""
}

/**
 * adminPairStart：生成配对码与二维码
 *
 * 处理流程：
 * 1、生成新的一次性配对码
 * 2、二维码内容：电脑名、地址列表、端口、证书指纹、配对码
 */
func (s *Server) adminPairStart(w http.ResponseWriter, r *http.Request) {
	// 1、配对码
	code, exp := s.Pairing.NewCode()
	// 2、二维码
	cfg := s.Cfg.Get()
	var addrs []string
	for _, a := range netutil.Private() {
		addrs = append(addrs, a.IP)
	}
	payload, _ := json.Marshal(map[string]any{"v": 1, "n": cfg.HostName, "a": addrs, "p": cfg.Port, "f": s.Identity.Fingerprint, "c": code})
	text := "PD1:" + base64.RawURLEncoding.EncodeToString(payload)
	png, err := qrcode.Encode(text, qrcode.Medium, 512)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]any{"code": code, "expiresAt": exp.UnixMilli(), "qr": "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), "qrText": text, "addresses": addrs, "hostName": cfg.HostName})
}

/** adminPairCancel：关闭配对窗口 */
func (s *Server) adminPairCancel(w http.ResponseWriter, r *http.Request) {
	s.Pairing.CancelCode()
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** adminPairDecide：允许或拒绝手机配对 */
func (s *Server) adminPairDecide(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Allow bool `json:"allow"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	if err := s.Pairing.Decide(r.PathValue("id"), in.Allow); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/**
 * adminSaveWorkspace：新增或修改工作区
 *
 * 处理流程：
 * 1、展开 ~，要求绝对路径且目录存在
 * 2、名称不能为空，未给 ID 时生成
 * 3、写库
 */
func (s *Server) adminSaveWorkspace(w http.ResponseWriter, r *http.Request) {
	var in store.Workspace
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	// 1、路径
	p := strings.TrimSpace(in.RootPath)
	if strings.HasPrefix(p, "~") {
		home, _ := os.UserHomeDir()
		p = filepath.Join(home, strings.TrimPrefix(p, "~"))
	}
	if !filepath.IsAbs(p) {
		writeErr(w, r, errf(400, "bad_path", "请填写完整的文件夹路径"))
		return
	}
	info, err := os.Stat(p)
	if err != nil || !info.IsDir() {
		writeErr(w, r, errf(400, "bad_path", "文件夹不存在"))
		return
	}
	in.RootPath = filepath.Clean(p)
	// 2、名称与 ID
	in.Name = strings.TrimSpace(in.Name)
	if in.Name == "" {
		in.Name = filepath.Base(in.RootPath)
	}
	if in.ID == "" {
		in.ID = security.NewID()[:12]
	}
	// 3、写库
	if err := s.Store.SaveWorkspace(r.Context(), in); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, in)
}

/** adminDeleteWorkspace：删除工作区配置（不动磁盘文件） */
func (s *Server) adminDeleteWorkspace(w http.ResponseWriter, r *http.Request) {
	if err := s.Store.DeleteWorkspace(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** adminRevokeDevice：吊销手机令牌 */
func (s *Server) adminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	if err := s.Store.RevokeDevice(r.Context(), r.PathValue("id")); err != nil {
		writeErr(w, r, err)
		return
	}
	s.Store.Audit(r.Context(), r.PathValue("id"), "device.revoke", map[string]string{"by": "host"})
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** adminConfig：修改设置，端口与收发目录变更在重启后生效 */
func (s *Server) adminConfig(w http.ResponseWriter, r *http.Request) {
	var in struct {
		HostName          *string          `json:"hostName"`
		Features          *config.Features `json:"features"`
		InboxDir          *string          `json:"inboxDir"`
		OutboxDir         *string          `json:"outboxDir"`
		Notify            *config.Notify   `json:"notify"`
		TerminalIdleHours *int             `json:"terminalIdleHours"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	outboxChanged := false
	cfg, err := s.Cfg.Update(func(c *config.Config) {
		if in.HostName != nil && strings.TrimSpace(*in.HostName) != "" {
			c.HostName = strings.TrimSpace(*in.HostName)
		}
		if in.Features != nil {
			c.Features = *in.Features
		}
		if in.InboxDir != nil {
			c.Transfer.InboxDir = *in.InboxDir
		}
		if in.OutboxDir != nil && *in.OutboxDir != c.Transfer.OutboxDir {
			c.Transfer.OutboxDir, outboxChanged = *in.OutboxDir, true
		}
		if in.Notify != nil {
			c.Notify = *in.Notify
		}
		if in.TerminalIdleHours != nil {
			c.TerminalIdleHours = *in.TerminalIdleHours
		}
	})
	if err != nil {
		writeErr(w, r, err)
		return
	}
	// 发件目录立即改为监听新目录
	if outboxChanged && s.Outbox != nil {
		if err := s.Outbox.SetDir(cfg.Transfer.OutboxDir); err != nil {
			writeErr(w, r, err)
			return
		}
	}
	s.Hub.PublishGlobal("host.status", map[string]any{"features": cfg.Features})
	writeJSON(w, 200, map[string]any{"config": cfg})
}

/** adminSend：命令行与右键菜单把文件发给手机 */
func (s *Server) adminSend(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Paths []string `json:"paths"`
		To    string   `json:"to"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	target := ""
	if in.To != "" {
		devs, _ := s.Store.Devices(r.Context())
		for _, d := range devs {
			if !d.Revoked && (d.ID == in.To || strings.EqualFold(d.Name, in.To)) {
				target = d.ID
			}
		}
		if target == "" {
			writeErr(w, r, errf(404, "not_found", "找不到设备："+in.To))
			return
		}
	}
	var sent []store.OutboxItem
	for _, p := range in.Paths {
		it, err := s.Outbox.Send(r.Context(), p, target)
		if err != nil {
			writeErr(w, r, errf(400, "send_failed", filepath.Base(p)+"："+err.Error()))
			return
		}
		sent = append(sent, it)
	}
	writeJSON(w, 200, sent)
}

/** adminApprove：MCP 审批工具转来的请求，阻塞直到手机决定 */
func (s *Server) adminApprove(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Session  string         `json:"session"`
		ToolName string         `json:"tool_name"`
		Input    map[string]any `json:"input"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	out, err := s.Sessions.ApproveForClaude(r.Context(), in.Session, in.ToolName, in.Input)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, out)
}

/** adminAudit：最近的审计记录 */
func (s *Server) adminAudit(w http.ResponseWriter, r *http.Request) {
	list, err := s.Store.AuditEntries(r.Context(), 300)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, list)
}

/** adminOpen：在系统文件管理器中打开收件、发件或工作区目录 */
func (s *Server) adminOpen(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Which string `json:"which"`
		ID    string `json:"id"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	cfg := s.Cfg.Get()
	var dir string
	switch in.Which {
	case "inbox":
		dir = cfg.Transfer.InboxDir
	case "outbox":
		dir = cfg.Transfer.OutboxDir
	case "workspace":
		ws, err := s.Store.Workspace(r.Context(), in.ID)
		if err != nil {
			writeErr(w, r, err)
			return
		}
		dir = ws.RootPath
	default:
		writeErr(w, r, errf(400, "bad_target", "未知目录"))
		return
	}
	os.MkdirAll(dir, 0o755)
	if err := openFolder(dir); err != nil {
		writeErr(w, r, err)
		return
	}
	writeJSON(w, 200, map[string]bool{"ok": true})
}

/** openFolder：调用系统文件管理器 */
func openFolder(dir string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", dir)
	case "windows":
		cmd = exec.Command("explorer", dir)
	default:
		cmd = exec.Command("xdg-open", dir)
	}
	if err := cmd.Start(); err != nil {
		return errors.New("无法打开文件夹")
	}
	go cmd.Wait()
	return nil
}

/** adminPause：暂停或恢复所有传输 */
func (s *Server) adminPause(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Paused bool `json:"paused"`
	}
	if err := readJSON(r, &in); err != nil {
		writeErr(w, r, err)
		return
	}
	s.PauseTransfers(in.Paused)
	writeJSON(w, 200, map[string]bool{"paused": in.Paused})
}

/** adminQuit：退出服务 */
func (s *Server) adminQuit(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]bool{"ok": true})
	if s.Quit != nil {
		go func() {
			time.Sleep(200 * time.Millisecond)
			s.Quit()
		}()
	}
}

/** ApproveViaAdmin：MCP 审批子命令调用本机管理接口 */
func ApproveViaAdmin(ctx context.Context, adminURL, key, sessionID, tool string, input map[string]any) (map[string]any, error) {
	body, _ := json.Marshal(map[string]any{"session": sessionID, "tool_name": tool, "input": input})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(adminURL, "/")+"/admin/api/approve", strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-PD-Key", key)
	req.Header.Set("Content-Type", "application/json")
	res, err := (&http.Client{Timeout: 15 * time.Minute}).Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		return nil, err
	}
	if res.StatusCode != 200 {
		msg, _ := out["message"].(string)
		return nil, errors.New(msg)
	}
	return out, nil
}
