/**
 * 配置模块单元测试。
 */
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpenWritesDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "sub", "config.json")
	s, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	c := s.Get()
	if c.Port != 8443 || c.Features.Terminal || !c.Features.Agents {
		t.Fatalf("默认值异常: %+v", c)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatal("默认配置未落盘")
	}
}

func TestUpdatePersistsAndNormalizes(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	s, _ := Open(p)
	if _, err := s.Update(func(c *Config) {
		c.Features.Terminal = true
		c.Port = -1
	}); err != nil {
		t.Fatal(err)
	}
	s2, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	c := s2.Get()
	if !c.Features.Terminal || c.Port != 8443 {
		t.Fatalf("重新加载后异常: %+v", c)
	}
}

func TestOpenRejectsBrokenFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(p, []byte("{broken"), 0o600)
	if _, err := Open(p); err == nil {
		t.Fatal("损坏的配置应报错")
	}
}

func TestDefaultDataDirEnv(t *testing.T) {
	t.Setenv("POCKETDESK_HOME", "/tmp/pdx")
	d, err := DefaultDataDir()
	if err != nil || d != "/tmp/pdx" {
		t.Fatalf("环境变量未生效: %s %v", d, err)
	}
}

func TestAgentsDefaultsFilled(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(p, []byte(`{"agents":{"dsh":["deepseek","--acp"]},"notify":{"kind":"weird"}}`), 0o600)
	s, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	c := s.Get()
	if c.Agents["dsh"][0] != "deepseek" || c.Agents["claude"][0] != "claude" {
		t.Fatalf("Agent 命令合并异常: %v", c.Agents)
	}
	if c.Notify.Kind != "" {
		t.Fatal("非法推送类型应清空")
	}
}

func TestDefaultDirs(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	base := baseDir(home)
	// 新安装：默认工作目录与发件目录在 PocketDesk 文件夹下，收件目录就是默认工作目录
	d := Default()
	if d.DefaultWorkspace != filepath.Join(base, "Workspace") || d.Transfer.InboxDir != d.DefaultWorkspace || d.Transfer.OutboxDir != filepath.Join(base, "Outbox") {
		t.Fatalf("默认目录异常: %+v", d)
	}
	// 旧版默认位置改到新位置，旧收件目录改为默认工作目录，用户自己选的目录保持不变
	p := filepath.Join(t.TempDir(), "config.json")
	old := filepath.Join(home, "PocketDesk")
	raw := `{"transfer":{"inboxDir":"` + filepath.ToSlash(filepath.Join(old, "Inbox")) + `","outboxDir":"/data/out"},"defaultWorkspace":"` + filepath.ToSlash(filepath.Join(old, "Workspace")) + `"}`
	if err := os.WriteFile(p, []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	c := s.Get()
	if c.Transfer.InboxDir != c.DefaultWorkspace || c.DefaultWorkspace != filepath.Join(base, "Workspace") || c.Transfer.OutboxDir != "/data/out" {
		t.Fatalf("旧目录迁移异常: %+v", c.Transfer)
	}
}
