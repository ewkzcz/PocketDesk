/**
 * 证书与令牌工具单元测试。
 */
package security

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIdentityPersistsFingerprint(t *testing.T) {
	dir := t.TempDir()
	a, err := LoadOrCreateIdentity(dir, "host")
	if err != nil {
		t.Fatal(err)
	}
	b, err := LoadOrCreateIdentity(dir, "host")
	if err != nil {
		t.Fatal(err)
	}
	if a.Fingerprint != b.Fingerprint || len(a.Fingerprint) != 64 {
		t.Fatalf("指纹不稳定: %s %s", a.Fingerprint, b.Fingerprint)
	}
	info, _ := os.Stat(filepath.Join(dir, "host.key"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("私钥权限应为 0600: %v", info.Mode())
	}
}

func TestIdentityBrokenFile(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "host.crt"), []byte("x"), 0o600)
	os.WriteFile(filepath.Join(dir, "host.key"), []byte("y"), 0o600)
	if _, err := LoadOrCreateIdentity(dir, "h"); err == nil {
		t.Fatal("损坏证书应报错")
	}
}

func TestTokens(t *testing.T) {
	a, b := NewToken(), NewToken()
	if a == b || len(a) < 40 {
		t.Fatal("令牌不够随机")
	}
	if HashToken(a) == a || len(HashToken(a)) != 64 {
		t.Fatal("哈希异常")
	}
	if !EqualConstant("x", "x") || EqualConstant("x", "y") {
		t.Fatal("比较错误")
	}
	if len(NewID()) != 32 {
		t.Fatal("ID 长度异常")
	}
}
