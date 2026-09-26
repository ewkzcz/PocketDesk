/**
 * 防休眠单元测试（使用计数的假实现）。
 */
package power

import (
	"sync"
	"testing"
	"time"
)

/** countHolder：记录持有与释放次数 */
type countHolder struct {
	mu       sync.Mutex
	holds    int
	releases int
}

func (c *countHolder) Hold() error { c.mu.Lock(); c.holds++; c.mu.Unlock(); return nil }
func (c *countHolder) Release()    { c.mu.Lock(); c.releases++; c.mu.Unlock() }

func TestTouchExtendsThenReleases(t *testing.T) {
	h := &countHolder{}
	k := &Keeper{h: h, linger: 60 * time.Millisecond}
	k.Touch()
	time.Sleep(30 * time.Millisecond)
	k.Touch()
	time.Sleep(40 * time.Millisecond)
	if !k.Holding() {
		t.Fatal("持续活动期间应保持")
	}
	time.Sleep(80 * time.Millisecond)
	if k.Holding() {
		t.Fatal("空闲后应解除")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.holds != 1 || h.releases != 1 {
		t.Fatalf("持有 %d 次 释放 %d 次", h.holds, h.releases)
	}
}

func TestClose(t *testing.T) {
	h := &countHolder{}
	k := &Keeper{h: h, linger: time.Hour}
	k.Touch()
	k.Close()
	if k.Holding() || h.releases != 1 {
		t.Fatal("关闭应立即解除")
	}
	New(time.Second).Close()
}
