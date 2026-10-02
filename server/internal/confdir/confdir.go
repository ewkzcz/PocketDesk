/**
 * 配置目录：找出 Claude Code、Codex 与 CC Switch 实际使用的数据目录，不写死在用户主目录下。
 *
 * 用户可以改这些目录：Claude Code 认 CLAUDE_CONFIG_DIR，Codex 认 CODEX_HOME，
 * CC Switch 可以在设置里改自己的数据目录，也可以单独指定 Claude Code、Codex 的配置目录。
 * 这里按工具自己的规则依次查找，找不到时才用默认位置。
 */
package confdir

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/ewkzcz/pocketdesk/server/internal/sysenv"
)

/** ccSwitchID：CC Switch 的应用标识，它的应用数据目录以此命名 */
const ccSwitchID = "com.ccswitch.desktop"

/** Env：读取用户环境变量（与 Agent 运行时一致，含 shell 配置文件里的设置），测试时替换 */
var Env = func(key string) string {
	prefix := key + "="
	for _, kv := range sysenv.Login() {
		if strings.HasPrefix(kv, prefix) {
			return kv[len(prefix):]
		}
	}
	return ""
}

/** realHome：当前用户的主目录；传入其他目录（如测试用的临时目录）时不读用户环境变量 */
func realHome(home string) bool {
	h, err := os.UserHomeDir()
	return err == nil && filepath.Clean(h) == filepath.Clean(home)
}

/** fromEnv：主目录是当前用户时读取环境变量里的目录 */
func fromEnv(home, key string) string {
	if !realHome(home) {
		return ""
	}
	return expand(home, Env(key))
}

/** expand：展开开头的 ~，去掉首尾空白 */
func expand(home, p string) string {
	p = strings.TrimSpace(p)
	switch {
	case p == "~":
		return home
	case strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`):
		return filepath.Join(home, p[2:])
	}
	return p
}

/**
 * Claude：Claude Code 的配置目录
 *
 * 处理流程：
 * 1、环境变量 CLAUDE_CONFIG_DIR
 * 2、CC Switch 设置里指定的 Claude Code 配置目录
 * 3、默认 ~/.claude
 */
func Claude(home string) string {
	if d := fromEnv(home, "CLAUDE_CONFIG_DIR"); d != "" {
		return d
	}
	if d := ccSwitchOverride(home, "claudeConfigDir"); d != "" {
		return d
	}
	return filepath.Join(home, ".claude")
}

/**
 * Codex：Codex 的数据目录
 *
 * 处理流程：
 * 1、环境变量 CODEX_HOME
 * 2、CC Switch 设置里指定的 Codex 配置目录
 * 3、默认 ~/.codex
 */
func Codex(home string) string {
	if d := fromEnv(home, "CODEX_HOME"); d != "" {
		return d
	}
	if d := ccSwitchOverride(home, "codexConfigDir"); d != "" {
		return d
	}
	return filepath.Join(home, ".codex")
}

/**
 * CCSwitch：CC Switch 的数据目录（含 cc-switch.db 与 settings.json）
 *
 * 处理流程：
 * 1、CC Switch 设置里改过数据目录时，取它记在应用数据目录 app_paths.json 中的位置（目录须存在）
 * 2、默认 ~/.cc-switch
 * 3、Windows 默认位置没有数据库时，兼容旧版本放在 HOME 环境变量目录下的数据
 */
func CCSwitch(home string) string {
	// 1、自定义目录
	if base := appDataDir(home); base != "" {
		var store map[string]any
		if b, err := os.ReadFile(filepath.Join(base, ccSwitchID, "app_paths.json")); err == nil && json.Unmarshal(b, &store) == nil {
			if p, _ := store["app_config_dir_override"].(string); p != "" {
				if d := expand(home, p); isDir(d) {
					return d
				}
			}
		}
	}
	// 2、默认位置
	def := filepath.Join(home, ".cc-switch")
	// 3、Windows 旧位置
	if runtime.GOOS == "windows" && !exists(filepath.Join(def, "cc-switch.db")) && realHome(home) {
		if h := strings.TrimSpace(os.Getenv("HOME")); h != "" {
			if legacy := filepath.Join(h, ".cc-switch"); exists(filepath.Join(legacy, "cc-switch.db")) {
				return legacy
			}
		}
	}
	return def
}

/** appDataDir：系统给应用存数据的目录（与 CC Switch 所用框架的规则一致） */
func appDataDir(home string) string {
	switch runtime.GOOS {
	case "darwin":
		return filepath.Join(home, "Library", "Application Support")
	case "windows":
		if realHome(home) {
			return os.Getenv("APPDATA")
		}
		return filepath.Join(home, "AppData", "Roaming")
	default:
		if x := os.Getenv("XDG_DATA_HOME"); x != "" && realHome(home) {
			return x
		}
		return filepath.Join(home, ".local", "share")
	}
}

/** ccSwitchOverride：CC Switch 设置里为某个工具指定的配置目录，没有指定时为空 */
func ccSwitchOverride(home, key string) string {
	b, err := os.ReadFile(filepath.Join(CCSwitch(home), "settings.json"))
	if err != nil {
		return ""
	}
	var s map[string]any
	if json.Unmarshal(b, &s) != nil {
		return ""
	}
	p, _ := s[key].(string)
	return expand(home, p)
}

/** exists：文件或目录存在 */
func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

/** isDir：目录存在 */
func isDir(p string) bool {
	info, err := os.Stat(p)
	return err == nil && info.IsDir()
}
