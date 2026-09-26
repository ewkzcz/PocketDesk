/**
 * 文件命名与落盘规则：日期文件夹、时间戳命名、非法字符替换、重名加序号、原子落盘。
 */
package naming

import (
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

/** DateFolder：YYYYMMDD 形式的日期文件夹名 */
func DateFolder(t time.Time) string { return t.Format("20060102") }

/** IsDateFolder：判断名称是否为 8 位合法日期 */
func IsDateFolder(name string) bool {
	if len(name) != 8 {
		return false
	}
	_, err := time.Parse("20060102", name)
	return err == nil
}

/** preferredExt：常见 MIME 的首选扩展名，避免系统表返回冷门后缀 */
var preferredExt = map[string]string{
	"text/plain":       ".txt",
	"text/markdown":    ".md",
	"text/html":        ".html",
	"text/csv":         ".csv",
	"image/jpeg":       ".jpg",
	"image/png":        ".png",
	"image/gif":        ".gif",
	"image/webp":       ".webp",
	"image/heic":       ".heic",
	"video/mp4":        ".mp4",
	"video/quicktime":  ".mov",
	"audio/mpeg":       ".mp3",
	"audio/mp4":        ".m4a",
	"application/pdf":  ".pdf",
	"application/zip":  ".zip",
	"application/json": ".json",
}

/**
 * ExtForMime：根据 MIME 推断扩展名
 *
 * 处理流程：
 * 1、去掉参数部分（如 charset）
 * 2、优先查首选表，再查系统表
 * 3、都没有时返回 .bin
 */
func ExtForMime(m string) string {
	// 1、去参数
	base, _, err := mime.ParseMediaType(m)
	if err != nil {
		base = strings.ToLower(strings.TrimSpace(strings.SplitN(m, ";", 2)[0]))
	}
	// 2、查表
	if ext, ok := preferredExt[base]; ok {
		return ext
	}
	if exts, _ := mime.ExtensionsByType(base); len(exts) > 0 {
		return exts[0]
	}
	if strings.HasPrefix(base, "text/") {
		return ".txt"
	}
	// 3、兜底
	return ".bin"
}

/** TimestampName：无名数据的文件名，形如 20261001-093015-042.txt */
func TimestampName(t time.Time, mimeType string) string {
	return fmt.Sprintf("%s-%03d%s", t.Format("20060102-150405"), t.Nanosecond()/1e6, ExtForMime(mimeType))
}

/** reservedNames：Windows 保留设备名 */
var reservedNames = map[string]bool{
	"CON": true, "PRN": true, "AUX": true, "NUL": true,
	"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true, "COM6": true, "COM7": true, "COM8": true, "COM9": true,
	"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true, "LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
}

/** maxNameBytes：常见文件系统的单个文件名字节上限 */
const maxNameBytes = 255

/**
 * Sanitize：把文件名处理成两个系统都能保存的形式
 *
 * 处理流程：
 * 1、统一为 NFC，去掉路径部分
 * 2、非法字符与控制字符替换为 _
 * 3、去掉结尾的点和空格
 * 4、保留设备名追加 _
 * 5、超长时保留扩展名截断
 */
func Sanitize(name string) string {
	// 1、NFC 与去路径
	name = norm.NFC.String(name)
	if i := strings.LastIndexAny(name, `/\`); i >= 0 {
		name = name[i+1:]
	}
	// 2、替换非法字符
	name = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || strings.ContainsRune(`\/:*?"<>|`, r) || r == utf8.RuneError {
			return '_'
		}
		return r
	}, name)
	// 3、去结尾点和空格
	name = strings.TrimRightFunc(name, func(r rune) bool { return r == '.' || unicode.IsSpace(r) })
	name = strings.TrimLeftFunc(name, unicode.IsSpace)
	if name == "" {
		return "_"
	}
	// 4、保留名
	stem, ext := SplitExt(name)
	if reservedNames[strings.ToUpper(stem)] {
		stem += "_"
		name = stem + ext
	}
	// 5、截断
	if len(name) > maxNameBytes {
		keep := maxNameBytes - len(ext)
		if keep < 1 {
			ext = ""
			keep = maxNameBytes
		}
		name = truncateUTF8(stem, keep) + ext
	}
	return name
}

/** SplitExt：拆出主名和扩展名；以点开头且无其他点的视为无扩展名 */
func SplitExt(name string) (string, string) {
	i := strings.LastIndex(name, ".")
	if i <= 0 {
		return name, ""
	}
	return name[:i], name[i:]
}

/** truncateUTF8：按字节截断且不切断多字节字符 */
func truncateUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

/** Candidate：第 i 个候选名，0 为原名，之后为 name-1.ext、name-2.ext */
func Candidate(name string, i int) string {
	if i == 0 {
		return name
	}
	stem, ext := SplitExt(name)
	return fmt.Sprintf("%s-%d%s", stem, i, ext)
}

/** Fold：大小写不敏感且 NFC 统一后的比较键 */
func Fold(name string) string {
	return strings.ToLower(norm.NFC.String(name))
}

/** placeMu：同一进程内串行落盘，避免大小写变体的竞争 */
var placeMu sync.Mutex

/** ErrTooManyConflicts：候选名全部被占用 */
var ErrTooManyConflicts = errors.New("重名文件过多")

/**
 * Place：把临时文件以「不存在才创建」的方式移动到目标目录
 *
 * 处理流程：
 * 1、确保目录存在并读取已有文件名（大小写不敏感）
 * 2、依次尝试候选名，跳过已占用的名字
 * 3、以 O_EXCL 创建占位文件锁定名字
 * 4、把临时文件改名覆盖占位文件
 */
func Place(tmpPath, dir, name string) (string, error) {
	placeMu.Lock()
	defer placeMu.Unlock()
	// 1、目录与已有名字
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	taken := map[string]bool{}
	if entries, err := os.ReadDir(dir); err == nil {
		for _, e := range entries {
			taken[Fold(e.Name())] = true
		}
	}
	name = Sanitize(name)
	for i := 0; i < 100000; i++ {
		// 2、候选名
		cand := Candidate(name, i)
		if taken[Fold(cand)] {
			continue
		}
		dst := filepath.Join(dir, cand)
		// 3、占位
		f, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		f.Close()
		// 4、改名覆盖占位，跨分区时退回复制
		if err := os.Rename(tmpPath, dst); err != nil {
			if cerr := copyFile(tmpPath, dst); cerr != nil {
				os.Remove(dst)
				return "", err
			}
			os.Remove(tmpPath)
		}
		return cand, nil
	}
	return "", ErrTooManyConflicts
}

/** copyFile：把 src 内容写入已存在的 dst 并刷盘 */
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
