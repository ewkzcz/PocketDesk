//go:build !darwin && !windows

/**
 * 其他系统：写入 systemd 用户服务（不作正式支持，仅便于自行使用）。
 */
package autostart

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

/** unitPath：用户服务文件位置 */
func unitPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "systemd", "user", "pocketdesk.service")
}

/** install：写入并启用用户服务 */
func install(exe, dataDir string) (string, error) {
	p := unitPath()
	content := fmt.Sprintf("[Unit]\nDescription=PocketDesk\n\n[Service]\nExecStart=%q serve\nRestart=on-failure\n\n[Install]\nWantedBy=default.target\n", exe)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		return "", err
	}
	exec.Command("systemctl", "--user", "daemon-reload").Run()
	exec.Command("systemctl", "--user", "enable", "--now", "pocketdesk.service").Run()
	return p, nil
}

/** uninstall：停用并删除用户服务 */
func uninstall() error {
	exec.Command("systemctl", "--user", "disable", "--now", "pocketdesk.service").Run()
	if err := os.Remove(unitPath()); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
