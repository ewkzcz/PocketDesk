/**
 * 子进程环境：终端与 Agent 使用用户自己的登录环境，不继承电脑端服务自身的环境变量
 * （服务可能由其他程序启动，带着别的账号、接口地址或模型设置）。
 */
package sysenv

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"time"
)

/** baseKeys：新开一个终端窗口时系统本来就有的变量 */
var baseKeys = []string{"HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK"}

/** Shell：用户登录 shell，找不到时退回 zsh 或 sh */
func Shell() string {
	sh := os.Getenv("SHELL")
	if sh == "" {
		sh = "/bin/zsh"
		if _, err := os.Stat(sh); err != nil {
			sh = "/bin/sh"
		}
	}
	return sh
}

/**
 * Base：干净的基础环境，等同于刚打开一个终端窗口，其余由用户的 shell 配置文件设置
 * Windows 没有登录 shell 的概念，沿用当前环境（去掉 Claude Code 运行时注入的变量）
 */
func Base() []string {
	if runtime.GOOS == "windows" {
		return withoutRuntime(os.Environ())
	}
	out := []string{"PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
	for _, k := range baseKeys {
		if v, ok := os.LookupEnv(k); ok {
			out = append(out, k+"="+v)
		}
	}
	if _, ok := os.LookupEnv("SHELL"); !ok {
		out = append(out, "SHELL="+Shell())
	}
	return out
}

/** 登录环境只取一次 */
var (
	loginOnce sync.Once
	loginEnv  []string
)

/** marker：分隔 shell 启动时的输出与环境变量 */
const marker = "\x00PD-ENV\x00"

/**
 * Login：用户登录 shell 的完整环境，与在自己的终端里执行命令时一致（含 ~/.zshrc 中的设置）
 *
 * 处理流程：
 * 1、从干净的基础环境启动登录交互 shell，输出分隔标记后打印全部变量，5 秒超时
 * 2、按标记截取并解析；失败时退回当前环境（去掉 Claude Code 运行时注入的变量）
 */
func Login() []string {
	if runtime.GOOS == "windows" {
		return Base()
	}
	loginOnce.Do(func() {
		// 1、登录 shell
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, Shell(), "-l", "-i", "-c", `printf '\000PD-ENV\000'; env -0`)
		cmd.Env = Base()
		out, err := cmd.Output()
		// 2、解析
		i := bytes.LastIndex(out, []byte(marker))
		if err != nil || i < 0 {
			return
		}
		for _, kv := range bytes.Split(out[i+len(marker):], []byte{0}) {
			if s := string(kv); strings.Contains(s, "=") {
				loginEnv = append(loginEnv, s)
			}
		}
	})
	if len(loginEnv) == 0 {
		return withoutRuntime(os.Environ())
	}
	return append([]string(nil), loginEnv...)
}

/** withoutRuntime：去掉 Claude Code 运行时注入的变量，避免子进程误以为自己运行在另一个 Claude Code 里 */
func withoutRuntime(env []string) []string {
	var out []string
	for _, kv := range env {
		k := strings.SplitN(kv, "=", 2)[0]
		if k == "CLAUDECODE" || strings.HasPrefix(k, "CLAUDE_CODE_") || strings.HasPrefix(k, "CLAUDE_AGENT_SDK") {
			continue
		}
		out = append(out, kv)
	}
	return out
}
