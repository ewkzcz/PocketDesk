//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

/** detach：后台服务脱离当前会话，关闭窗口或终端后继续运行 */
func detach(c *exec.Cmd) { c.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }
