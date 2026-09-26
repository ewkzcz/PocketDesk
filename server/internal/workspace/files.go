/**
 * 工作区文件操作：列目录、ETag、带条件的保存、重命名、移动、新建文件夹、搜索。
 */
package workspace

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"golang.org/x/text/unicode/norm"
)

/** 文件操作错误 */
var (
	ErrConflict    = errors.New("文件已被修改")
	ErrExists      = errors.New("目标已存在")
	ErrNotDir      = errors.New("不是文件夹")
	ErrIsDir       = errors.New("是文件夹")
	ErrNeedIfMatch = errors.New("缺少 If-Match")
)

/** Entry：目录中的一项 */
type Entry struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	IsDir      bool   `json:"isDir"`
	Size       int64  `json:"size"`
	ModTime    int64  `json:"modTime"`
	ChildCount int    `json:"childCount"`
	DateFolder bool   `json:"dateFolder"`
}

/** ListOptions：列目录参数 */
type ListOptions struct {
	Sort       string
	Desc       bool
	ShowHidden bool
}

/** ETag：由大小与纳秒修改时间组成的强校验值 */
func ETag(info fs.FileInfo) string {
	return fmt.Sprintf(`"%x-%x"`, info.Size(), info.ModTime().UnixNano())
}

/**
 * List：列出目录内容
 *
 * 处理流程：
 * 1、解析并确认是目录
 * 2、读取条目，按需过滤隐藏项，统一 NFC 文件名
 * 3、文件夹统计子项数量
 * 4、按选项排序
 */
func List(root, rel string, opt ListOptions) ([]Entry, error) {
	// 1、解析
	abs, err := Resolve(root, rel)
	if err != nil {
		return nil, err
	}
	clean, _ := CleanRel(rel)
	info, err := os.Stat(abs)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, ErrNotDir
	}
	// 2、读取条目
	dirents, err := os.ReadDir(abs)
	if err != nil {
		return nil, err
	}
	out := make([]Entry, 0, len(dirents))
	for _, d := range dirents {
		name := norm.NFC.String(d.Name())
		if !opt.ShowHidden && strings.HasPrefix(name, ".") {
			continue
		}
		fi, err := os.Stat(filepath.Join(abs, d.Name()))
		if err != nil {
			continue
		}
		e := Entry{Name: name, Path: joinRel(clean, name), IsDir: fi.IsDir(), Size: fi.Size(), ModTime: fi.ModTime().UnixMilli(), ChildCount: -1}
		// 3、子项数量
		if e.IsDir {
			e.Size = 0
			e.DateFolder = naming.IsDateFolder(name)
			e.ChildCount = countChildren(filepath.Join(abs, d.Name()), opt.ShowHidden)
		}
		out = append(out, e)
	}
	// 4、排序
	SortEntries(out, opt.Sort, opt.Desc)
	return out, nil
}

/** joinRel：拼接相对路径，根目录用 . 表示 */
func joinRel(dir, name string) string {
	if dir == "." || dir == "" {
		return name
	}
	return path.Join(dir, name)
}

/** countChildren：统计文件夹内可见条目数量，最多统计一万项 */
func countChildren(dir string, hidden bool) int {
	f, err := os.Open(dir)
	if err != nil {
		return 0
	}
	defer f.Close()
	names, _ := f.Readdirnames(10000)
	n := 0
	for _, s := range names {
		if hidden || !strings.HasPrefix(s, ".") {
			n++
		}
	}
	return n
}

/**
 * SortEntries：文件夹始终在前
 *
 * 处理流程：
 * 1、按 time / size 时依字段排序，名称兜底
 * 2、默认排序：日期文件夹按时间升序排在最前，其余按名称
 */
func SortEntries(list []Entry, by string, desc bool) {
	less := func(a, b Entry) bool {
		switch by {
		// 1、指定字段
		case "time":
			if a.ModTime != b.ModTime {
				return a.ModTime < b.ModTime
			}
		case "size":
			if a.Size != b.Size {
				return a.Size < b.Size
			}
		default:
			// 2、日期文件夹优先
			if a.DateFolder != b.DateFolder {
				return a.DateFolder
			}
		}
		return naming.Fold(a.Name) < naming.Fold(b.Name)
	}
	sort.SliceStable(list, func(i, j int) bool {
		a, b := list[i], list[j]
		if a.IsDir != b.IsDir {
			return a.IsDir
		}
		if desc {
			return less(b, a)
		}
		return less(a, b)
	})
}

