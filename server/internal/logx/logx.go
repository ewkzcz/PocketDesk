/**
 * 日志：按天滚动写入文件并保留 7 天，默认只记录警告和错误；导出时打包并去掉令牌等敏感内容。
 */
package logx

import (
	"archive/zip"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

/** keepDays：日志保留天数 */
const keepDays = 7

/** Daily：按天滚动的文件写入器 */
type Daily struct {
	mu   sync.Mutex
	dir  string
	day  string
	f    *os.File
	now  func() time.Time
	also io.Writer
}

/** NewDaily：创建写入器，also 为额外输出（如标准错误） */
func NewDaily(dir string, also io.Writer) (*Daily, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Daily{dir: dir, now: time.Now, also: also}, nil
}

/**
 * Write：写入当天文件，跨天时切换并清理过期文件
 *
 * 处理流程：
 * 1、日期变化时关闭旧文件、打开新文件
 * 2、删除超过保留天数的文件
 * 3、写入
 */
func (d *Daily) Write(p []byte) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	// 1、切换
	day := d.now().Format("20060102")
	if day != d.day || d.f == nil {
		if d.f != nil {
			d.f.Close()
		}
		f, err := os.OpenFile(filepath.Join(d.dir, "pocketdesk-"+day+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err != nil {
			return 0, err
		}
		d.f, d.day = f, day
		// 2、清理
		d.prune()
	}
	// 3、写入
	if d.also != nil {
		d.also.Write(p)
	}
	return d.f.Write(p)
}

/** prune：删除过期日志 */
func (d *Daily) prune() {
	cutoff := d.now().AddDate(0, 0, -keepDays).Format("20060102")
	entries, _ := os.ReadDir(d.dir)
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "pocketdesk-") && strings.HasSuffix(name, ".log") {
			if day := strings.TrimSuffix(strings.TrimPrefix(name, "pocketdesk-"), ".log"); day < cutoff {
				os.Remove(filepath.Join(d.dir, name))
			}
		}
	}
}

/** Close：关闭当前文件 */
func (d *Daily) Close() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.f != nil {
		return d.f.Close()
	}
	return nil
}

/** Setup：安装为默认日志，debug 时记录信息级别 */
func Setup(dir string, debug bool, also io.Writer) (*Daily, error) {
	d, err := NewDaily(dir, also)
	if err != nil {
		return nil, err
	}
	level := slog.LevelWarn
	if debug {
		level = slog.LevelInfo
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(d, &slog.HandlerOptions{Level: level})))
	return d, nil
}

/** secretRe：需要去除的令牌、密钥与配对码 */
var secretRe = regexp.MustCompile(`(?i)((?:authorization[=:"\s]+)?bearer\s+|token[=:"\s]+|key[=:"\s]+|code[=:"\s]+|authorization[=:"\s]+)[A-Za-z0-9._~+/=-]{6,}`)

/** Sanitize：去掉敏感内容 */
func Sanitize(s string) string {
	return secretRe.ReplaceAllString(s, "${1}[已去除]")
}

/**
 * Export：把保留期内的日志打包为 zip，逐行去除敏感内容
 */
func Export(dir string, w io.Writer) error {
	zw := zip.NewWriter(w)
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".log") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, n := range names {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			continue
		}
		fw, err := zw.Create("host/" + n)
		if err != nil {
			return err
		}
		if _, err := io.WriteString(fw, Sanitize(string(b))); err != nil {
			return err
		}
	}
	return zw.Close()
}
