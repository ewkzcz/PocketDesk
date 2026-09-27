//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

/** detach：后台服务不带控制台窗口，关闭桌面应用后继续运行 */
func detach(c *exec.Cmd) {
	const detachedProcess, newGroup, noWindow = 0x00000008, 0x00000200, 0x08000000
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: detachedProcess | newGroup | noWindow, HideWindow: true}
}
