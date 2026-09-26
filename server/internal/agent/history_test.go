/**
 * 历史会话扫描单元测试。
 */
package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClaudeAndCodexHistory(t *testing.T) {
	home := t.TempDir()
	cwd := "/Users/me/Work/pay.ments"
	cdir := filepath.Join(home, ".claude", "projects", "-Users-me-Work-pay-ments")
	os.MkdirAll(cdir, 0o755)
	os.WriteFile(filepath.Join(cdir, "s-old.jsonl"), []byte(`{"type":"user","message":{"role":"user","content":"<command-name>x</command-name>"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"重构 支付\n模块"}]}}
`), 0o644)
	os.WriteFile(filepath.Join(cdir, "s-new.jsonl"), []byte(`{"type":"summary","summary":"修复登录"}`+"\n"), 0o644)
	later := time.Now().Add(time.Hour)
	os.Chtimes(filepath.Join(cdir, "s-new.jsonl"), later, later)
	list := ListHistory(KindClaude, home, cwd, 10)
	if len(list) != 2 || list[0].ID != "s-new" || list[0].Title != "修复登录" || list[1].Title != "重构 支付 模块" {
		t.Fatalf("Claude 历史 %+v", list)
	}
	xdir := filepath.Join(home, ".codex", "sessions", "2026", "10", "01")
	os.MkdirAll(xdir, 0o755)
	os.WriteFile(filepath.Join(xdir, "rollout-a.jsonl"), []byte(`{"type":"session_meta","payload":{"id":"th-1","cwd":"`+cwd+`"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>"}]}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"`+strings.Repeat("长", 50)+`"}]}}
`), 0o644)
	os.WriteFile(filepath.Join(xdir, "rollout-b.jsonl"), []byte(`{"type":"session_meta","payload":{"id":"th-2","cwd":"/other"}}`+"\n"), 0o644)
	x := ListHistory(KindCodex, home, cwd, 10)
	if len(x) != 1 || x[0].ID != "th-1" || !strings.HasSuffix(x[0].Title, "…") {
		t.Fatalf("Codex 历史 %+v", x)
	}
	if l := ListHistory(KindPi, home, cwd, 10); len(l) != 0 {
		t.Fatal("未支持的类型应返回空")
	}
	if l := ListHistory(KindClaude, home, cwd, 1); len(l) != 1 {
		t.Fatal("数量上限")
	}
}
