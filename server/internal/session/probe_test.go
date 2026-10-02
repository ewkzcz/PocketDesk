package session

import (
	"archive/zip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

/** writeZip：按文件名与内容写一个 zip（模拟 Office 文件） */
func writeZip(t *testing.T, p string, files map[string]string) {
	t.Helper()
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	for name, body := range files {
		w, _ := zw.Create(name)
		w.Write([]byte(body))
	}
	zw.Close()
	f.Close()
}

/** docxBody：由段落生成 word/document.xml */
func docxBody(paras ...string) map[string]string {
	var b strings.Builder
	b.WriteString(`<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>`)
	for _, p := range paras {
		b.WriteString(`<w:p><w:r><w:t>` + p + `</w:t></w:r></w:p>`)
	}
	b.WriteString(`</w:body></w:document>`)
	return map[string]string{"word/document.xml": b.String()}
}

/** 从命令里找出涉及的文件：引号、~ 与 $HOME、cd 之后的相对路径、key=value，跳过临时目录与通配符 */
func TestShellPaths(t *testing.T) {
	home, cwd := "/Users/me", "/w"
	cases := []struct {
		cmd  string
		want []string
	}{
		{`cd /tmp/docx_build && node make.js "/Users/me/Desktop/测试3.docx"`, []string{"/Users/me/Desktop/测试3.docx"}},
		{`python3 /w/make_docx.py "$HOME/Desktop/docx测试文件.docx" "$(date)" 2>&1; ls -l ~/Desktop/a.pdf`, []string{"/w/make_docx.py", "/Users/me/Desktop/docx测试文件.docx", "/Users/me/Desktop/a.pdf"}},
		{`textutil -convert docx /tmp/a.html -output out/报告.docx`, []string{"/w/out/报告.docx"}},
		{`cd sub && soffice --convert-to pdf --outdir=../dist 计划.pptx`, []string{"/w/sub/计划.pptx"}},
		{`rm -f *.log && curl https://x.com/a.zip -o /Users/me/a.zip`, []string{"/Users/me/a.zip"}},
		{"python3 - <<'EOF'\np = \"/Users/me/Desktop/x.xlsx\"\nEOF", []string{"/Users/me/Desktop/x.xlsx"}},
	}
	for _, c := range cases {
		if got := shellPaths(c.cmd, cwd, home); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s\n得到 %q\n期望 %q", c.cmd, got, c.want)
		}
	}
}

/** Word、PowerPoint、Excel 的文字内容 */
func TestOfficeText(t *testing.T) {
	dir := t.TempDir()
	d := filepath.Join(dir, "a.docx")
	writeZip(t, d, docxBody("标题", "", "正文一段"))
	if s, ok := officeText(d); !ok || s != "标题\n正文一段" {
		t.Fatalf("docx %q %v", s, ok)
	}
	p := filepath.Join(dir, "b.pptx")
	writeZip(t, p, map[string]string{
		"ppt/slides/slide2.xml":  `<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>第二页</a:t></a:r></a:p></p:sld>`,
		"ppt/slides/slide10.xml": `<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>第十页</a:t></a:r></a:p></p:sld>`,
	})
	if s, _ := officeText(p); s != "【第 2 页】\n第二页\n【第 10 页】\n第十页" {
		t.Fatalf("pptx %q", s)
	}
	x := filepath.Join(dir, "c.xlsx")
	writeZip(t, x, map[string]string{
		"xl/sharedStrings.xml":     `<sst><si><t>姓名</t></si><si><t></t></si><si><t>张三</t></si></sst>`,
		"xl/worksheets/sheet1.xml": `<worksheet><sheetData><row><c t="s"><v>0</v></c><c><v>42</v></c></row><row><c t="s"><v>2</v></c><c t="inlineStr"><is><t>备注</t></is></c></row></sheetData></worksheet>`,
	})
	if s, _ := officeText(x); s != "【工作表 1】\n姓名\t42\n张三\t备注" {
		t.Fatalf("xlsx %q", s)
	}
	os.WriteFile(filepath.Join(dir, "bad.docx"), []byte("not zip"), 0o644)
	if _, ok := officeText(filepath.Join(dir, "bad.docx")); ok {
		t.Fatal("坏文件应失败")
	}
}
