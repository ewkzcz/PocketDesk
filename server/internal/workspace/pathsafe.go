/**
 * 工作区路径安全：规范化相对路径、解析符号链接，确保最终路径落在工作区根目录内。
 */
package workspace

import (
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

/** 路径相关错误 */
var (
	ErrOutside   = errors.New("路径超出工作区范围")
	ErrBadPath   = errors.New("路径格式不合法")
	ErrReadOnly  = errors.New("工作区为只读")
)

/**
 * CleanRel：把协议中的相对路径规范化
 *
 * 处理流程：
 * 1、统一分隔符为 /，拒绝空字节与盘符
 * 2、拒绝绝对路径
 * 3、path.Clean 后拒绝任何 .. 片段
 */
func CleanRel(rel string) (string, error) {
	// 1、分隔符与非法字符
	rel = strings.ReplaceAll(rel, `\`, "/")
	if strings.ContainsRune(rel, 0) || (len(rel) >= 2 && rel[1] == ':') {
		return "", ErrBadPath
	}
	// 2、绝对路径
	if strings.HasPrefix(rel, "/") {
		rel = strings.TrimLeft(rel, "/")
	}
	// 3、任何 .. 片段都直接拒绝，再清理多余分隔符
	for _, seg := range strings.Split(rel, "/") {
		if seg == ".." {
			return "", ErrOutside
		}
	}
	c := strings.TrimPrefix(path.Clean("/"+rel), "/")
	if c == "" {
		return ".", nil
	}
	return c, nil
}

/**
 * Resolve：把相对路径解析为工作区内的绝对路径
 *
 * 处理流程：
 * 1、规范化相对路径
 * 2、解析根目录的真实路径
 * 3、从目标向上找到第一个存在的祖先，解析其符号链接
 * 4、拼回不存在的尾部，确认结果仍在根目录内
 */
func Resolve(root, rel string) (string, error) {
	// 1、相对路径
	clean, err := CleanRel(rel)
	if err != nil {
		return "", err
	}
	// 2、真实根目录
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return "", err
	}
	realRoot, err = filepath.Abs(realRoot)
	if err != nil {
		return "", err
	}
	// 3、找到存在的祖先并解析
	target := filepath.Join(realRoot, filepath.FromSlash(clean))
	existing, tail := target, ""
	for {
		if _, err := os.Lstat(existing); err == nil {
			break
		} else if !errors.Is(err, fs.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(existing)
		if parent == existing {
			return "", ErrOutside
		}
		tail = filepath.Join(filepath.Base(existing), tail)
		existing = parent
	}
	realExisting, err := filepath.EvalSymlinks(existing)
	if err != nil {
		return "", err
	}
	// 4、拼回并校验
	final := filepath.Join(realExisting, tail)
	if !within(realRoot, final) {
		return "", ErrOutside
	}
	return final, nil
}

/** within：判断 p 是否等于 root 或在 root 之下 */
func within(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

/** IsHidden：任一段以点开头即视为隐藏 */
func IsHidden(rel string) bool {
	for _, seg := range strings.Split(rel, "/") {
		if strings.HasPrefix(seg, ".") && seg != "." {
			return true
		}
	}
	return false
}
