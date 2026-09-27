/**
 * 子进程环境测试：只带用户自己 shell 配置里的变量，不继承服务自身的变量。
 */
package sysenv

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
)

func has(env []string, kv string) bool { return slices.Contains(env, kv) }

func hasKey(env []string, k string) bool {
	return slices.ContainsFunc(env, func(kv string) bool { return strings.HasPrefix(kv, k+"=") })
}

func TestBaseAndLogin(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows 沿用当前环境")
	}
	zsh, err := exec.LookPath("zsh")
	if err != nil {
		t.Skip("本机没有 zsh")
	}
	home := t.TempDir()
	os.WriteFile(filepath.Join(home, ".zshrc"), []byte("export PD_FROM_RC=yes\nalias ccs='claude'\necho 启动时的输出\n"), 0o644)
	t.Setenv("HOME", home)
	t.Setenv("SHELL", zsh)
	t.Setenv("ANTHROPIC_BASE_URL", "https://leak.example")
	t.Setenv("CLAUDE_CODE_ENTRYPOINT", "claude-desktop")
	base := Base()
	if hasKey(base, "ANTHROPIC_BASE_URL") || hasKey(base, "CLAUDE_CODE_ENTRYPOINT") || !has(base, "HOME="+home) {
		t.Fatalf("基础环境不应带服务自身的变量：%v", base)
	}
	login := Login()
	if !has(login, "PD_FROM_RC=yes") {
		t.Fatalf("应带上 .zshrc 里的变量：%v", login)
	}
	if hasKey(login, "ANTHROPIC_BASE_URL") || hasKey(login, "CLAUDE_CODE_ENTRYPOINT") {
		t.Fatalf("登录环境不应继承服务自身的变量")
	}
	for _, kv := range login {
		if strings.Contains(kv, "启动时的输出") {
			t.Fatal("shell 启动时的输出混进了环境变量")
		}
	}
}
