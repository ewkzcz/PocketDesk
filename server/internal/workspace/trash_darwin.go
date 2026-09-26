//go:build darwin

/**
 * macOS 删除：移到当前用户的废纸篓。
 */
package workspace

import (
	"os"
	"path/filepath"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
)

/**
 * Trash：移到 ~/.Trash，重名时加序号
 *
 * 处理流程：
 * 1、定位废纸篓目录
 * 2、找到不冲突的名字后改名移动
 */
func Trash(abs string) error {
	// 1、废纸篓
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(home, ".Trash")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// 2、移动
	base := filepath.Base(abs)
	for i := 0; ; i++ {
		dst := filepath.Join(dir, naming.Candidate(base, i))
		if _, err := os.Lstat(dst); os.IsNotExist(err) {
			return os.Rename(abs, dst)
		}
	}
}
