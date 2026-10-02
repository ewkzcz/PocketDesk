/**
 * 命令产生的改动：Agent 用命令或脚本生成、修改文件（如生成 docx、导出 pdf）时没有写文件记录，
 * 这里从命令文本里找出涉及的文件、并在非 git 目录记下工作目录的文件状态，本轮结束时对比找出改动；
 * Word、PowerPoint、Excel 文件取出文字内容对比，其他二进制文件只记录有变化。
 */
package session

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

/** maxProbes：一条命令最多跟踪的文件数 */
const maxProbes = 40

/** maxOffice：提取文字内容的 Office 文件大小上限 */
const maxOffice = 30 << 20

/** fileExt：像文件名的结尾（扩展名） */
var fileExt = regexp.MustCompile(`\.[A-Za-z0-9]{1,8}$`)

/** commandText：工具调用参数里的命令文本 */
func commandText(in any) string {
	m, _ := in.(map[string]any)
	for _, k := range []string{"command", "cmd"} {
		switch v := m[k].(type) {
		case string:
			return v
		case []any:
			parts := make([]string, 0, len(v))
			for _, x := range v {
				if s, ok := x.(string); ok {
					parts = append(parts, s)
				}
			}
			return strings.Join(parts, " ")
		}
	}
	return ""
}

/**
 * shellTokens：把命令拆成词，处理单双引号与转义，; & | ( ) < > 与换行都是分隔
 */
func shellTokens(cmd string) []string {
	var out []string
	var cur strings.Builder
	has := false
	push := func() {
		if has {
			out = append(out, cur.String())
		}
		cur.Reset()
		has = false
	}
	quote := rune(0)
	rs := []rune(cmd)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			} else if r == '\\' && quote == '"' && i+1 < len(rs) {
				i++
				cur.WriteRune(rs[i])
			} else {
				cur.WriteRune(r)
			}
		case r == '\'' || r == '"':
			quote, has = r, true
		case r == '\\' && i+1 < len(rs):
			i++
			cur.WriteRune(rs[i])
			has = true
		case strings.ContainsRune(" \t\r\n;&|()<>", r):
			push()
		default:
			cur.WriteRune(r)
			has = true
		}
	}
	push()
	return out
}

/** skipRoots：临时目录与系统目录，其中的文件是中间产物，不跟踪（测试时替换） */
var skipRoots = []string{"/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/dev/", "/proc/", filepath.Clean(os.TempDir()) + string(filepath.Separator)}

/** skipPrefix：是否在不跟踪的目录下 */
func skipPrefix(p string) bool {
	for _, pre := range skipRoots {
		if strings.HasPrefix(p, pre) {
			return true
		}
	}
	return false
}

/**
 * shellPaths：命令里提到的文件（绝对路径）
 *
 * 处理流程：
 * 1、拆词，遇到 cd 时更新相对路径的起点
 * 2、参数里的 key=value 取等号后面；展开 ~ 与 $HOME
 * 3、只保留像文件名的词（有扩展名、不含通配符和变量），跳过临时目录
 */
func shellPaths(cmd, cwd, home string) []string {
	toks := shellTokens(cmd)
	dir := cwd
	seen := map[string]bool{}
	var out []string
	expand := func(p string) string {
		switch {
		case p == "~" || strings.HasPrefix(p, "~/"):
			return home + p[1:]
		case strings.HasPrefix(p, "$HOME/"):
			return home + p[5:]
		case strings.HasPrefix(p, "${HOME}/"):
			return home + p[7:]
		}
		return p
	}
	for i := 0; i < len(toks) && len(out) < maxProbes; i++ {
		t := toks[i]
		// 1、切换目录
		if t == "cd" && i+1 < len(toks) {
			d := expand(toks[i+1])
			if !filepath.IsAbs(d) {
				d = filepath.Join(dir, d)
			}
			dir = filepath.Clean(d)
			i++
			continue
		}
		// 2、参数
		if k := strings.LastIndex(t, "="); k >= 0 {
			t = t[k+1:]
		}
		p := expand(strings.TrimSpace(t))
		// 3、像文件名
		if p == "" || strings.ContainsAny(p, "*?$`{}[]") || strings.Contains(p, "://") || strings.HasSuffix(p, "/") || !fileExt.MatchString(filepath.Base(p)) {
			continue
		}
		if !filepath.IsAbs(p) {
			p = filepath.Join(dir, p)
		}
		p = filepath.Clean(p)
		if seen[p] || skipPrefix(p) {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}

/** canon：解析所在目录的符号链接（如 macOS 的 /var 与 /private/var），同一个文件只算一次 */
func canon(p string) string {
	if r, err := filepath.EvalSymlinks(filepath.Dir(p)); err == nil {
		return filepath.Join(r, filepath.Base(p))
	}
	return p
}

/** probe：执行命令前记下命令涉及文件的当前状态 */
func (t *turn) probe(cmd string) {
	for _, p := range shellPaths(cmd, t.cwd, t.home) {
		p = canon(p)
		if info, err := os.Stat(p); err == nil && info.IsDir() {
			continue
		}
		t.probes[p] = true
		if t.base[p] == nil {
			t.base[p] = readBaseline(p)
		}
	}
}

/** sigOf：文件的修改时间与大小，不存在时为空 */
func sigOf(p string) string {
	info, err := os.Stat(p)
	if err != nil || info.IsDir() {
		return ""
	}
	return strconv.FormatInt(info.ModTime().UnixNano(), 36) + ":" + strconv.FormatInt(info.Size(), 36)
}

/** 工作目录快照的规模上限，超过时放弃（目录太大时只依赖命令里提到的文件） */
const (
	maxSnapFiles = 5000
	maxSnapDepth = 6
)

/** snapSkip：快照时跳过的依赖、构建与缓存目录 */
var snapSkip = map[string]bool{"node_modules": true, "__pycache__": true, "build": true, "dist": true, "target": true, "venv": true, "Pods": true, "DerivedData": true}

/**
 * dirSnapshot：工作目录（非 git 仓库）下文件的修改时间与大小；文件太多时返回 nil
 */
func dirSnapshot(root string) map[string]string {
	out := map[string]string{}
	over := false
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if over || depth > maxSnapDepth {
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			name := e.Name()
			if strings.HasPrefix(name, ".") {
				continue
			}
			p := filepath.Join(dir, name)
			if e.IsDir() {
				if !snapSkip[name] {
					walk(p, depth+1)
				}
				continue
			}
			if !e.Type().IsRegular() {
				continue
			}
			if len(out) >= maxSnapFiles {
				over = true
				return
			}
			out[p] = sigOf(p)
		}
	}
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}
	walk(root, 0)
	if over {
		return nil
	}
	return out
}

/** isOffice：Word、PowerPoint、Excel 文件 */
func isOffice(p string) bool {
	switch strings.ToLower(filepath.Ext(p)) {
	case ".docx", ".pptx", ".xlsx":
		return true
	}
	return false
}

/**
 * officeText：取出 Office 文件的文字内容，一段（或表格一行）一行
 *
 * Word：正文段落；PowerPoint：按页取各段文字并标出页码；Excel：按工作表逐行取单元格内容。
 */
