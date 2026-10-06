/**
 * 截屏：手机或电脑端发起，电脑截下当前屏幕，截图按普通文件发回发起的手机（电脑端发起时发给所有手机）。
 */
package httpapi

import (
	"errors"
	"github.com/ewkzcz/pocketdesk/server/internal/hub"
	"net/http"
	"os"
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
	if err := captureScreen(file); err != nil {
		if errors.Is(err, errScreenDenied) {
			writeErr(w, r, errf(403, "screen_denied", "PocketDesk 还没有屏幕录制权限：请在电脑上弹出的窗口里点「允许」（没弹出就到「系统设置 → 隐私与安全性 → 屏幕录制」里打开 PocketDesk），然后退出并重新打开 PocketDesk，再截一次"))
			return
		}
		writeErr(w, r, errf(500, "screenshot_failed", "截屏失败："+err.Error()))
		return
	}
	if info, err := os.Stat(file); err != nil || info.Size() == 0 {
		writeErr(w, r, errf(500, "screenshot_failed", "截屏失败，没有生成图片"))
		return
	}
	// 2、发给手机：电脑端发起时不指定手机
	target := deviceOf(r).ID
	if target == hub.DesktopDevice {
		target = ""
	}
	it, err := s.Outbox.Send(r.Context(), file, target)
	if err != nil {
		writeErr(w, r, err)
		return
	}
	s.audit(r, "screenshot", map[string]string{"name": it.Name})
	writeJSON(w, 200, it)
}
