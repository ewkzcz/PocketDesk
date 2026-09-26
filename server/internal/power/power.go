/**
 * 防休眠：有活跃传输时阻止电脑休眠，传输结束两分钟后解除。
 */
package power

import (
	"sync"
	"time"
)

/** holder：平台相关的防休眠实现 */
type holder interface {
	Hold() error
	Release()
}

/** Keeper：按最近活动时间维持防休眠 */
type Keeper struct {
	mu       sync.Mutex
	h        holder
	holding  bool
	deadline time.Time
	linger   time.Duration
	timer    *time.Timer
}

/** New：创建防休眠器，活动后维持 linger 时长 */
func New(linger time.Duration) *Keeper {
	return &Keeper{h: newHolder(), linger: linger}
}

/**
 * Touch：记录一次传输活动
 *
 * 处理流程：
 * 1、延长截止时间
 * 2、尚未持有时开始防休眠
 * 3、到期检查：没有新活动则解除
 */
func (k *Keeper) Touch() {
	k.mu.Lock()
	defer k.mu.Unlock()
	// 1、截止时间
	k.deadline = time.Now().Add(k.linger)
	// 2、持有
	if !k.holding {
		if err := k.h.Hold(); err == nil {
			k.holding = true
		}
	}
	// 3、到期检查
	if k.timer == nil {
		k.timer = time.AfterFunc(k.linger, k.check)
	}
}

/** check：截止时间已过则解除，否则继续等待 */
func (k *Keeper) check() {
	k.mu.Lock()
	defer k.mu.Unlock()
	if left := time.Until(k.deadline); left > 0 {
		k.timer = time.AfterFunc(left, k.check)
		return
	}
	k.timer = nil
	if k.holding {
		k.h.Release()
		k.holding = false
	}
}

/** Holding：当前是否在防休眠 */
func (k *Keeper) Holding() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.holding
}

/** Close：立即解除 */
func (k *Keeper) Close() {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.timer != nil {
		k.timer.Stop()
		k.timer = nil
	}
	if k.holding {
		k.h.Release()
		k.holding = false
	}
}
