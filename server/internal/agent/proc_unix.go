//go:build !windows

/**
 * 类 Unix 系统的进程组设置、中断（SIGINT）与强制结束。
 */
package agent

import (
	"os/exec"
	"syscall"
)

/** setProcAttr：子进程独立成组，便于整组中断 */
func setProcAttr(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

/** interruptProcess：向整个进程组发送 SIGINT */
func interruptProcess(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	return syscall.Kill(-cmd.Process.Pid, syscall.SIGINT)
}

/** killProcess：结束整个进程组 */
func killProcess(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}
