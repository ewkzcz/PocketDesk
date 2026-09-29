/**
 * 异地连接：检测电脑上的 Tailscale（基于 WireGuard 的加密组网），未安装时引导到官方下载页。
 */
package httpapi

import (
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/ewkzcz/pocketdesk/server/internal/desktop"
	"github.com/ewkzcz/pocketdesk/server/internal/netutil"
)

/** tailscaleDownload：官方下载页 */
const tailscaleDownload = "https://tailscale.com/download"

/** tailscaleInstalled：电脑上是否装了 Tailscale */
func tailscaleInstalled() bool {
	if _, err := exec.LookPath("tailscale"); err == nil {
		return true
	}
	var paths []string
	switch runtime.GOOS {
	case "darwin":
		home, _ := os.UserHomeDir()
		paths = []string{"/Applications/Tailscale.app", filepath.Join(home, "Applications", "Tailscale.app")}
	case "windows":
		paths = []string{filepath.Join(os.Getenv("ProgramFiles"), "Tailscale", "tailscale.exe")}
	}
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

/**
 * remoteStatus：异地连接状态
 *
 * state 取值：missing 未安装、offline 已安装但未登录或未连接、ready 已连通（有 Tailscale 地址）
 */
func remoteStatus() map[string]any {
	var ips []string
	for _, a := range netutil.Private() {
		if a.Kind == netutil.KindTailscale {
			ips = append(ips, a.IP)
		}
	}
	state := "missing"
	switch {
	case len(ips) > 0:
		state = "ready"
	case tailscaleInstalled():
		state = "offline"
	}
	// proxyTun：电脑开着 Clash 等代理的 TUN 模式时，Tailscale 需要放行才能稳定连接
	return map[string]any{"state": state, "addresses": ips, "proxyTun": netutil.ProxyTUNs()}
}

/** adminRemote：异地连接状态（桌面端概览） */
func (s *Server) adminRemote(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, remoteStatus())
}

/** adminTailscaleDownload：在默认浏览器打开 Tailscale 官方下载页（只打开固定地址） */
func (s *Server) adminTailscaleDownload(w http.ResponseWriter, r *http.Request) {
	u := tailscaleDownload
	if err := desktop.OpenBrowser(u); err != nil {
		writeErr(w, r, errf(500, "open_failed", "无法打开浏览器"))
		return
	}
	writeJSON(w, 200, map[string]string{"url": u})
}
