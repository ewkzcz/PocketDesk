/**
 * 服务组装：按配置创建各模块并启动 HTTPS 监听、本机管理端口、mDNS 广播与定时清理。
 */
package app

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/agent"
	"github.com/ewkzcz/pocketdesk/server/internal/config"
	"github.com/ewkzcz/pocketdesk/server/internal/httpapi"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"github.com/ewkzcz/pocketdesk/server/internal/logx"
	"github.com/ewkzcz/pocketdesk/server/internal/netutil"
	"github.com/ewkzcz/pocketdesk/server/internal/notify"
	"github.com/ewkzcz/pocketdesk/server/internal/outbox"
	"github.com/ewkzcz/pocketdesk/server/internal/pairing"
	"github.com/ewkzcz/pocketdesk/server/internal/power"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/session"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/terminal"
	"github.com/ewkzcz/pocketdesk/server/internal/tus"
)

/** Options：启动参数 */
type Options struct {
	DataDir    string
	Version    string
	Debug      bool
	Registry   *agent.Registry
	ListenAddr func() []string
	NoMDNS     bool
	Executable string
}

/** App：一个运行中的服务 */
type App struct {
	Opt      Options
	Cfg      *config.Store
	Store    *store.Store
	API      *httpapi.Server
	Sessions *session.Manager
	Terms    *terminal.Manager
	Outbox   *outbox.Service
	Tus      *tus.Server
	Identity *security.Identity
	AdminKey string
	logs     *logx.Daily
	power    *power.Keeper
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	servers  []*http.Server
	mdns     *netutil.Announcer
	mu       sync.Mutex
	quit     chan struct{}
}

/** DefaultRegistry：四个 Agent 的驱动 */
func DefaultRegistry() *agent.Registry {
	return agent.NewRegistry(agent.ClaudeDriver{}, agent.CodexDriver{}, agent.PiDriver{}, agent.ACPDriver{Name: agent.KindDSH})
}

/** LoadAdminKey：读取或生成本机管理密钥（0600） */
func LoadAdminKey(dataDir string) (string, error) {
	p := filepath.Join(dataDir, "admin.key")
	if b, err := os.ReadFile(p); err == nil && len(strings.TrimSpace(string(b))) >= 32 {
		return strings.TrimSpace(string(b)), nil
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return "", err
	}
	key := security.NewToken()
	if err := os.WriteFile(p, []byte(key), 0o600); err != nil {
		return "", err
	}
	return key, nil
}

/**
 * New：创建全部模块（不监听端口）
 *
 * 处理流程：
 * 1、日志、配置、数据库、证书、管理密钥
 * 2、配对、广播、会话、终端
 * 3、上传、发件箱、防休眠
 * 4、接口层并挂好各模块回调
 */
func New(opt Options) (*App, error) {
	// 1、基础
	if err := os.MkdirAll(opt.DataDir, 0o700); err != nil {
		return nil, err
	}
	logs, err := logx.Setup(filepath.Join(opt.DataDir, "logs"), opt.Debug, os.Stderr)
	if err != nil {
		return nil, err
	}
	cfg, err := config.Open(filepath.Join(opt.DataDir, "config.json"))
	if err != nil {
		return nil, err
	}
	st, err := store.Open(filepath.Join(opt.DataDir, "pocketdesk.db"))
	if err != nil {
		return nil, err
	}
	id, err := security.LoadOrCreateIdentity(filepath.Join(opt.DataDir, "tls"), cfg.Get().HostName)
	if err != nil {
		return nil, err
	}
	key, err := LoadAdminKey(opt.DataDir)
	if err != nil {
		return nil, err
	}
	if opt.Registry == nil {
		opt.Registry = DefaultRegistry()
	}
	if opt.Executable == "" {
		opt.Executable, _ = os.Executable()
	}
	a := &App{Opt: opt, Cfg: cfg, Store: st, Identity: id, AdminKey: key, logs: logs, quit: make(chan struct{})}
	// 2、配对、广播、会话、终端
	h := hub.New()
	pm := pairing.New(st)
	a.Sessions = session.New(session.Deps{
		Store: st, Hub: h, Registry: opt.Registry, Config: cfg.Get,
		Notifier: func() notify.Notifier {
			n := cfg.Get().Notify
			return notify.New(notify.Config{Kind: n.Kind, URL: n.URL, Topic: n.Topic}, nil)
		},
		ApproveCmd: func(sid string) []string {
			return []string{opt.Executable, "mcp-approve", "--data", opt.DataDir, "--session", sid}
		},
	})
	a.Terms = terminal.New(terminal.Deps{
		Store: st, Enabled: func() bool { return cfg.Get().Features.Terminal },
		IdleAfter: func() time.Duration { return time.Duration(cfg.Get().TerminalIdleHours) * time.Hour },
		HostName:  func() string { return cfg.Get().HostName },
		OnPreview: func(sid, p string) {
			h.PublishGlobal("session.preview", map[string]string{"session": sid, "preview": p})
		},
	})
	// 3、上传、发件箱、防休眠
	a.Tus, err = tus.New(st, filepath.Join(opt.DataDir, "uploads"), "/files/", httpapi.UploadResolver(cfg, st))
	if err != nil {
		return nil, err
	}
	a.Outbox, err = outbox.New(st, cfg.Get().Transfer.OutboxDir)
	if err != nil {
		return nil, err
	}
	a.power = power.New(2 * time.Minute)
	// 4、接口层
	a.API = &httpapi.Server{
		Cfg: cfg, Store: st, Identity: id, Pairing: pm, Sessions: a.Sessions, Terms: a.Terms, Hub: h,
		Tus: a.Tus, Outbox: a.Outbox, Power: a.power, Version: opt.Version, DataDir: opt.DataDir,
		AdminKey: key, LogDir: filepath.Join(opt.DataDir, "logs"), Quit: a.Quit,
	}
	a.Tus.DeviceOf = httpapi.DeviceID
	a.Tus.OnComplete = a.API.OnUploadComplete
	a.Tus.OnProgress = a.API.OnUploadProgress
	a.Outbox.OnNew = a.API.OnOutboxNew
	return a, nil
}

