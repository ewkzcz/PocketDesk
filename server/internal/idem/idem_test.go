/**
 * 重复请求识别单元测试。
 */
package idem

import (
	"testing"
	"time"
)

func TestRecent(t *testing.T) {
	now := time.Unix(0, 0)
	r := New(2, time.Minute)
	r.now = func() time.Time { return now }
	if r.Has("") || r.Has("a") {
		t.Fatal("未记录前不应命中")
	}
	r.Add("")
	r.Add("a")
	if !r.Has("a") {
		t.Fatal("记录后应命中")
	}
	r.Add("b")
	r.Add("c")
	if r.Has("a") || !r.Has("b") || !r.Has("c") {
		t.Fatal("超过上限应淘汰最早的编号")
	}
	now = now.Add(2 * time.Minute)
	if r.Has("c") {
		t.Fatal("过期后不应命中")
	}
}

func TestRecentZeroValue(t *testing.T) {
	var r Recent
	r.Add("x")
	if !r.Has("x") || r.Has("y") {
		t.Fatal("零值应可直接使用")
	}
}
