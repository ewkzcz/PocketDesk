/**
 * 终端会话：电脑端持有伪终端，保留最近一万行输出作为回滚缓冲，手机断线不结束，重连时先回放再接实时输出。
 */
package terminal

import (
	"bytes"
	"context"
	"errors"
	"io"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/ewkzcz/pocketdesk/server/internal/workspace"
)

/** 终端相关常量 */
const (
	Kind          = "terminal"
	MaxLines      = 10000
	StateRunning  = "running"
	StateExited   = "exited"
	previewPeriod = 2 * time.Second
)

/** 终端错误 */
var (
	ErrDisabled = errors.New("电脑端未开启终端功能")
	ErrNotFound = errors.New("终端会话不存在或已结束")
)

/** ptyProc：跨平台伪终端进程 */
type ptyProc interface {
	io.ReadWriteCloser
	Resize(cols, rows int) error
	Wait() error
}

/** Deps：终端管理器依赖 */
type Deps struct {
	Store     *store.Store
	Enabled   func() bool
	IdleAfter func() time.Duration
	OnPreview func(sessionID, preview string)
	HostName  func() string
	Start     func(argv []string, cwd string, cols, rows int) (ptyProc, error)
}

/** Manager：全部终端会话 */
type Manager struct {
	d     Deps
	mu    sync.Mutex
	terms map[string]*Term
}

/** New：创建终端管理器 */
func New(d Deps) *Manager {
	if d.Start == nil {
		d.Start = startPty
	}
	return &Manager{d: d, terms: map[string]*Term{}}
}

/** Term：一个终端会话 */
type Term struct {
	ID       string
	proc     ptyProc
	mu       sync.Mutex
	buf      []byte
	lines    int
	subs     map[chan []byte]struct{}
	exited   bool
	lastUsed time.Time
	lastPrev string
	done     chan struct{}
}

/** Options：新建终端参数 */
type Options struct {
	WorkspaceID string `json:"workspaceId"`
	Cwd         string `json:"cwd"`
	Cols        int    `json:"cols"`
	Rows        int    `json:"rows"`
	Command     string `json:"command"`
}

/**
 * Create：新建终端会话
 *
 * 处理流程：
 * 1、检查功能开关，解析起始目录（限制在工作区内）
 * 2、启动默认 shell 并登记会话
 * 3、后台读取输出并监控空闲
 * 4、有快捷启动命令时写入 shell 执行
 */
