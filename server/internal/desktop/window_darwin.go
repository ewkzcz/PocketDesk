//go:build darwin

package desktop

import (
	"runtime"

	webview "github.com/webview/webview_go"
)

/** init：macOS 的窗口只能在主线程创建和运行，把主协程固定在主线程上 */
func init() { runtime.LockOSThread() }

/** Show：打开窗口并阻塞到窗口关闭 */
func Show(w Window) error {
	v := webview.New(false)
	defer v.Destroy()
	v.SetTitle(w.Title)
	v.SetSize(w.Width, w.Height, webview.HintNone)
	v.Navigate(w.URL)
	v.Run()
	return nil
}