/**
 * Save：带 If-Match 的原子保存
 *
 * 处理流程：
 * 1、目标存在时必须带 If-Match 且与当前 ETag 一致
 * 2、写入同目录临时文件并刷盘
 * 3、保留原权限后改名替换
 */
func Save(abs string, body io.Reader, ifMatch string, create bool) (string, error) {
	// 1、条件校验
	info, err := os.Stat(abs)
	switch {
	case err == nil:
		if info.IsDir() {
			return "", ErrIsDir
		}
		if ifMatch == "" {
			return "", ErrNeedIfMatch
		}
		if ifMatch != "*" && ifMatch != ETag(info) {
			return "", ErrConflict
		}
	case errors.Is(err, fs.ErrNotExist):
		if !create {
			return "", err
		}
	default:
		return "", err
	}
	// 2、临时文件
	dir := filepath.Dir(abs)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	tmp, err := os.CreateTemp(dir, ".pd-save-*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := io.Copy(tmp, body); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	// 3、替换
	if info != nil {
		os.Chmod(tmpName, info.Mode().Perm())
	} else {
		os.Chmod(tmpName, 0o644)
	}
	if err := os.Rename(tmpName, abs); err != nil {
		return "", err
	}
	ni, err := os.Stat(abs)
	if err != nil {
		return "", err
	}
	return ETag(ni), nil
}

/**
 * Rename：同目录改名，目标已存在则报错
 *
 * 处理流程：
 * 1、清理新名字
 * 2、检查目标不存在（大小写不敏感，但允许仅改大小写）
 * 3、执行改名
 */
func Rename(abs, newName string) (string, error) {
	// 1、清理
	newName = naming.Sanitize(newName)
	dst := filepath.Join(filepath.Dir(abs), newName)
	// 2、冲突检查
	if naming.Fold(filepath.Base(abs)) != naming.Fold(newName) {
		if exists(filepath.Dir(abs), newName) {
			return "", ErrExists
		}
	}
	// 3、改名
	return newName, os.Rename(abs, dst)
}

/** Move：移动到目标文件夹，同名时报错 */
func Move(abs, destDir string) error {
	info, err := os.Stat(destDir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return ErrNotDir
	}
	name := filepath.Base(abs)
	if within(abs, destDir) {
		return ErrBadPath
	}
	if exists(destDir, name) {
		return ErrExists
	}
	return os.Rename(abs, filepath.Join(destDir, name))
}

/** Mkdir：新建文件夹 */
func Mkdir(parent, name string) (string, error) {
	name = naming.Sanitize(name)
	if exists(parent, name) {
		return "", ErrExists
	}
	return name, os.Mkdir(filepath.Join(parent, name), 0o755)
}

/** exists：目录中是否已有同名项（大小写与 Unicode 形式不敏感） */
func exists(dir, name string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	key := naming.Fold(name)
	for _, e := range entries {
		if naming.Fold(e.Name()) == key {
			return true
		}
	}
	return false
}

/**
 * Search：全工作区文件名搜索
 *
 * 处理流程：
 * 1、关键词统一为小写 NFC
 * 2、遍历工作区，跳过隐藏项与缓存目录
 * 3、文件名包含关键词即命中，达到上限或被取消时停止
 */
func Search(ctx context.Context, root, q string, limit int) ([]Entry, error) {
	// 1、关键词
	key := naming.Fold(strings.TrimSpace(q))
	if key == "" {
		return []Entry{}, nil
	}
	if limit <= 0 {
		limit = 200
	}
	realRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	errStop := errors.New("stop")
	// 2、遍历
	err = filepath.WalkDir(realRoot, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if p == realRoot {
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		// 3、匹配
		name := norm.NFC.String(d.Name())
		if strings.Contains(naming.Fold(name), key) {
			info, err := d.Info()
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(realRoot, p)
			e := Entry{Name: name, Path: norm.NFC.String(filepath.ToSlash(rel)), IsDir: d.IsDir(), ModTime: info.ModTime().UnixMilli(), ChildCount: -1}
			if !d.IsDir() {
				e.Size = info.Size()
			} else {
				e.DateFolder = naming.IsDateFolder(name)
			}
			out = append(out, e)
			if len(out) >= limit {
				return errStop
			}
		}
		return nil
	})
	if err != nil && !errors.Is(err, errStop) {
		return out, err
	}
	return out, nil
}