func officeText(p string) (string, bool) {
	r, err := zip.OpenReader(p)
	if err != nil {
		return "", false
	}
	defer r.Close()
	files := map[string]*zip.File{}
	for _, f := range r.File {
		files[f.Name] = f
	}
	read := func(name string) []byte {
		f := files[name]
		if f == nil || f.UncompressedSize64 > 64<<20 {
			return nil
		}
		rc, err := f.Open()
		if err != nil {
			return nil
		}
		defer rc.Close()
		b, _ := io.ReadAll(rc)
		return b
	}
	var lines []string
	switch strings.ToLower(filepath.Ext(p)) {
	case ".docx":
		b := read("word/document.xml")
		if b == nil {
			return "", false
		}
		lines = xmlParas(b, "p", "t", false)
	case ".pptx":
		var slides []string
		for name := range files {
			if strings.HasPrefix(name, "ppt/slides/slide") && strings.HasSuffix(name, ".xml") {
				slides = append(slides, name)
			}
		}
		sort.Slice(slides, func(i, j int) bool { return slideNo(slides[i]) < slideNo(slides[j]) })
		for _, s := range slides {
			lines = append(lines, "【第 "+strconv.Itoa(slideNo(s))+" 页】")
			lines = append(lines, xmlParas(read(s), "p", "t", false)...)
		}
	case ".xlsx":
		shared := xmlParas(read("xl/sharedStrings.xml"), "si", "t", true)
		var sheets []string
		for name := range files {
			if strings.HasPrefix(name, "xl/worksheets/sheet") && strings.HasSuffix(name, ".xml") {
				sheets = append(sheets, name)
			}
		}
		sort.Slice(sheets, func(i, j int) bool { return slideNo(sheets[i]) < slideNo(sheets[j]) })
		for _, s := range sheets {
			lines = append(lines, "【工作表 "+strconv.Itoa(slideNo(s))+"】")
			lines = append(lines, sheetRows(read(s), shared)...)
		}
	default:
		return "", false
	}
	text := strings.Join(lines, "\n")
	if len(text) > 1<<20 {
		text = text[:1<<20]
	}
	return text, true
}

/** slideNo：slide12.xml、sheet3.xml 中的序号 */
func slideNo(name string) int {
	base := strings.TrimSuffix(filepath.Base(name), ".xml")
	i := len(base)
	for i > 0 && base[i-1] >= '0' && base[i-1] <= '9' {
		i--
	}
	n, _ := strconv.Atoi(base[i:])
	return n
}

/** xmlParas：按段落元素收集其中文字元素的内容；keepEmpty 为 false 时跳过空段落（共享字符串需要保留以免序号错位） */
func xmlParas(b []byte, para, text string, keepEmpty bool) []string {
	if b == nil {
		return nil
	}
	dec := xml.NewDecoder(bytes.NewReader(b))
	var out []string
	var cur strings.Builder
	depth, inText := 0, false
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		switch x := tok.(type) {
		case xml.StartElement:
			switch x.Name.Local {
			case para:
				depth++
			case text:
				inText = true
			case "tab":
				cur.WriteByte('\t')
			}
		case xml.EndElement:
			switch x.Name.Local {
			case text:
				inText = false
			case para:
				depth--
				if depth == 0 {
					if s := strings.TrimSpace(cur.String()); s != "" || keepEmpty {
						out = append(out, s)
					}
					cur.Reset()
				}
			}
		case xml.CharData:
			if inText {
				cur.Write(x)
			}
		}
	}
	return out
}

/** sheetRows：工作表逐行取单元格内容（共享字符串、内联字符串与数值），制表符分隔 */
func sheetRows(b []byte, shared []string) []string {
	if b == nil {
		return nil
	}
	dec := xml.NewDecoder(bytes.NewReader(b))
	var out, row []string
	var cell strings.Builder
	cellType, inVal := "", false
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		switch x := tok.(type) {
		case xml.StartElement:
			switch x.Name.Local {
			case "row":
				row = row[:0]
			case "c":
				cellType = ""
				cell.Reset()
				for _, a := range x.Attr {
					if a.Name.Local == "t" {
						cellType = a.Value
					}
				}
			case "v", "t":
				inVal = true
			}
		case xml.EndElement:
			switch x.Name.Local {
			case "v", "t":
				inVal = false
			case "c":
				v := cell.String()
				if cellType == "s" {
					if n, err := strconv.Atoi(v); err == nil && n >= 0 && n < len(shared) {
						v = shared[n]
					}
				}
				row = append(row, v)
			case "row":
				if s := strings.TrimRight(strings.Join(row, "\t"), "\t"); strings.TrimSpace(s) != "" {
					out = append(out, s)
				}
			}
		case xml.CharData:
			if inVal {
				cell.Write(x)
			}
		}
	}
	return out
}
