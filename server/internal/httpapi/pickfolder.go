/**
 * 桌面端选择文件夹：网页拿不到文件夹的完整路径，由电脑端弹出系统自带的文件夹选择窗口，返回选中的路径。
 */
package httpapi

import (
	"context"
	"errors"
	"net/http"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

/**
 * pickFolder：弹出系统的文件夹选择窗口，用户取消时返回空字符串
 *
 * 处理流程：
 * 1、macOS 用 AppleScript，Windows 用 PowerShell 的文件夹对话框，其他系统用 zenity
 * 2、去掉末尾换行与分隔符
 */
func pickFolder(ctx context.Context, prompt string) (string, error) {
	// 1、系统窗口
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.CommandContext(ctx, "osascript", "-e", "activate", "-e", `POSIX path of (choose folder with prompt "`+strings.ReplaceAll(prompt, `"`, "")+`")`)
	case "windows":
		ps := `[Console]::OutputEncoding=[Text.Encoding]::UTF8; Add-Type -AssemblyName System.Windows.Forms; $d=New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description='` +
			strings.ReplaceAll(prompt, "'", "") + `'; $d.ShowNewFolderButton=$true; if($d.ShowDialog() -eq 'OK'){ [Console]::Out.Write($d.SelectedPath) }`
		cmd = exec.CommandContext(ctx, "powershell", "-NoProfile", "-STA", "-Command", ps)
	default:
		cmd = exec.CommandContext(ctx, "zenity", "--file-selection", "--directory", "--title="+prompt)
	}
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return "", nil
		}
		return "", err
	}
	// 2、整理路径
	p := strings.TrimSpace(string(out))
	if p == "" {
		return "", nil
	}
	if len(p) > 1 {
		p = strings.TrimRight(p, `/\`)
	}
	return filepath.Clean(p), nil
}

/** adminPickFolder：桌面端「选择文件夹」按钮 */
func (s *Server) adminPickFolder(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Prompt string `json:"prompt"`
	}
	readJSON(r, &in)
	if in.Prompt == "" {
		in.Prompt = "选择文件夹"
	}
	pick := s.FolderPicker
	if pick == nil {
		pick = pickFolder
	}
	p, err := pick(r.Context(), in.Prompt)
	if err != nil {
		writeErr(w, r, errf(500, "picker_failed", "无法打开文件夹选择窗口"))
		return
	}
	writeJSON(w, 200, map[string]string{"path": p, "name": filepath.Base(p)})
}