func (m *Manager) Create(ctx context.Context, o Options) (store.Session, error) {
	// 1、开关与目录
	if !m.d.Enabled() {
		return store.Session{}, ErrDisabled
	}
	ws, err := m.d.Store.Workspace(ctx, o.WorkspaceID)
	if err != nil {
		return store.Session{}, err
	}
	abs, err := workspace.Resolve(ws.RootPath, o.Cwd)
	if err != nil {
		return store.Session{}, err
	}
	rel, _ := workspace.CleanRel(o.Cwd)
	if o.Cols <= 0 || o.Cols > 1000 {
		o.Cols = 80
	}
	if o.Rows <= 0 || o.Rows > 1000 {
		o.Rows = 24
	}
	// 2、启动
	argv := defaultShell()
	p, err := m.d.Start(argv, abs, o.Cols, o.Rows)
	if err != nil {
		return store.Session{}, err
	}
	title := "终端 · " + m.d.HostName()
	shellName := argv[0]
	if i := strings.LastIndexAny(shellName, `/\`); i >= 0 {
		shellName = shellName[i+1:]
	}
	s, err := m.d.Store.CreateSession(ctx, store.Session{ID: security.NewID(), Kind: Kind, Title: title, WorkspaceID: ws.ID, Cwd: rel, Model: strings.TrimSuffix(shellName, ".exe"), State: StateRunning})
	if err != nil {
		p.Close()
		return s, err
	}
	t := &Term{ID: s.ID, proc: p, subs: map[chan []byte]struct{}{}, lastUsed: time.Now(), done: make(chan struct{})}
	m.mu.Lock()
	m.terms[s.ID] = t
	m.mu.Unlock()
	// 3、读取与空闲监控（先开始读取，避免写入命令时输出无人接收而阻塞）
	go m.readLoop(t)
	go m.idleLoop(t)
	// 4、快捷启动
	if cmd := strings.TrimSpace(o.Command); cmd != "" {
		t.Input([]byte(cmd + "\r"))
	}
	return s, nil
}

/** Get：取运行中的终端 */
func (m *Manager) Get(id string) (*Term, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.terms[id]
	if !ok {
		return nil, ErrNotFound
	}
	return t, nil
}

/**
 * readLoop：持续读取输出，写入缓冲并分发给在线连接
 *
 * 处理流程：
 * 1、读取一块输出，追加到回滚缓冲并按行数裁剪
 * 2、分发给订阅者（慢连接断开后由缓冲回放兜底）
 * 3、定期更新会话摘要为最后一行输出
 * 4、进程结束后标记会话已结束
 */
func (m *Manager) readLoop(t *Term) {
	b := make([]byte, 32*1024)
	lastPreview := time.Time{}
	for {
		n, err := t.proc.Read(b)
		if n > 0 {
			chunk := append([]byte(nil), b[:n]...)
			// 1、缓冲
			t.mu.Lock()
			t.append(chunk)
			// 2、分发；跟不上的连接直接断开，客户端重连后从缓冲回放，画面不会错乱
			for ch := range t.subs {
				select {
				case ch <- chunk:
				default:
					delete(t.subs, ch)
					close(ch)
				}
			}
			t.mu.Unlock()
			// 3、摘要
			if time.Since(lastPreview) > previewPeriod {
				lastPreview = time.Now()
				m.updatePreview(t)
			}
		}
		if err != nil {
			break
		}
	}
	// 4、结束
	t.proc.Wait()
	m.updatePreview(t)
	t.mu.Lock()
	t.exited = true
	for ch := range t.subs {
		close(ch)
		delete(t.subs, ch)
	}
	t.mu.Unlock()
	close(t.done)
	st := StateExited
	m.d.Store.UpdateSession(context.Background(), t.ID, store.SessionPatch{State: &st})
	m.mu.Lock()
	delete(m.terms, t.ID)
	m.mu.Unlock()
}

/** maxBufBytes：回滚缓冲的字节上限，防止超长行撑爆内存 */
const maxBufBytes = 8 << 20

/**
 * append：追加输出并保留最后 MaxLines 行（调用方持锁）
 *
 * 处理流程：
 * 1、追加并累计行数
 * 2、超过上限 10% 或字节上限时才整体裁剪一次，避免每块输出都复制整个缓冲
 */
func (t *Term) append(chunk []byte) {
	// 1、追加
	t.buf = append(t.buf, chunk...)
	t.lines += bytes.Count(chunk, []byte{'\n'})
	// 2、批量裁剪
	if len(t.buf) > maxBufBytes {
		cut := len(t.buf) - maxBufBytes/2
		if j := bytes.IndexByte(t.buf[cut:], '\n'); j >= 0 {
			cut += j + 1
		}
		t.lines -= bytes.Count(t.buf[:cut], []byte{'\n'})
		t.buf = append([]byte(nil), t.buf[cut:]...)
	}
	if t.lines <= MaxLines+MaxLines/10 {
		return
	}
	drop := t.lines - MaxLines
	idx := 0
	for i := 0; i < drop; i++ {
		j := bytes.IndexByte(t.buf[idx:], '\n')
		if j < 0 {
			break
		}
		idx += j + 1
	}
	t.buf = append([]byte(nil), t.buf[idx:]...)
	t.lines = MaxLines
}

/** updatePreview：会话摘要为最后一个非空输出行 */
func (m *Manager) updatePreview(t *Term) {
	t.mu.Lock()
	tail := t.buf
	if len(tail) > 4096 {
		tail = tail[len(tail)-4096:]
	}
	line := lastLine(StripANSI(string(tail)))
	changed := line != t.lastPrev
	t.lastPrev = line
	t.mu.Unlock()
	if !changed {
		return
	}
	m.d.Store.UpdateSession(context.Background(), t.ID, store.SessionPatch{Preview: &line})
	if m.d.OnPreview != nil {
		m.d.OnPreview(t.ID, line)
	}
}

/** idleLoop：长时间没有输入也没有连接时结束会话 */
func (m *Manager) idleLoop(t *Term) {
	tick := time.NewTicker(time.Minute)
	defer tick.Stop()
	for {
		select {
		case <-t.done:
			return
		case <-tick.C:
			t.mu.Lock()
			idle := len(t.subs) == 0 && time.Since(t.lastUsed) > m.d.IdleAfter()
			t.mu.Unlock()
			if idle {
				t.proc.Close()
				return
			}
		}
	}
}

/**
 * Attach：连接终端，返回回滚缓冲与实时输出通道
 */
func (t *Term) Attach() ([]byte, chan []byte, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.exited {
		return nil, nil, ErrNotFound
	}
	ch := make(chan []byte, 256)
	t.subs[ch] = struct{}{}
	t.lastUsed = time.Now()
	return append([]byte(nil), t.buf...), ch, nil
}

/** Detach：断开连接，终端继续运行 */
func (t *Term) Detach(ch chan []byte) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.subs[ch]; ok {
		delete(t.subs, ch)
		close(ch)
	}
	t.lastUsed = time.Now()
}

/** Input：写入键盘输入 */
func (t *Term) Input(b []byte) error {
	t.mu.Lock()
	t.lastUsed = time.Now()
	t.mu.Unlock()
	_, err := t.proc.Write(b)
	return err
}

/** Resize：调整终端尺寸 */
func (t *Term) Resize(cols, rows int) error {
	if cols <= 0 || rows <= 0 || cols > 1000 || rows > 1000 {
		return errors.New("尺寸不合法")
	}
	return t.proc.Resize(cols, rows)
}

/** Done：终端结束信号 */
func (t *Term) Done() <-chan struct{} { return t.done }

/** Close：结束指定终端 */
func (m *Manager) Close(id string) error {
	t, err := m.Get(id)
	if err != nil {
		return err
	}
	return t.proc.Close()
}

/** Shutdown：结束全部终端 */
func (m *Manager) Shutdown() {
	m.mu.Lock()
	list := make([]*Term, 0, len(m.terms))
	for _, t := range m.terms {
		list = append(list, t)
	}
	m.mu.Unlock()
	for _, t := range list {
		t.proc.Close()
	}
}

/** MarkStale：服务启动时把上次遗留的运行中终端标记为已结束 */
func (m *Manager) MarkStale(ctx context.Context) error {
	list, err := m.d.Store.Sessions(ctx)
	if err != nil {
		return err
	}
	st := StateExited
	for _, s := range list {
		if s.Kind == Kind && s.State != StateExited {
			m.d.Store.UpdateSession(ctx, s.ID, store.SessionPatch{State: &st})
		}
	}
	return nil
}

/** ansiRe：ANSI 控制序列 */
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[@-Z\\-_]`)

/** StripANSI：去掉颜色、光标等控制序列与其他控制字符 */
func StripANSI(s string) string {
	s = ansiRe.ReplaceAllString(s, "")
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' {
			return r
		}
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, s)
}

/** lastLine：最后一个非空行 */
func lastLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			if r := []rune(l); len(r) > 80 {
				return string(r[:80])
			}
			return l
		}
	}
	return ""
}
