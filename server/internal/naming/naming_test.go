/**
 * 命名规则单元测试，覆盖 50 个同名并发落盘不覆盖。
 */
package naming

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestDateAndTimestamp(t *testing.T) {
	ts := time.Date(2026, 10, 1, 9, 30, 15, 42*int(time.Millisecond), time.Local)
	if DateFolder(ts) != "20261001" {
		t.Fatal(DateFolder(ts))
	}
	if got := TimestampName(ts, "text/plain; charset=utf-8"); got != "20261001-093015-042.txt" {
		t.Fatal(got)
	}
	if got := TimestampName(ts, "image/png"); !strings.HasSuffix(got, ".png") {
		t.Fatal(got)
	}
	if ExtForMime("application/x-unknown-zzz") != ".bin" || ExtForMime("text/x-weird") != ".txt" {
		t.Fatal("兜底扩展名错误")
	}
	if !IsDateFolder("20261001") || IsDateFolder("20261399") || IsDateFolder("2026100") {
		t.Fatal("日期文件夹判断错误")
	}
}

func TestSanitize(t *testing.T) {
	cases := map[string]string{
		`a:b*c?.txt`:    "a_b_c_.txt",
		`dir/sub\x.pdf`: "x.pdf",
		"CON.txt":       "CON_.txt",
		"con":           "con_",
		"name. ":        "name",
		"":              "_",
		"...":           "_",
		"tab\there.md":  "tab_here.md",
		"é.txt":        "é.txt",
		".bashrc":       ".bashrc",
	}
	for in, want := range cases {
		if got := Sanitize(in); got != want {
			t.Errorf("Sanitize(%q)=%q 期望 %q", in, got, want)
		}
	}
	long := strings.Repeat("中", 200) + ".md"
	got := Sanitize(long)
	if len(got) > 255 || !strings.HasSuffix(got, ".md") {
		t.Fatalf("截断异常: %d", len(got))
	}
}

func TestCandidate(t *testing.T) {
	if Candidate("report.pdf", 0) != "report.pdf" || Candidate("report.pdf", 2) != "report-2.pdf" || Candidate("Makefile", 1) != "Makefile-1" {
		t.Fatal("候选名错误")
	}
}

func TestPlaceCaseInsensitiveConflict(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "Report.PDF"), []byte("old"), 0o644)
	tmp := filepath.Join(t.TempDir(), "up")
	os.WriteFile(tmp, []byte("new"), 0o644)
	name, err := Place(tmp, dir, "report.pdf")
	if err != nil {
		t.Fatal(err)
	}
	if name != "report-1.pdf" {
		t.Fatalf("大小写不同也应视为重名: %s", name)
	}
	old, _ := os.ReadFile(filepath.Join(dir, "Report.PDF"))
	if string(old) != "old" {
		t.Fatal("原文件被覆盖")
	}
}

func TestPlaceFiftyConcurrentNoOverwrite(t *testing.T) {
	dir := t.TempDir()
	src := t.TempDir()
	var wg sync.WaitGroup
	names := make(chan string, 50)
	for i := 0; i < 50; i++ {
		tmp := filepath.Join(src, fmt.Sprintf("t%d", i))
		os.WriteFile(tmp, []byte(fmt.Sprint(i)), 0o644)
		wg.Add(1)
		go func() {
			defer wg.Done()
			n, err := Place(tmp, dir, "name.txt")
			if err != nil {
				t.Error(err)
				return
			}
			names <- n
		}()
	}
	wg.Wait()
	close(names)
	seen := map[string]bool{}
	for n := range names {
		seen[n] = true
	}
	if len(seen) != 50 || !seen["name.txt"] || !seen["name-49.txt"] {
		t.Fatalf("得到 %d 个不同文件名", len(seen))
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 50 {
		t.Fatalf("目录中有 %d 个文件", len(entries))
	}
}
