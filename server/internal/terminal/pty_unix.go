//go:build !windows

/**
 * 类 Unix 伪终端：使用 PTY，默认启动用户的登录 shell。
 */
package terminal

import (
	"os"
	"os/exec"
	"syscall"

	"github.com/creack/pty"
)

/** unixPty：PTY 进程 */
type unixPty struct {
	f   *os.File
	cmd *exec.Cmd
}

/** defaultShell：用户登录 shell，找不到时退回 zsh 或 sh */
func defaultShell() []string {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/zsh"
		if _, err := os.Stat(sh); err != nil {
			sh = "/bin/sh"
		}
	}
	return []string{sh, "-l"}
}

/**
 * startPty：启动伪终端
 *
 * 处理流程：
 * 1、组装命令、目录与终端类型环境变量
 * 2、以指定尺寸启动 PTY
 */
func startPty(argv []string, cwd string, cols, rows int) (ptyProc, error) {
	// 1、命令
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")
	// 2、启动
	f, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
	if err != nil {
		return nil, err
	}
	return &unixPty{f: f, cmd: cmd}, nil
}

/** Read：读输出 */
func (p *unixPty) Read(b []byte) (int, error) { return p.f.Read(b) }

/** Write：写输入 */
func (p *unixPty) Write(b []byte) (int, error) { return p.f.Write(b) }

/** Resize：调整尺寸 */
func (p *unixPty) Resize(cols, rows int) error {
	return pty.Setsize(p.f, &pty.Winsize{Cols: uint16(cols), Rows: uint16(rows)})
}

/** Wait：等待进程结束 */
func (p *unixPty) Wait() error { return p.cmd.Wait() }

/** Close：结束进程并关闭 PTY */
func (p *unixPty) Close() error {
	if p.cmd.Process != nil {
		p.cmd.Process.Signal(syscall.SIGHUP)
		p.cmd.Process.Kill()
	}
	return p.f.Close()
}
