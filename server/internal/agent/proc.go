/**
 * 子进程封装：按行读写 JSON，收集标准错误尾部，统一中断与结束处理。
 */
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
)

/** lineProc：逐行输出的子进程 */
type lineProc struct {
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	wmu     sync.Mutex
	events  chan Event
	done    chan struct{}
	errMu   sync.Mutex
	err     error
	stderr  *tailBuffer
	closeMu sync.Once
	emitMu  sync.RWMutex
	closed  bool
}

/**
 * startLineProc：启动子进程并逐行回调标准输出
 *
 * 处理流程：
 * 1、组装命令、工作目录、环境变量与进程组属性
 * 2、接好标准输入输出，标准错误只保留尾部
 * 3、后台读取每一行交给 onLine，进程结束后关闭事件通道
 */
func startLineProc(argv []string, cwd string, env []string, onLine func(*lineProc, []byte)) (*lineProc, error) {
	if len(argv) == 0 {
		return nil, errors.New("未配置启动命令")
	}
	// 1、命令
	path, err := LookPath(argv[0])
	if err != nil {
		return nil, fmt.Errorf("找不到 %s，请确认已安装", argv[0])
	}
	cmd := exec.Command(path, argv[1:]...)
	cmd.Dir = cwd
	cmd.Env = append(childEnv(), env...)
	setProcAttr(cmd)
	// 2、管道
	p := &lineProc{cmd: cmd, events: make(chan Event, 256), done: make(chan struct{}), stderr: &tailBuffer{max: 8192}}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = p.stderr
	p.stdin = stdin
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// 3、读取
	go func() {
		r := bufio.NewReaderSize(stdout, 64*1024)
		for {
			line, err := r.ReadBytes('\n')
			if len(bytes.TrimSpace(line)) > 0 {
				onLine(p, bytes.TrimSpace(line))
			}
			if err != nil {
				break
			}
		}
		werr := cmd.Wait()
		p.errMu.Lock()
		if p.err == nil && werr != nil {
			msg := strings.TrimSpace(p.stderr.String())
			if msg != "" {
				p.err = fmt.Errorf("%v: %s", werr, lastLine(msg))
			} else {
				p.err = werr
			}
		}
		p.errMu.Unlock()
		// 先通知发送方退出，再在写锁下关闭事件通道，避免向已关闭通道发送
		close(p.done)
		p.emitMu.Lock()
		p.closed = true
		close(p.events)
		p.emitMu.Unlock()
	}()
	return p, nil
}

/** childEnv：当前环境变量，去掉会让子进程误认为运行在 Claude Code 会话内的变量 */
func childEnv() []string {
	var out []string
	for _, kv := range os.Environ() {
		k := strings.SplitN(kv, "=", 2)[0]
		if k == "CLAUDECODE" || strings.HasPrefix(k, "CLAUDE_CODE_SESSION") || k == "CLAUDE_CODE_ENTRYPOINT" {
			continue
		}
		out = append(out, kv)
	}
	return out
}

/** emit：向事件通道发送，进程已结束时丢弃 */
func (p *lineProc) emit(e Event) {
	p.emitMu.RLock()
	defer p.emitMu.RUnlock()
	if p.closed {
		return
	}
	select {
	case <-p.done:
	case p.events <- e:
	}
}

/** writeJSON：写一行 JSON 到标准输入 */
func (p *lineProc) writeJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	p.wmu.Lock()
	defer p.wmu.Unlock()
	_, err = p.stdin.Write(append(b, '\n'))
	return err
}

/** Events：事件通道 */
func (p *lineProc) Events() <-chan Event { return p.events }

/** Done：进程结束信号 */
func (p *lineProc) Done() <-chan struct{} { return p.done }

/** Err：进程退出原因 */
func (p *lineProc) Err() error {
	p.errMu.Lock()
	defer p.errMu.Unlock()
	return p.err
}

/** signalInterrupt：向进程组发送中断信号 */
func (p *lineProc) signalInterrupt() error { return interruptProcess(p.cmd) }

/** Close：关闭输入并结束进程组 */
func (p *lineProc) Close() error {
	p.closeMu.Do(func() {
		p.stdin.Close()
		select {
		case <-p.done:
		default:
			killProcess(p.cmd)
		}
	})
	return nil
}

/** tailBuffer：只保留最后 max 字节的写缓冲 */
type tailBuffer struct {
	mu  sync.Mutex
	max int
	buf []byte
}

/** Write：追加并截断 */
func (t *tailBuffer) Write(b []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, b...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(b), nil
}

/** String：当前内容 */
func (t *tailBuffer) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return string(t.buf)
}

/** lastLine：多行文本的最后一个非空行 */
func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

/** waitCtx：等待进程结束或上下文取消 */
func waitCtx(ctx context.Context, done <-chan struct{}) error {
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}
