//go:build !darwin && !windows

/**
 * 其他系统删除：按 freedesktop 规范移到用户回收站。
 */
package workspace

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
)

/**
 * Trash：移到 ~/.local/share/Trash 并写入 trashinfo
 *
 * 处理流程：
 * 1、确定回收站目录（支持 XDG_DATA_HOME）
 * 2、找到不冲突的名字
 * 3、先写 info 文件再移动
 */
func Trash(abs string) error {
	// 1、回收站目录
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		base = filepath.Join(home, ".local", "share")
	}
	files := filepath.Join(base, "Trash", "files")
	infos := filepath.Join(base, "Trash", "info")
	if err := os.MkdirAll(files, 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(infos, 0o700); err != nil {
		return err
	}
	// 2、名字
	name := filepath.Base(abs)
	for i := 0; ; i++ {
		cand := naming.Candidate(name, i)
		if _, err := os.Lstat(filepath.Join(files, cand)); !os.IsNotExist(err) {
			continue
		}
		// 3、info 与移动
		info := fmt.Sprintf("[Trash Info]\nPath=%s\nDeletionDate=%s\n", (&url.URL{Path: abs}).EscapedPath(), time.Now().Format("2006-01-02T15:04:05"))
		infoPath := filepath.Join(infos, cand+".trashinfo")
		if err := os.WriteFile(infoPath, []byte(info), 0o600); err != nil {
			return err
		}
		if err := os.Rename(abs, filepath.Join(files, cand)); err != nil {
			os.Remove(infoPath)
			return err
		}
		return nil
	}
}
