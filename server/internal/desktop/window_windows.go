//go:build windows

package desktop

import (
	"errors"
	"os"
	"path/filepath"

	"github.com/jchv/go-webview2"
)

/** Show：打开窗口并阻塞到窗口关闭；系统缺少 WebView2 运行时时返回错误，由调用方改用浏览器 */
func Show(w Window) error {
	data := filepath.Join(os.Getenv("LOCALAPPDATA"), "PocketDesk", "WebView2")
	v := webview2.NewWithOptions(webview2.WebViewOptions{
		DataPath:      data,
		AutoFocus:     true,
		WindowOptions: webview2.WindowOptions{Title: w.Title, Width: uint(w.Width), Height: uint(w.Height), Center: true},
	})
	if v == nil {
		return errors.New("系统缺少 WebView2 运行时")
	}
	defer v.Destroy()
	v.Navigate(w.URL)
	v.Run()
	return nil
}
