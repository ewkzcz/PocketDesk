/**
 * 配对流程单元测试（使用内存假存储）。
 */
package pairing

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** fakeStore：记录创建的设备 */
type fakeStore struct {
	mu      sync.Mutex
	devices []store.Device
}

func (f *fakeStore) CreateDevice(_ context.Context, d store.Device) (store.Device, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.devices = append(f.devices, d)
	return d, nil
}

/** autoDecide：收到请求后自动给出决定 */
func autoDecide(m *Manager, allow bool) {
	m.OnRequest(func(r Request) {
		go m.Decide(r.ID, allow)
	})
}

func TestSubmitAllowIssuesToken(t *testing.T) {
	fs := &fakeStore{}
	m := New(fs)
	autoDecide(m, true)
	code, _ := m.NewCode()
	res, err := m.Submit(context.Background(), code, "我的手机", "android")
	if err != nil {
		t.Fatal(err)
	}
	if res.Token == "" || len(fs.devices) != 1 {
		t.Fatal("未签发令牌")
	}
	if fs.devices[0].TokenHash != security.HashToken(res.Token) {
		t.Fatal("入库的不是令牌哈希")
	}
	if _, _, ok := m.Current(); ok {
		t.Fatal("配对成功后配对码应作废")
	}
}

func TestSubmitNormalizesCode(t *testing.T) {
	m := New(&fakeStore{})
	autoDecide(m, true)
	code, _ := m.NewCode()
	lower := []byte(code)
	for i, c := range lower {
		if c >= 'A' && c <= 'Z' {
			lower[i] = c + 32
		}
	}
	if _, err := m.Submit(context.Background(), " "+string(lower)+" ", "x", "ios"); err != nil {
		t.Fatalf("小写加空格应能通过: %v", err)
	}
}

func TestSubmitDenied(t *testing.T) {
	m := New(&fakeStore{})
	autoDecide(m, false)
	code, _ := m.NewCode()
	if _, err := m.Submit(context.Background(), code, "x", "ios"); !errors.Is(err, ErrDenied) {
		t.Fatalf("应被拒绝: %v", err)
	}
}

func TestSubmitTimeout(t *testing.T) {
	m := New(&fakeStore{})
	code, _ := m.NewCode()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := m.Submit(ctx, code, "x", "ios"); !errors.Is(err, ErrTimeout) {
		t.Fatalf("应超时: %v", err)
	}
	if len(m.Pending()) != 0 {
		t.Fatal("超时后应清理待确认请求")
	}
}

func TestCodeExpires(t *testing.T) {
	m := New(&fakeStore{})
	now := time.Now()
	m.SetClock(func() time.Time { return now })
	code, _ := m.NewCode()
	m.SetClock(func() time.Time { return now.Add(CodeTTL + time.Second) })
	if _, err := m.Submit(context.Background(), code, "x", "ios"); !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("过期码应失效: %v", err)
	}
}

func TestLockAfterFiveFailures(t *testing.T) {
	m := New(&fakeStore{})
	now := time.Now()
	m.SetClock(func() time.Time { return now })
	code, _ := m.NewCode()
	for i := 0; i < MaxFailures; i++ {
		if _, err := m.Submit(context.Background(), "WRONG000", "x", "ios"); !errors.Is(err, ErrInvalidCode) {
			t.Fatalf("第 %d 次应为错误码: %v", i, err)
		}
	}
	if _, err := m.Submit(context.Background(), code, "x", "ios"); !errors.Is(err, ErrLocked) {
		t.Fatalf("应已锁定: %v", err)
	}
	autoDecide(m, true)
	m.SetClock(func() time.Time { return now.Add(LockDuration - time.Minute) })
	if _, err := m.Submit(context.Background(), code, "x", "ios"); !errors.Is(err, ErrLocked) {
		t.Fatalf("锁定期内仍应锁定: %v", err)
	}
	m.SetClock(func() time.Time { return now.Add(LockDuration + time.Second) })
	code, _ = m.NewCode()
	if _, err := m.Submit(context.Background(), code, "x", "ios"); err != nil {
		t.Fatalf("解锁后应能配对: %v", err)
	}
}

func TestDecideUnknown(t *testing.T) {
	m := New(&fakeStore{})
	if err := m.Decide("nope", true); !errors.Is(err, ErrNoRequest) {
		t.Fatal(err)
	}
}

func TestDisplay(t *testing.T) {
	if Display("ABCD2345") != "ABCD-2345" || Display("abc") != "abc" {
		t.Fatal("格式化错误")
	}
}
