//go:build windows

/**
 * Windows 的新进程组设置、中断（Ctrl+Break 控制台事件）与强制结束。
 */
package agent

import (
	"os/exec"
	"strconv"
	"syscall"

	"golang.org/x/sys/windows"
)

/** setProcAttr：新进程组且不弹出控制台窗口 */
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP,
		HideWindow:    true,
	}
}

/** interruptProcess：向进程组发送 Ctrl+Break */
func interruptProcess(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return windows.GenerateConsoleCtrlEvent(windows.CTRL_BREAK_EVENT, uint32(cmd.Process.Pid))
}

/** killProcess：结束进程树 */
func killProcess(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	kill := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(cmd.Process.Pid))
	kill.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if kill.Run() != nil {
		cmd.Process.Kill()
	}
}
