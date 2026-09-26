/**
 * 发件箱单元测试：监听登记、指定设备发送、确认后归档。
 */
package outbox

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** newSvc：搭建临时数据库与发件目录 */
func newSvc(t *testing.T) (*Service, *store.Store) {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	s, err := New(st, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	s.SetSettle(30 * time.Millisecond)
	return s, st
}

/** waitFor：轮询直到条件成立 */
func waitFor(t *testing.T, fn func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if fn() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("等待超时")
}

func TestStartScansAndWatches(t *testing.T) {
	s, st := newSvc(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	os.WriteFile(filepath.Join(s.Dir(), "old.txt"), []byte("old"), 0o644)
	os.WriteFile(filepath.Join(s.Dir(), ".hidden"), []byte("h"), 0o644)
	var mu sync.Mutex
	var notified []string
	s.OnNew = func(it store.OutboxItem) {
		mu.Lock()
		notified = append(notified, it.Name)
		mu.Unlock()
	}
	if err := s.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	os.WriteFile(filepath.Join(s.Dir(), "new.png"), []byte("png"), 0o644)
	waitFor(t, func() bool {
		list, _ := st.PendingOutbox(ctx, "d1")
		return len(list) == 2
	})
	list, _ := st.PendingOutbox(ctx, "d1")
	if list[0].SHA256 == "" || list[0].Size == 0 {
		t.Fatal("未计算哈希")
	}
	os.Remove(filepath.Join(s.Dir(), "old.txt"))
	waitFor(t, func() bool {
		list, _ := st.PendingOutbox(ctx, "d1")
		return len(list) == 1
	})
	mu.Lock()
	defer mu.Unlock()
	if len(notified) != 2 {
		t.Fatalf("通知次数 %d", len(notified))
	}
}

func TestSendWithTargetAndAck(t *testing.T) {
	s, st := newSvc(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.Start(ctx)
	defer s.Stop()
	src := filepath.Join(t.TempDir(), "报告.pdf")
	os.WriteFile(src, []byte("pdf"), 0o644)
	it, err := s.Send(ctx, src, "d2")
	if err != nil {
		t.Fatal(err)
	}
	it2, _ := s.Send(ctx, src, "")
	if it2.Name != "报告-1.pdf" {
		t.Fatalf("重名应加序号: %s", it2.Name)
	}
	time.Sleep(100 * time.Millisecond)
	got, _ := st.OutboxItem(ctx, it.ID)
	if got.TargetDevice != "d2" {
		t.Fatal("监听不应覆盖目标设备")
	}
	if l, _ := st.PendingOutbox(ctx, "d1"); len(l) != 1 {
		t.Fatalf("d1 只应看到未指定目标的文件: %d", len(l))
	}
	if err := s.Ack(ctx, it.ID); err != nil {
		t.Fatal(err)
	}
	got, _ = st.OutboxItem(ctx, it.ID)
	if got.Status != store.OutboxSent || filepath.Base(filepath.Dir(got.Path)) != s.now().Format("20060102") {
		t.Fatalf("确认后状态 %+v", got)
	}
	if _, err := os.Stat(got.Path); err != nil {
		t.Fatal("归档文件不存在")
	}
	time.Sleep(100 * time.Millisecond)
	if _, err := st.OutboxItem(ctx, it.ID); err != nil {
		t.Fatal("移动事件不应删除已发送记录")
	}
	if err := s.Ack(ctx, it.ID); err != nil {
		t.Fatal("重复确认应幂等")
	}
	if _, err := s.Send(ctx, t.TempDir(), ""); err == nil {
		t.Fatal("文件夹应拒绝")
	}
}
