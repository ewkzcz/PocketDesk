/**
 * CC Switch 供应商单元测试：用临时数据库模拟 CC Switch 的数据。
 */
package ccswitch

import (
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

/** fakeHome：建一个带 CC Switch 数据库与 Claude 设置的临时主目录 */
func fakeHome(t *testing.T) {
	home := t.TempDir()
	old := Home
	Home = func() string { return home }
	t.Cleanup(func() { Home = old })
	os.MkdirAll(filepath.Join(home, ".cc-switch"), 0o755)
	os.MkdirAll(filepath.Join(home, ".claude"), 0o755)
	os.WriteFile(filepath.Join(home, ".claude", "settings.json"), []byte(`{"env":{"ANTHROPIC_BASE_URL":"https://old","ANTHROPIC_MODEL":"old-model","OTHER":"1"}}`), 0o644)
	db, err := sql.Open("sqlite", filepath.Join(home, ".cc-switch", "cc-switch.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	db.Exec(`CREATE TABLE providers (id TEXT, app_type TEXT, name TEXT, settings_config TEXT, sort_index INTEGER, created_at INTEGER, is_current BOOLEAN)`)
	ins := func(id, app, name, cfg string, cur int) {
		if _, err := db.Exec(`INSERT INTO providers VALUES(?,?,?,?,?,?,?)`, id, app, name, cfg, 0, 0, cur); err != nil {
			t.Fatal(err)
		}
	}
	ins("ds", "claude", "DeepSeek", `{"env":{"ANTHROPIC_AUTH_TOKEN":"sk-a","ANTHROPIC_BASE_URL":"https://api.deepseek.com/anthropic","ANTHROPIC_DEFAULT_OPUS_MODEL":"deepseek-pro"},"model":"opus"}`, 1)
	cx := map[string]any{"auth": map[string]string{"OPENAI_API_KEY": "sk-b"}, "config": "model_provider = \"custom\"\nmodel = \"gpt-x\"\nmodel_reasoning_effort = \"high\"\nnotify = [\"a\"]\n\n[model_providers.custom]\nname = \"c\"\nbase_url = \"https://relay.example/v1\"\nwire_api = \"responses\"\n\n[projects.\"/x\"]\ntrust_level = \"trusted\"\n"}
	b, _ := json.Marshal(cx)
	ins("relay", "codex", "Relay", string(b), 0)
}

func TestListAndLaunch(t *testing.T) {
	fakeHome(t)
	ctx := context.Background()
	list, err := List(ctx, "claude")
	if err != nil || len(list) != 1 || !list[0].Current || list[0].Host != "api.deepseek.com" || strings.Join(list[0].Models, ",") != "deepseek-pro,opus" {
		t.Fatalf("Claude 供应商 %+v %v", list, err)
	}
	if b, _ := json.Marshal(list); strings.Contains(string(b), "sk-a") {
		t.Fatal("列表不应包含密钥")
	}
	l, err := LaunchFor("claude", list[0])
	if err != nil {
		t.Fatal(err)
	}
	var st struct {
		Env   map[string]string `json:"env"`
		Model string            `json:"model"`
	}
	json.Unmarshal([]byte(l.Settings), &st)
	if st.Env["ANTHROPIC_BASE_URL"] != "https://api.deepseek.com/anthropic" || st.Env["ANTHROPIC_MODEL"] != "" || st.Model != "opus" || l.Model != "opus" {
		t.Fatalf("Claude 附加设置 %s", l.Settings)
	}
	if _, ok := st.Env["OTHER"]; ok {
		t.Fatal("与接口无关的变量不应改动")
	}
	p, err := Get(ctx, "codex", "relay")
	if err != nil || p.Host != "relay.example" {
		t.Fatalf("Codex 供应商 %+v %v", p, err)
	}
	l, err = LaunchFor("codex", p)
	if err != nil {
		t.Fatal(err)
	}
	cfg := strings.Join(l.Config, "\n")
	for _, want := range []string{`model="gpt-x"`, `model_provider="custom"`, `model_reasoning_effort="high"`, `model_providers.custom.base_url="https://relay.example/v1"`, `model_providers.custom.env_key="` + KeyEnv + `"`} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("缺少 %s:\n%s", want, cfg)
		}
	}
	if strings.Contains(cfg, "projects") || strings.Contains(cfg, "notify") || strings.Contains(cfg, "sk-b") {
		t.Fatalf("不应覆盖无关设置或在命令行带密钥:\n%s", cfg)
	}
	if l.Model != "gpt-x" {
		t.Fatalf("默认模型 %q", l.Model)
	}
	if len(l.Env) != 1 || l.Env[0] != KeyEnv+"=sk-b" {
		t.Fatalf("密钥应经环境变量传入 %v", l.Env)
	}
	if _, err := Get(ctx, "codex", "nope"); err != ErrNotFound {
		t.Fatal("不存在的供应商应报错")
	}
}
