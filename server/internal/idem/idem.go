/**
 * 重复请求识别：记住最近处理过的消息编号，手机在网络超时后重发同一条消息时直接视为成功，不再重复执行。
 */
package idem

import (
	"sync"
	"time"
)

/** Recent：最近见过的编号（有数量上限与过期时间），零值可直接使用（2000 个、30 分钟） */
type Recent struct {
	mu    sync.Mutex
	max   int
	ttl   time.Duration
	now   func() time.Time
	seen  map[string]time.Time
	order []string
}

/** New：创建，最多记住 max 个编号，每个保留 ttl */
func New(max int, ttl time.Duration) *Recent {
	return &Recent{max: max, ttl: ttl, now: time.Now, seen: map[string]time.Time{}}
}

/** init：补齐零值的默认设置（调用方持有锁） */
func (r *Recent) init() {
	if r.seen == nil {
		r.seen = map[string]time.Time{}
	}
	if r.now == nil {
		r.now = time.Now
	}
	if r.max <= 0 {
		r.max = 2000
	}
	if r.ttl <= 0 {
		r.ttl = 30 * time.Minute
	}
}

/** Has：编号是否在有效期内处理过；空编号总是返回 false */
func (r *Recent) Has(key string) bool {
	if key == "" {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	at, ok := r.seen[key]
	return ok && r.now().Sub(at) < r.ttl
}

/**
 * Add：记录处理成功的编号
 *
 * 处理流程：
 * 1、空编号不记录
 * 2、超过上限时按先后顺序淘汰最早的编号
 */
func (r *Recent) Add(key string) {
	// 1、空编号
	if key == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.init()
	if _, ok := r.seen[key]; !ok {
		r.order = append(r.order, key)
	}
	r.seen[key] = r.now()
	// 2、淘汰
	for len(r.order) > r.max {
		delete(r.seen, r.order[0])
		r.order = r.order[1:]
	}
}
