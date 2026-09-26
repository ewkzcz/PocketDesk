//go:build darwin

/**
 * macOS：写入 ~/Library/LaunchAgents 下的 plist 并加载，登录后自动运行，异常退出自动拉起。
 */
package autostart

import (
	"encoding/xml"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

/** plistPath：LaunchAgent 文件位置 */
func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", Label+".plist")
}

/** xmlEscape：转义 plist 字符串 */
func xmlEscape(s string) string {
	var b strings.Builder
	xml.EscapeText(&b, []byte(s))
	return b.String()
}

/**
 * install：生成 plist 并通过 launchctl 加载
 */
func install(exe, dataDir string) (string, error) {
	p := plistPath()
	logDir := filepath.Join(dataDir, "logs")
	content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key><array><string>%s</string><string>serve</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, Label, xmlEscape(exe), xmlEscape(filepath.Join(logDir, "launchd.err")))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return "", err
	}
	os.MkdirAll(logDir, 0o700)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		return "", err
	}
	exec.Command("launchctl", "unload", p).Run()
	if out, err := exec.Command("launchctl", "load", "-w", p).CombinedOutput(); err != nil {
		return p, fmt.Errorf("加载自启任务失败: %s", strings.TrimSpace(string(out)))
	}
	return p, nil
}

/** uninstall：卸载并删除 plist */
func uninstall() error {
	p := plistPath()
	exec.Command("launchctl", "unload", "-w", p).Run()
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
