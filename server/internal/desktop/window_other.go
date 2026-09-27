//go:build !darwin && !windows

package desktop

/** Show：其他系统没有原生窗口，用默认浏览器打开 */
func Show(w Window) error { return OpenBrowser(w.URL) }
