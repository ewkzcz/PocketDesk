package session

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

/** 仓库之外的写文件记录会进入改动清单，并带上完整路径 */
func TestOutsideWrites(t *testing.T) {
	root, other := t.TempDir(), t.TempDir()
	inside := filepath.Join(root, "a.txt")
	outside := filepath.Join(other, "b.md")
	if err := os.WriteFile(outside, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := outsideWrites(root, map[string]bool{inside: true, outside: true, "rel.txt": true}, root)
	if len(got) != 1 || got[0].Abs != outside || got[0].Path != outside || got[0].Status != "modified" {
		t.Fatalf("仓库外的改动不对：%+v", got)
	}
	if absWrite(root, "rel.txt") != filepath.Join(root, "rel.txt") {
		t.Fatal("相对路径应按工作目录还原")
	}
}

/** 逐行对比统计增删行数，并生成可读的差异文本 */
func TestUnifiedDiff(t *testing.T) {
	before := "a\nb\nc\nd\ne\nf\ng\nh\n"
	after := "a\nB\nc\nd\ne\nf\ng\nh\ni\n"
	add, del, text := unifiedDiff("x.txt", before, after, true, true)
	if add != 2 || del != 1 {
		t.Fatalf("行数不对 +%d -%d", add, del)
	}
	for _, want := range []string{"--- a/x.txt", "+++ b/x.txt", "-b\n", "+B\n", "+i\n", "@@ -1,"} {
		if !strings.Contains(text, want) {
			t.Fatalf("差异缺少 %q:\n%s", want, text)
		}
	}
	add, del, text = unifiedDiff("n.md", "", "1\n2\n3", false, true)
	if add != 3 || del != 0 || !strings.Contains(text, "--- /dev/null") {
		t.Fatalf("新建文件 +%d -%d\n%s", add, del, text)
	}
	if add, del, text = unifiedDiff("s", "same\n", "same\n", true, true); add+del != 0 || text != "" {
		t.Fatal("内容相同不应有差异")
	}
	// 较大的随机改动：按结果重放应得到改动后的内容
	var a, b []string
	for i := 0; i < 400; i++ {
		a = append(a, strconv.Itoa(i%37))
		if i%7 != 0 {
			b = append(b, strconv.Itoa(i%37))
		}
		if i%11 == 0 {
			b = append(b, "new"+strconv.Itoa(i))
		}
	}
	var got []string
	for _, o := range lineOps(a, b) {
		if o.kind != '-' {
			got = append(got, o.text)
		}
	}
	if strings.Join(got, "\n") != strings.Join(b, "\n") {
		t.Fatal("逐行结果重放后与改动后内容不一致")
	}
}

/** 工具结果里的原文优先于事后读取的磁盘内容，并据此统计本轮改动 */
func TestNoteBaseOriginalWins(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "f.txt")
	os.WriteFile(p, []byte("x\ny\n"), 0o644)
	tr := &turn{base: map[string]*baseline{}, patch: map[string]string{}, writes: map[string]bool{p: true}, cwd: dir}
	tr.noteBase(p, map[string]any{})
	tr.noteBase(p, map[string]any{"original": "x\n", "existed": true})
	tr.noteBase(p, map[string]any{"original": "zzz\n", "existed": true})
	if b := tr.base[p]; !b.firm || b.text != "x\n" {
		t.Fatalf("应以第一次工具结果的原文为准：%+v", b)
	}
}
