/**
 * 桌面应用窗口：用系统自带的网页引擎在独立窗口中显示管理界面（macOS 为 WebKit，Windows 为 WebView2）。
 */
package desktop

import (
	"os/exec"
	"runtime"
)

/** Window：窗口参数 */
type Window struct {
	Title  string
	URL    string
	Width  int
	Height int
}

/** OpenBrowser：没有原生窗口时用默认浏览器打开 */
func OpenBrowser(url string) error {
	var c *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		c = exec.Command("open", url)
	case "windows":
		c = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		c = exec.Command("xdg-open", url)
	}
	return c.Start()
}