/** TLSConfig：只用 HTTP/1.1，保证每一路传输是独立的 TCP 连接 */
func (a *App) TLSConfig() *tls.Config {
	return &tls.Config{Certificates: []tls.Certificate{a.Identity.Cert}, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}}
}

/**
 * Start：启动后台任务与监听
 *
 * 处理流程：
 * 1、恢复遗留状态，确保文件传输助手存在，首次运行时登记默认工作区
 * 2、启动发件箱监听与定时清理
 * 3、手机端 HTTPS 按地址监听，管理端口只监听回环
 * 4、局域网广播 mDNS
 */
func (a *App) Start(ctx context.Context) error {
	ctx, a.cancel = context.WithCancel(ctx)
	// 1、恢复
	a.Sessions.Recover(ctx)
	a.Terms.MarkStale(ctx)
	if err := a.API.EnsureAssistant(ctx); err != nil {
		return err
	}
	a.defaultWorkspace(ctx)
	// 2、后台任务
	if err := a.Outbox.Start(ctx); err != nil {
		return err
	}
	a.wg.Add(1)
	go a.maintenance(ctx)
	// 3、监听
	cfg := a.Cfg.Get()
	phone := &http.Server{Handler: a.API.Handler(), TLSConfig: a.TLSConfig(), ReadHeaderTimeout: 20 * time.Second, TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){}, ErrorLog: quietLog()}
	admin := &http.Server{Handler: a.API.AdminHandler(), ReadHeaderTimeout: 20 * time.Second}
	a.servers = []*http.Server{phone, admin}
	list := a.Opt.ListenAddr
	if list == nil {
		list = netutil.DefaultAddrs
	}
	ls := netutil.NewListenerSet(cfg.Port, list, func(ln net.Listener) {
		phone.Serve(tls.NewListener(ln, phone.TLSConfig))
	})
	a.wg.Add(1)
	go func() {
		defer a.wg.Done()
		ls.Run(ctx)
	}()
	aln, err := net.Listen("tcp", netutil.HostPort("127.0.0.1", cfg.AdminPort))
	if err != nil {
		return fmt.Errorf("本机管理端口 %d 被占用: %w", cfg.AdminPort, err)
	}
	go admin.Serve(aln)
	// 4、广播
	if !a.Opt.NoMDNS {
		if m, err := netutil.Announce(cfg.HostName, cfg.Port, a.Identity.Fingerprint); err == nil {
			a.mdns = m
		} else {
			slog.Warn("mDNS 广播失败", "err", err)
		}
	}
	return nil
}

/** defaultWorkspace：首次运行且 ~/Workspace 存在时登记为工作区 */
func (a *App) defaultWorkspace(ctx context.Context) {
	list, err := a.Store.Workspaces(ctx)
	if err != nil || len(list) > 0 {
		return
	}
	home, _ := os.UserHomeDir()
	p := filepath.Join(home, "Workspace")
	if info, err := os.Stat(p); err == nil && info.IsDir() {
		a.Store.SaveWorkspace(ctx, store.Workspace{ID: security.NewID()[:12], Name: "Workspace", RootPath: p})
	}
}

/** maintenance：每天归档旧事件、清理过期审计与 7 天未完成的上传 */
func (a *App) maintenance(ctx context.Context) {
	defer a.wg.Done()
	run := func() {
		if n, err := a.Store.Maintain(ctx, filepath.Join(a.Opt.DataDir, "archive"), store.DefaultRetention); err != nil {
			slog.Warn("归档事件失败", "err", err)
		} else if n > 0 {
			slog.Info("已归档事件", "count", n)
		}
		days := a.Cfg.Get().Transfer.UploadExpireDays
		if _, err := a.Tus.Expire(ctx, time.Duration(days)*24*time.Hour); err != nil {
			slog.Warn("清理过期上传失败", "err", err)
		}
	}
	run()
	t := time.NewTicker(24 * time.Hour)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			run()
		}
	}
}

/** Quit：请求退出 */
func (a *App) Quit() {
	a.mu.Lock()
	defer a.mu.Unlock()
	select {
	case <-a.quit:
	default:
		close(a.quit)
	}
}

/** Done：收到退出请求 */
func (a *App) Done() <-chan struct{} { return a.quit }

/** Close：停止监听并释放资源 */
func (a *App) Close() error {
	if a.cancel != nil {
		a.cancel()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, s := range a.servers {
		s.Shutdown(ctx)
	}
	a.mdns.Close()
	a.Outbox.Stop()
	a.Sessions.Shutdown()
	a.Terms.Shutdown()
	a.power.Close()
	a.wg.Wait()
	err := a.Store.Close()
	a.logs.Close()
	return err
}

/** debugWriter：把 http.Server 的内部错误（如 TLS 握手失败）降为调试日志，避免刷屏 */
type debugWriter struct{}

/** Write：写入调试日志 */
func (debugWriter) Write(p []byte) (int, error) {
	slog.Debug("http", "msg", strings.TrimSpace(string(p)))
	return len(p), nil
}

/** quietLog：http.Server 使用的日志 */
func quietLog() *log.Logger { return log.New(debugWriter{}, "", 0) }
