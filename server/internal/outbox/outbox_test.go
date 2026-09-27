/**
 * 发往手机单元测试：复制到收件目录日期文件夹、指定设备、确认后保留原文件、收件目录更换后立即生效。
 */
package outbox

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** newSvc：搭建临时数据库与收件目录 */
func newSvc(t *testing.T, dir *string) (*Service, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	return New(st, func() string { return *dir }), st
}

func TestSendWithTargetAndAck(t *testing.T) {
	dir := t.TempDir()
	s, st := newSvc(t, &dir)
	ctx := context.Background()
	var notified []string
	s.OnNew = func(it store.OutboxItem) { notified = append(notified, it.Name) }
	src := filepath.Join(t.TempDir(), "报告.pdf")
	os.WriteFile(src, []byte("pdf"), 0o644)
	it, err := s.Send(ctx, src, "d2")
	if err != nil {
		t.Fatal(err)
	}
	// 复制到收件目录的日期文件夹，原文件不动
	want := filepath.Join(dir, s.now().Format("20060102"), "报告.pdf")
	if b, _ := os.ReadFile(want); string(b) != "pdf" {
		t.Fatalf("未复制到日期文件夹: %s", want)
	}
	if _, err := os.Stat(src); err != nil {
		t.Fatal("原文件不应移动")
	}
	it2, _ := s.SendReader(ctx, strings.NewReader("pdf2"), "报告.pdf", "")
	if it2.Name != "报告-1.pdf" || len(notified) != 2 {
		t.Fatalf("重名应加序号并通知: %s %v", it2.Name, notified)
	}
	if l, _ := st.PendingOutbox(ctx, "d1"); len(l) != 1 {
		t.Fatalf("d1 只应看到未指定目标的文件: %d", len(l))
	}
	// 确认后标记已发送，文件留在原处
	if err := s.Ack(ctx, it.ID); err != nil {
		t.Fatal(err)
	}
	got, _ := st.OutboxItem(ctx, it.ID)
	if got.Status != store.OutboxSent || got.Path != want {
		t.Fatalf("确认后状态 %+v", got)
	}
	if err := s.Ack(ctx, it.ID); err != nil {
		t.Fatal("重复确认应幂等")
	}
	if _, err := s.Send(ctx, t.TempDir(), ""); err == nil {
		t.Fatal("文件夹应拒绝")
	}
}

func TestInboxChangeTakesEffect(t *testing.T) {
	dir := t.TempDir()
	s, _ := newSvc(t, &dir)
	dir = t.TempDir()
	it, err := s.SendReader(context.Background(), strings.NewReader("x"), "a.txt", "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(it.Path, dir) {
		t.Fatalf("应使用新的收件目录: %s", it.Path)
	}
}
