/**
 * CC Switch 供应商：只读读取 CC Switch 保存的模型供应商（接口地址、密钥、模型），
 * 生成单个会话的启动参数，让这个会话改用指定供应商，不改动电脑上的全局配置和 CC Switch 的数据。
 */
package ccswitch

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"
	_ "modernc.org/sqlite"
)

/** Home：用户主目录，测试时替换 */
var Home = func() string {
	h, _ := os.UserHomeDir()
	return h
}

/** ErrNotFound：没有这个供应商 */
var ErrNotFound = errors.New("CC Switch 里没有这个供应商")

/** KeyEnv：Codex 自定义供应商读取密钥的环境变量名 */
const KeyEnv = "POCKETDESK_PROVIDER_KEY"

/** Provider：一个供应商，Models 为它配置里写到的模型 */
type Provider struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Current bool     `json:"current"`
	Host    string   `json:"host"`
	Models  []string `json:"models"`
	config  json.RawMessage
}

/** Launch：会话改用某供应商时的启动参数 */
type Launch struct {
	// Settings：Claude Code 的附加设置（JSON），以 --settings 传入，优先于用户设置
	Settings string
	// Config：Codex 的 -c 覆盖项
	Config []string
	// Env：附加环境变量
	Env []string
	// Model：供应商配置的默认模型，会话没选模型时使用（续聊时 Agent 会沿用旧会话的模型，需要明确指定）
	Model string
}

/** dbPath：CC Switch 数据库位置 */
func dbPath() string { return filepath.Join(Home(), ".cc-switch", "cc-switch.db") }

/** Available：电脑上装了 CC Switch 并有数据 */
func Available() bool {
	_, err := os.Stat(dbPath())
	return err == nil
}

/** open：只读打开数据库，CC Switch 同时运行也不影响 */
func open() (*sql.DB, error) {
	if !Available() {
		return nil, errors.New("电脑上没有找到 CC Switch")
	}
	return sql.Open("sqlite", "file:"+filepath.ToSlash(dbPath())+"?mode=ro&_pragma=busy_timeout(3000)")
}

/**
 * List：某个 Agent（claude、codex）的全部供应商，按 CC Switch 中的顺序
 *
 * 处理流程：
 * 1、只读查询供应商表
 * 2、从配置中取出接口地址与模型，不返回密钥
 */
func List(ctx context.Context, app string) ([]Provider, error) {
	db, err := open()
	if err != nil {
		return nil, err
	}
	defer db.Close()
	// 1、查询
	rows, err := db.QueryContext(ctx, `SELECT id,name,settings_config,is_current FROM providers WHERE app_type=? ORDER BY COALESCE(sort_index,999999), created_at, name`, app)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Provider{}
	for rows.Next() {
		var p Provider
		var cfg string
		var cur int
		if err := rows.Scan(&p.ID, &p.Name, &cfg, &cur); err != nil {
			return nil, err
		}
		// 2、地址与模型
		p.Current = cur == 1
		p.config = json.RawMessage(cfg)
		p.Host, p.Models = describe(app, p.config)
		out = append(out, p)
	}
	return out, rows.Err()
}

/** Get：按 ID 取一个供应商 */
func Get(ctx context.Context, app, id string) (Provider, error) {
	list, err := List(ctx, app)
	if err != nil {
		return Provider{}, err
	}
	for _, p := range list {
		if p.ID == id {
			return p, nil
		}
	}
	return Provider{}, ErrNotFound
}

/** claudeConfig：Claude 供应商配置 */
type claudeConfig map[string]any

/** codexConfig：Codex 供应商配置，config 为 TOML 文本 */
type codexConfig struct {
	Auth   map[string]any `json:"auth"`
	Config string         `json:"config"`
}

/** claudeModelKeys：Claude 配置里写模型的环境变量 */
var claudeModelKeys = []string{"ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"}

/** describe：接口地址的主机名与配置中出现的模型 */
func describe(app string, raw json.RawMessage) (host string, models []string) {
	seen := map[string]bool{}
	add := func(m string) {
		if m = strings.TrimSpace(m); m != "" && !seen[m] {
			seen[m] = true
			models = append(models, m)
		}
	}
	switch app {
	case "claude":
		var c claudeConfig
		json.Unmarshal(raw, &c)
		env := strMap(c["env"])
		host = hostOf(env["ANTHROPIC_BASE_URL"])
		for _, k := range claudeModelKeys {
			add(env[k])
		}
		if m, ok := c["model"].(string); ok {
			add(m)
		}
	case "codex":
		var c codexConfig
		json.Unmarshal(raw, &c)
		var t map[string]any
		toml.Decode(c.Config, &t)
		if m, ok := t["model"].(string); ok {
			add(m)
		}
		mp, _ := t["model_provider"].(string)
		if provs, ok := t["model_providers"].(map[string]any); ok {
			if one, ok := provs[mp].(map[string]any); ok {
				host, _ = one["base_url"].(string)
				host = hostOf(host)
			}
		}
	}
	if models == nil {
		models = []string{}
	}
	return host, models
}

/** hostOf：地址中的主机名 */
func hostOf(u string) string {
	if p, err := url.Parse(strings.TrimSpace(u)); err == nil && p.Host != "" {
		return p.Host
	}
	return ""
}

