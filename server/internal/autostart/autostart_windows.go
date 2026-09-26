//go:build windows

/**
 * Windows：用户级计划任务（登录时启动，不需要管理员权限），并在「发送到」目录放一个发送脚本。
 */
package autostart

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

/** sendToPath：「发送到」菜单中的脚本位置 */
func sendToPath() string {
	return filepath.Join(os.Getenv("APPDATA"), `Microsoft\Windows\SendTo`, "PocketDesk.cmd")
}

/** run：隐藏窗口执行命令 */
func run(name string, args ...string) ([]byte, error) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd.CombinedOutput()
}

/**
 * install：创建登录启动的计划任务，并写入「发送到 → PocketDesk」脚本
 */
func install(exe, dataDir string) (string, error) {
	tr := fmt.Sprintf(`"%s" serve`, exe)
	if out, err := run("schtasks", "/Create", "/F", "/SC", "ONLOGON", "/RL", "LIMITED", "/TN", "PocketDesk", "/TR", tr); err != nil {
		return "", fmt.Errorf("创建计划任务失败: %s", strings.TrimSpace(string(out)))
	}
	script := fmt.Sprintf("@echo off\r\n\"%s\" send %%*\r\n", exe)
	if err := os.WriteFile(sendToPath(), []byte(script), 0o644); err != nil {
		return "PocketDesk", err
	}
	run("schtasks", "/Run", "/TN", "PocketDesk")
	return "PocketDesk", nil
}

/** uninstall：删除计划任务与发送脚本 */
func uninstall() error {
	run("schtasks", "/Delete", "/F", "/TN", "PocketDesk")
	if err := os.Remove(sendToPath()); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
