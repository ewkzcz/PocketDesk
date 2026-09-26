//go:build windows

/**
 * Windows 伪终端：使用 ConPTY，默认 PowerShell 7，没有则用 Windows PowerShell。
 */
package terminal

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"

	"github.com/UserExistsError/conpty"
)

/** winPty：ConPTY 进程 */
type winPty struct {
	c *conpty.ConPty
}

/** defaultShell：优先 pwsh */
func defaultShell() []string {
	if p, err := exec.LookPath("pwsh.exe"); err == nil {
		return []string{p, "-NoLogo"}
	}
	return []string{"powershell.exe", "-NoLogo"}
}

/**
 * startPty：启动 ConPTY
 *
 * 处理流程：
 * 1、确认系统支持 ConPTY
 * 2、拼接命令行并以指定尺寸、目录启动
 */
func startPty(argv []string, cwd string, cols, rows int) (ptyProc, error) {
	// 1、可用性
	if !conpty.IsConPtyAvailable() {
		return nil, errors.New("当前 Windows 版本不支持 ConPTY")
	}
	// 2、启动
	parts := make([]string, len(argv))
	for i, a := range argv {
		if strings.ContainsAny(a, " \t\"") {
			a = `"` + strings.ReplaceAll(a, `"`, `\"`) + `"`
		}
		parts[i] = a
	}
	c, err := conpty.Start(strings.Join(parts, " "), conpty.ConPtyDimensions(cols, rows), conpty.ConPtyWorkDir(cwd), conpty.ConPtyEnv(os.Environ()))
	if err != nil {
		return nil, err
	}
	return &winPty{c: c}, nil
}

/** Read：读输出 */
func (p *winPty) Read(b []byte) (int, error) { return p.c.Read(b) }

/** Write：写输入 */
func (p *winPty) Write(b []byte) (int, error) { return p.c.Write(b) }

/** Resize：调整尺寸 */
func (p *winPty) Resize(cols, rows int) error { return p.c.Resize(cols, rows) }

/** Wait：等待进程结束 */
func (p *winPty) Wait() error {
	_, err := p.c.Wait(context.Background())
	return err
}

/** Close：关闭 ConPTY 与进程 */
func (p *winPty) Close() error { return p.c.Close() }
