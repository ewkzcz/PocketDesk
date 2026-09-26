//go:build windows

/**
 * Windows 防休眠：在专用线程上调用 SetThreadExecutionState，释放时恢复默认。
 */
package power

import (
	"runtime"

	"golang.org/x/sys/windows"
)

/** 执行状态标志 */
const (
	esContinuous     = 0x80000000
	esSystemRequired = 0x00000001
)

/** procSetState：kernel32 中的 SetThreadExecutionState */
var procSetState = windows.NewLazySystemDLL("kernel32.dll").NewProc("SetThreadExecutionState")

/** winHolder：持有期间占用一个锁定的系统线程 */
type winHolder struct {
	stop chan struct{}
}

/** newHolder：创建 Windows 实现 */
func newHolder() holder { return &winHolder{} }

/** Hold：设置系统必需状态，直到 Release */
func (w *winHolder) Hold() error {
	if err := procSetState.Find(); err != nil {
		return err
	}
	w.stop = make(chan struct{})
	ready := make(chan struct{})
	go func(stop chan struct{}) {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		procSetState.Call(uintptr(esContinuous | esSystemRequired))
		close(ready)
		<-stop
		procSetState.Call(uintptr(esContinuous))
	}(w.stop)
	<-ready
	return nil
}

/** Release：恢复默认状态 */
func (w *winHolder) Release() {
	if w.stop != nil {
		close(w.stop)
		w.stop = nil
	}
}