/** strMap：取出字符串值组成的映射 */
func strMap(v any) map[string]string {
	out := map[string]string{}
	if m, ok := v.(map[string]any); ok {
		for k, x := range m {
			switch y := x.(type) {
			case string:
				out[k] = y
			case float64:
				out[k] = strconv.FormatFloat(y, 'f', -1, 64)
			case bool:
				out[k] = strconv.FormatBool(y)
			}
		}
	}
	return out
}

/**
 * LaunchFor：生成会话改用该供应商时的启动参数
 *
 * Claude Code：把供应商的整份设置以 --settings 传入；电脑当前设置里有、该供应商没有的接口与模型变量置空，
 * 避免沿用其他供应商的地址或模型。
 * Codex：把供应商 TOML 中模型相关设置与所选接口表展开成 -c 覆盖项，密钥经环境变量传入。
 */
func LaunchFor(app string, p Provider) (Launch, error) {
	var l Launch
	var err error
	switch app {
	case "claude":
		l, err = claudeLaunch(p.config)
	case "codex":
		l, err = codexLaunch(p.config)
	default:
		return Launch{}, fmt.Errorf("%s 暂不支持切换供应商", app)
	}
	return l, err
}

/** claudeLaunch：Claude Code 的附加设置 */
func claudeLaunch(raw json.RawMessage) (Launch, error) {
	var c claudeConfig
	if err := json.Unmarshal(raw, &c); err != nil || c == nil {
		return Launch{}, errors.New("供应商配置格式不正确")
	}
	env, _ := c["env"].(map[string]any)
	if env == nil {
		env = map[string]any{}
	}
	// 电脑当前生效的设置里残留的接口、密钥与模型变量置空
	var live struct {
		Env map[string]any `json:"env"`
	}
	if b, err := os.ReadFile(filepath.Join(Home(), ".claude", "settings.json")); err == nil {
		json.Unmarshal(b, &live)
	}
	for k := range live.Env {
		if _, ok := env[k]; !ok && strings.HasPrefix(k, "ANTHROPIC_") {
			env[k] = ""
		}
	}
	c["env"] = env
	b, err := json.Marshal(c)
	if err != nil {
		return Launch{}, err
	}
	model, _ := env["ANTHROPIC_MODEL"].(string)
	if model == "" {
		model, _ = c["model"].(string)
	}
	return Launch{Settings: string(b), Model: model}, nil
}

/** codexKeys：决定供应商与模型的顶层设置，以 model 开头的项也一并带上 */
var codexKeys = map[string]bool{"disable_response_storage": true, "preferred_auth_method": true}

/** codexLaunch：Codex 的 -c 覆盖项，只覆盖模型相关设置与所选供应商的接口表 */
func codexLaunch(raw json.RawMessage) (Launch, error) {
	var c codexConfig
	if err := json.Unmarshal(raw, &c); err != nil {
		return Launch{}, errors.New("供应商配置格式不正确")
	}
	var t map[string]any
	if _, err := toml.Decode(c.Config, &t); err != nil {
		return Launch{}, fmt.Errorf("供应商配置格式不正确：%w", err)
	}
	var l Launch
	l.Model, _ = t["model"].(string)
	keys := make([]string, 0, len(t))
	for k := range t {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if !codexKeys[k] && !strings.HasPrefix(k, "model") || k == "model_providers" {
			continue
		}
		if v, ok := tomlValue(t[k]); ok {
			l.Config = append(l.Config, tomlKey(k)+"="+v)
		}
	}
	mp, _ := t["model_provider"].(string)
	provs, _ := t["model_providers"].(map[string]any)
	one, _ := provs[mp].(map[string]any)
	fields := make([]string, 0, len(one))
	for k := range one {
		fields = append(fields, k)
	}
	sort.Strings(fields)
	for _, k := range fields {
		if v, ok := tomlValue(one[k]); ok {
			l.Config = append(l.Config, "model_providers."+tomlKey(mp)+"."+tomlKey(k)+"="+v)
		}
	}
	// 自定义供应商的密钥经环境变量传入，不写在命令行上
	if key, _ := c.Auth["OPENAI_API_KEY"].(string); one != nil && key != "" {
		l.Config = append(l.Config, "model_providers."+tomlKey(mp)+".env_key="+strconv.Quote(KeyEnv))
		l.Env = append(l.Env, KeyEnv+"="+key)
	}
	return l, nil
}

/** tomlKey：键名含特殊字符时加引号 */
func tomlKey(k string) string {
	for _, r := range k {
		if !(r == '_' || r == '-' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			b, _ := json.Marshal(k)
			return string(b)
		}
	}
	return k
}

/** tomlValue：单个值的 TOML 写法，JSON 的字符串、数字、布尔与数组写法与 TOML 兼容 */
func tomlValue(v any) (string, bool) {
	switch x := v.(type) {
	case string, bool, int64, float64:
		b, err := json.Marshal(x)
		return string(b), err == nil
	case []any:
		parts := make([]string, 0, len(x))
		for _, it := range x {
			s, ok := tomlValue(it)
			if !ok {
				return "", false
			}
			parts = append(parts, s)
		}
		return "[" + strings.Join(parts, ", ") + "]", true
	}
	return "", false
}
