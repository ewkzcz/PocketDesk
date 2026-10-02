/**
 * 配置目录查找测试。
 */
package confdir

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

/** 没有任何自定义时用默认位置 */
func TestDefaults(t *testing.T) {
	home := t.TempDir()
	if got := Claude(home); got != filepath.Join(home, ".claude") {
		t.Fatalf("Claude 默认目录 %s", got)
	}
	if got := Codex(home); got != filepath.Join(home, ".codex") {
		t.Fatalf("Codex 默认目录 %s", got)
	}
	if got := CCSwitch(home); got != filepath.Join(home, ".cc-switch") {
		t.Fatalf("CC Switch 默认目录 %s", got)
	}
}

/** CC Switch 改过数据目录时跟着走，并读取其中为 Claude Code、Codex 指定的目录 */
func TestCCSwitchOverrides(t *testing.T) {
	home := t.TempDir()
	data := filepath.Join(home, "sync", "ccs")
	os.MkdirAll(data, 0o755)
	os.WriteFile(filepath.Join(data, "settings.json"), []byte(`{"claudeConfigDir":"~/work/.claude","codexConfigDir":"/opt/codex"}`), 0o644)
	base := appDataDir(home)
	os.MkdirAll(filepath.Join(base, ccSwitchID), 0o755)
	os.WriteFile(filepath.Join(base, ccSwitchID, "app_paths.json"), []byte(`{"app_config_dir_override":"~/sync/ccs"}`), 0o644)
	if got := CCSwitch(home); got != data {
		t.Fatalf("应使用 CC Switch 自定义的数据目录 %s", got)
	}
	if got := Claude(home); got != filepath.Join(home, "work", ".claude") {
		t.Fatalf("应使用 CC Switch 指定的 Claude 目录 %s", got)
	}
	if got := Codex(home); got != "/opt/codex" {
		t.Fatalf("应使用 CC Switch 指定的 Codex 目录 %s", got)
	}
	// 自定义目录不存在时退回默认位置
	os.RemoveAll(data)
	if got := CCSwitch(home); got != filepath.Join(home, ".cc-switch") {
		t.Fatalf("自定义目录不存在时应退回默认 %s", got)
	}
}

/** 当前用户设置了环境变量时优先使用 */
func TestEnvFirst(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil || runtime.GOOS == "windows" {
		t.Skip()
	}
	old := Env
	t.Cleanup(func() { Env = old })
	Env = func(k string) string {
		return map[string]string{"CLAUDE_CONFIG_DIR": "/x/claude", "CODEX_HOME": "~/cx"}[k]
	}
	if got := Claude(home); got != "/x/claude" {
		t.Fatalf("CLAUDE_CONFIG_DIR %s", got)
	}
	if got := Codex(home); got != filepath.Join(home, "cx") {
		t.Fatalf("CODEX_HOME %s", got)
	}
	// 其他主目录（如测试用的临时目录）不读环境变量
	if got := Claude(t.TempDir()); filepath.Base(got) != ".claude" {
		t.Fatalf("临时主目录不应读环境变量 %s", got)
	}
}
