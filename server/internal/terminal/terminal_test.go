/**
 * 终端会话单元测试：假伪终端覆盖回放、裁剪、断线重连与空闲结束，Linux 上再跑一次真实 PTY。
 */
package terminal

import (
	"context"
	"io"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/store"
)

/** fakePty：用管道模拟的伪终端，输入原样回显 */
type fakePty struct {
	r      *io.PipeReader
	w      *io.PipeWriter
	mu     sync.Mutex
	cols   int
	rows   int
	closed chan struct{}
	once   sync.Once
}

func newFakePty(cols, rows int) *fakePty {
	r, w := io.Pipe()
	return &fakePty{r: r, w: w, cols: cols, rows: rows, closed: make(chan struct{})}
}

func (f *fakePty) Read(b []byte) (int, error)  { return f.r.Read(b) }
func (f *fakePty) Write(b []byte) (int, error) { return f.w.Write(b) }
func (f *fakePty) Resize(c, r int) error {
	f.mu.Lock()
	f.cols, f.rows = c, r
	f.mu.Unlock()
	return nil
}
func (f *fakePty) Wait() error { <-f.closed; return nil }
func (f *fakePty) Close() error {
	f.once.Do(func() { close(f.closed); f.w.Close() })
	return nil
}

/** env：测试环境 */
type env struct {
	m       *Manager
	st      *store.Store
	enabled bool
	idle    time.Duration
	last    *fakePty
	argv    []string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	st.SaveWorkspace(context.Background(), store.Workspace{ID: "w", Name: "w", RootPath: t.TempDir()})
	e := &env{st: st, enabled: true, idle: time.Hour}
	e.m = New(Deps{
		Store: st, Enabled: func() bool { return e.enabled }, IdleAfter: func() time.Duration { return e.idle },
		HostName: func() string { return "Mac" },
		Start: func(argv []string, cwd string, c, r int) (ptyProc, error) {
			e.argv = argv
			e.last = newFakePty(c, r)
			return e.last, nil
		},
	})
	t.Cleanup(e.m.Shutdown)
	return e
}

/** readUntil：从通道读取直到包含指定文本 */
func readUntil(t *testing.T, ch chan []byte, want string) string {
	t.Helper()
	var sb strings.Builder
	timeout := time.After(3 * time.Second)
	for !strings.Contains(sb.String(), want) {
		select {
		case b, ok := <-ch:
			if !ok {
				t.Fatalf("通道已关闭，已读 %q", sb.String())
			}
			sb.Write(b)
		case <-timeout:
			t.Fatalf("等待 %q 超时，已读 %q", want, sb.String())
		}
	}
	return sb.String()
}

func TestCreateReplayAndReattach(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	s, err := e.m.Create(ctx, Options{WorkspaceID: "w", Cwd: ".", Command: "claude"})
	if err != nil {
		t.Fatal(err)
	}
	if s.Title != "终端 · Mac" || s.Kind != Kind {
		t.Fatalf("会话 %+v", s)
	}
	term, _ := e.m.Get(s.ID)
	_, ch, _ := term.Attach()
	readUntil(t, ch, "claude\r")
	term.Input([]byte("ls\n"))
	readUntil(t, ch, "ls\n")
	term.Detach(ch)
	term.Input([]byte("after detach\n"))
	time.Sleep(50 * time.Millisecond)
	buf, ch2, err := term.Attach()
	if err != nil || !strings.Contains(string(buf), "after detach") {
		t.Fatalf("重连应回放断线期间的输出: %q %v", buf, err)
	}
	if err := term.Resize(120, 40); err != nil || e.last.cols != 120 {
		t.Fatal("尺寸同步失败")
	}
	if err := term.Resize(0, 40); err == nil {
		t.Fatal("非法尺寸应拒绝")
	}
	e.m.Close(s.ID)
	for range ch2 {
	}
	<-term.Done()
	got, _ := e.st.Session(ctx, s.ID)
	if got.State != StateExited || got.Preview != "after detach" {
		t.Fatalf("结束后状态 %+v", got)
	}
	if _, err := e.m.Get(s.ID); err != ErrNotFound {
		t.Fatal("结束后应移除")
	}
}

func TestDisabledAndBadCwd(t *testing.T) {
	e := newEnv(t)
	e.enabled = false
	if _, err := e.m.Create(context.Background(), Options{WorkspaceID: "w"}); err != ErrDisabled {
		t.Fatal("关闭时应拒绝")
	}
	e.enabled = true
	if _, err := e.m.Create(context.Background(), Options{WorkspaceID: "w", Cwd: "../.."}); err == nil {
		t.Fatal("越界目录应拒绝")
	}
}

func TestRingBufferKeepsLastLines(t *testing.T) {
	tm := &Term{}
	for i := 0; i < MaxLines*3; i++ {
		tm.append([]byte("line\n"))
	}
	n := strings.Count(string(tm.buf), "\n")
	if tm.lines != n || n < MaxLines || n > MaxLines+MaxLines/10 {
		t.Fatalf("行数 %d 计数 %d", n, tm.lines)
	}
	big := &Term{}
	chunk := []byte(strings.Repeat("x", 1<<20))
	for i := 0; i < 20; i++ {
		big.append(chunk)
	}
	if len(big.buf) > maxBufBytes {
		t.Fatalf("字节上限未生效 %d", len(big.buf))
	}
}

func TestStripANSIAndLastLine(t *testing.T) {
	in := "\x1b[32m~/site\x1b[0m $ npm run build\r\n\x1b]0;title\x07done\x1b[K\r\n\r\n"
	if got := lastLine(StripANSI(in)); got != "done" {
		t.Fatalf("摘要 %q", got)
	}
}

func TestSlowSubscriberDisconnected(t *testing.T) {
	e := newEnv(t)
	s, _ := e.m.Create(context.Background(), Options{WorkspaceID: "w"})
	term, _ := e.m.Get(s.ID)
	_, ch, _ := term.Attach()
	for i := 0; i < 400; i++ {
		term.Input([]byte("x\n"))
	}
	closed := false
	for i := 0; i < 1000 && !closed; i++ {
		select {
		case _, ok := <-ch:
			if !ok {
				closed = true
			}
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if !closed {
		t.Fatal("跟不上的连接应被断开")
	}
}

func TestRealPty(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("只在 Linux 上跑真实 PTY")
	}
	st, _ := store.Open(filepath.Join(t.TempDir(), "db"))
	defer st.Close()
	st.SaveWorkspace(context.Background(), store.Workspace{ID: "w", Name: "w", RootPath: t.TempDir()})
	t.Setenv("SHELL", "/bin/sh")
	m := New(Deps{Store: st, Enabled: func() bool { return true }, IdleAfter: func() time.Duration { return time.Hour }, HostName: func() string { return "h" }})
	defer m.Shutdown()
	s, err := m.Create(context.Background(), Options{WorkspaceID: "w", Command: "echo pd-$((40+2))"})
	if err != nil {
		t.Fatal(err)
	}
	term, _ := m.Get(s.ID)
	_, ch, _ := term.Attach()
	readUntil(t, ch, "pd-42")
}
