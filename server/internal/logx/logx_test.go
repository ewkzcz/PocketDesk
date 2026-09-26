/**
 * 日志模块单元测试。
 */
package logx

import (
	"archive/zip"
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestDailyRotateAndPrune(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "pocketdesk-20200101.log"), []byte("old"), 0o600)
	d, err := NewDaily(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	day := time.Date(2026, 10, 1, 23, 0, 0, 0, time.Local)
	d.now = func() time.Time { return day }
	d.Write([]byte("a\n"))
	day = day.Add(2 * time.Hour)
	d.Write([]byte("b\n"))
	d.Close()
	for _, n := range []string{"pocketdesk-20261001.log", "pocketdesk-20261002.log"} {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Fatalf("缺少 %s", n)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "pocketdesk-20200101.log")); !os.IsNotExist(err) {
		t.Fatal("过期日志未清理")
	}
}

func TestExportSanitizes(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "pocketdesk-20261001.log"), []byte("Authorization: Bearer abcDEF123456789 token=zzzzzzzzzz ok\n"), 0o600)
	var buf bytes.Buffer
	if err := Export(dir, &buf); err != nil {
		t.Fatal(err)
	}
	zr, _ := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if len(zr.File) != 1 {
		t.Fatal("文件数")
	}
	f, _ := zr.File[0].Open()
	b, _ := io.ReadAll(f)
	s := string(b)
	if strings.Contains(s, "abcDEF123456789") || strings.Contains(s, "zzzzzzzzzz") || !strings.Contains(s, "[已去除]") || !strings.Contains(s, "ok") {
		t.Fatalf("去敏结果 %q", s)
	}
}

func TestSetup(t *testing.T) {
	d, err := Setup(t.TempDir(), true, nil)
	if err != nil {
		t.Fatal(err)
	}
	d.Close()
}
