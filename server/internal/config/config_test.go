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
		c.Render.PageSize = "a4"
	}); err != nil {
		t.Fatal(err)
	}
	s2, err := Open(p)
	if err != nil {
		t.Fatal(err)
	}
	c := s2.Get()
	if !c.Features.Terminal || c.Port != 8443 || c.Render.PageSize != "a4" {
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
