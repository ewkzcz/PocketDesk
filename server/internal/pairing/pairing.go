/**
 * 配对流程：生成一次性配对码、校验并限流、等待电脑端确认后签发设备令牌。
 */
package pairing

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** 配对相关错误 */
var (
	ErrInvalidCode = errors.New("配对码错误或已过期")
	ErrLocked      = errors.New("配对码错误次数过多，请稍后再试")
	ErrDenied      = errors.New("电脑端拒绝了配对")
	ErrTimeout     = errors.New("等待电脑端确认超时")
	ErrNoRequest   = errors.New("配对请求不存在")
)

/** 规则常量 */
const (
	CodeTTL      = 5 * time.Minute
	MaxFailures  = 5
	LockDuration = 15 * time.Minute
	codeAlphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
)

/** DeviceCreator：签发令牌时需要的存储能力 */
type DeviceCreator interface {
	CreateDevice(ctx context.Context, d store.Device) (store.Device, error)
}

/** Request：等待电脑端确认的配对请求 */
type Request struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Platform  string    `json:"platform"`
	CreatedAt time.Time `json:"createdAt"`
	decision  chan bool
}

/** Result：配对成功后返回给手机的内容 */
type Result struct {
	DeviceID string `json:"deviceId"`
	Token    string `json:"token"`
}

/** Manager：配对状态机 */
type Manager struct {
	mu          sync.Mutex
	store       DeviceCreator
	now         func() time.Time
	code        string
	expires     time.Time
	failures    int
	lockedUntil time.Time
	pending     map[string]*Request
	onRequest   func(Request)
}

/** New：创建配对管理器 */
func New(s DeviceCreator) *Manager {
	return &Manager{store: s, now: time.Now, pending: map[string]*Request{}}
}

/** SetClock：替换时钟，仅供测试 */
func (m *Manager) SetClock(fn func() time.Time) { m.now = fn }

/** OnRequest：有新配对请求时的回调，用于提醒电脑端弹窗 */
func (m *Manager) OnRequest(fn func(Request)) { m.onRequest = fn }

/**
 * NewCode：生成新的一次性配对码，旧码立即失效
 *
 * 处理流程：
 * 1、从易辨认字符集中随机取 8 位
 * 2、记录 5 分钟有效期
 */
func (m *Manager) NewCode() (string, time.Time) {
	// 1、随机取码
	var b strings.Builder
	for i := 0; i < 8; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		if err != nil {
			panic(err)
		}
		b.WriteByte(codeAlphabet[n.Int64()])
	}
	// 2、有效期
	m.mu.Lock()
	defer m.mu.Unlock()
	m.code = b.String()
	m.expires = m.now().Add(CodeTTL)
	return Display(m.code), m.expires
}

/** Current：当前有效的配对码 */
func (m *Manager) Current() (string, time.Time, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.code == "" || !m.now().Before(m.expires) {
		return "", time.Time{}, false
	}
	return Display(m.code), m.expires, true
}

/** CancelCode：关闭配对窗口时作废配对码 */
func (m *Manager) CancelCode() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.code = ""
}

/** Display：把 8 位码格式化为 XXXX-XXXX */
func Display(code string) string {
	if len(code) != 8 {
		return code
	}
	return code[:4] + "-" + code[4:]
}

/** normalizeCode：去掉分隔符与空格并转大写 */
func normalizeCode(s string) string {
	s = strings.ToUpper(s)
	return strings.Map(func(r rune) rune {
		if r == '-' || r == ' ' {
			return -1
		}
		return r
	}, s)
}

/**
 * Submit：手机提交配对码并等待电脑端确认
 *
 * 处理流程：
 * 1、检查是否处于锁定期
 * 2、校验配对码，错误累计 5 次锁定 15 分钟
 * 3、登记待确认请求并通知电脑端
 * 4、等待允许、拒绝或超时
 * 5、允许后签发令牌、作废配对码
 */
func (m *Manager) Submit(ctx context.Context, code, name, platform string) (Result, error) {
	m.mu.Lock()
	now := m.now()
	// 1、锁定期
	if now.Before(m.lockedUntil) {
		m.mu.Unlock()
		return Result{}, ErrLocked
	}
	// 2、校验
	valid := m.code != "" && now.Before(m.expires) && security.EqualConstant(normalizeCode(code), m.code)
	if !valid {
		m.failures++
		if m.failures >= MaxFailures {
			m.failures = 0
			m.lockedUntil = now.Add(LockDuration)
		}
		m.mu.Unlock()
		return Result{}, ErrInvalidCode
	}
	m.failures = 0
	// 3、登记请求
	req := &Request{ID: security.NewID(), Name: strings.TrimSpace(name), Platform: platform, CreatedAt: now, decision: make(chan bool, 1)}
	if req.Name == "" {
		req.Name = "未命名设备"
	}
	m.pending[req.ID] = req
	cb := m.onRequest
	m.mu.Unlock()
	if cb != nil {
		cb(*req)
	}
	defer func() {
		m.mu.Lock()
		delete(m.pending, req.ID)
		m.mu.Unlock()
	}()
	// 4、等待决定
	var allow bool
	select {
	case allow = <-req.decision:
	case <-ctx.Done():
		return Result{}, ErrTimeout
	}
	if !allow {
		return Result{}, ErrDenied
	}
	// 5、签发令牌
	token := security.NewToken()
	d, err := m.store.CreateDevice(ctx, store.Device{ID: security.NewID(), Name: req.Name, Platform: platform, TokenHash: security.HashToken(token)})
	if err != nil {
		return Result{}, err
	}
	m.mu.Lock()
	m.code = ""
	m.mu.Unlock()
	return Result{DeviceID: d.ID, Token: token}, nil
}

/** Pending：等待确认的请求列表 */
func (m *Manager) Pending() []Request {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Request, 0, len(m.pending))
	for _, r := range m.pending {
		out = append(out, *r)
	}
	return out
}

/** Decide：电脑端允许或拒绝某个请求 */
func (m *Manager) Decide(id string, allow bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.pending[id]
	if !ok {
		return ErrNoRequest
	}
	select {
	case r.decision <- allow:
	default:
	}
	return nil
}
