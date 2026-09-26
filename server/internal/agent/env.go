/**
 * 可执行文件查找：补全登录 shell 的 PATH（开机自启时环境变量不全），并探测已安装 Agent 的版本。
 */
package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

/** pathOnce：登录 shell 的 PATH 只取一次 */
var (
	pathOnce  sync.Once
	extraPath string
)

/**
 * loginShellPath：读取登录 shell 的 PATH
 *
 * 处理流程：
 * 1、Windows 直接使用当前用户 PATH
 * 2、其他系统以登录交互方式执行 shell 输出 PATH，3 秒超时
 */
func loginShellPath() string {
	pathOnce.Do(func() {
		// 1、Windows
		if runtime.GOOS == "windows" {
			return
		}
		// 2、登录 shell
		sh := os.Getenv("SHELL")
		if sh == "" {
			sh = "/bin/zsh"
			if _, err := os.Stat(sh); err != nil {
				sh = "/bin/sh"
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, sh, "-l", "-c", "printf %s \"$PATH\"").Output()
		if err == nil {
			extraPath = strings.TrimSpace(string(out))
		}
	})
	return extraPath
}

/** LookPath：先查当前 PATH，再查登录 shell 的 PATH 与常见安装位置 */
func LookPath(name string) (string, error) {
	if p, err := exec.LookPath(name); err == nil {
		return p, nil
	}
	if filepath.IsAbs(name) {
		return exec.LookPath(name)
	}
	var dirs []string
	if lp := loginShellPath(); lp != "" {
		dirs = append(dirs, filepath.SplitList(lp)...)
	}
	home, _ := os.UserHomeDir()
	dirs = append(dirs, "/opt/homebrew/bin", "/usr/local/bin", filepath.Join(home, ".local", "bin"), filepath.Join(home, ".npm-global", "bin"), filepath.Join(home, ".bun", "bin"))
	if appData := os.Getenv("APPDATA"); appData != "" {
		dirs = append(dirs, filepath.Join(appData, "npm"))
	}
	exts := []string{""}
	if runtime.GOOS == "windows" {
		exts = []string{".exe", ".cmd", ".bat", ""}
	}
	for _, d := range dirs {
		for _, ext := range exts {
			p := filepath.Join(d, name+ext)
			if info, err := os.Stat(p); err == nil && !info.IsDir() {
				return p, nil
			}
		}
	}
	return "", exec.ErrNotFound
}

/** EnvPath：给子进程补上登录 shell 的 PATH */
func EnvPath() []string {
	lp := loginShellPath()
	if lp == "" {
		return nil
	}
	return []string{"PATH=" + lp + string(os.PathListSeparator) + os.Getenv("PATH")}
}

/** Installed：一个已安装 Agent 的信息 */
type Installed struct {
	Kind      string `json:"kind"`
	Label     string `json:"label"`
	Installed bool   `json:"installed"`
	Version   string `json:"version"`
}

/**
 * Detect：并行探测各 Agent 是否安装及版本
 *
 * 处理流程：
 * 1、按配置的命令名查找可执行文件
 * 2、执行 --version，取第一行，2 秒超时
 */
func Detect(commands map[string][]string) []Installed {
	out := make([]Installed, len(Kinds))
	var wg sync.WaitGroup
	for i, k := range Kinds {
		wg.Add(1)
		go func(i int, k string) {
			defer wg.Done()
			info := Installed{Kind: k, Label: Label(k)}
			argv := commands[k]
			if len(argv) == 0 {
				out[i] = info
				return
			}
			// 1、查找
			p, err := LookPath(argv[0])
			if err != nil {
				out[i] = info
				return
			}
			info.Installed = true
			// 2、版本
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, p, "--version")
			cmd.Env = append(os.Environ(), EnvPath()...)
			if b, err := cmd.Output(); err == nil {
				info.Version = strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0])
			}
			out[i] = info
		}(i, k)
	}
	wg.Wait()
	return out
}
