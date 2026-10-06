/**
 * 截屏：手机发起，电脑截下当前屏幕，截图按普通文件发回这台手机。
 */
package httpapi

import (
	"context"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

/**
 * screenshot：截取电脑屏幕并发给请求的手机
 *
 * 处理流程：
 * 1、仅 macOS 支持，用系统截屏命令存成临时图片
 * 2、交给发往手机的队列，临时图片随后删除
 */
func (s *Server) screenshot(w http.ResponseWriter, r *http.Request) {
	// 1、截屏
	if runtime.GOOS != "darwin" {
		writeErr(w, r, errf(501, "unsupported", "这台电脑暂不支持截屏"))
		return
	}
	dir, err := os.MkdirTemp("", "pd-shot-")
	if err != nil {
		writeErr(w, r, err)
		return
	}
	defer os.RemoveAll(dir)
	name := "屏幕截图 " + time.Now().Format("2006-01-02 15.04.05") + ".png"
	file := filepath.Join(dir, name)
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "screencapture", "-x", "-t", "png", file).CombinedOutput(); err != nil {
		writeErr(w, r, errf(500, "screenshot_failed", "截屏失败："+string(out)))
		return
	}
	if info, err := os.Stat(file); err != nil || info.Size() == 0 {
		writeErr(w, r, errf(500, "screenshot_failed", "截屏失败，请在电脑的「系统设置 → 隐私与安全性 → 屏幕录制」里允许 PocketDesk"))
		return
	}
	// 2、发给手机
	it, err := s.Outbox.Send(r.Context(), file, deviceOf(r).ID)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "screenshot", map[string]string{"name": it.Name})
	writeJSON(w, 200, it)
}
