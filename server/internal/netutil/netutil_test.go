/**
 * 网络地址与多地址监听单元测试。
 */
package netutil

import (
	"net"
	"sync"
	"testing"
)

func TestClassify(t *testing.T) {
	cases := map[string]string{
		"192.168.1.5": KindLAN, "10.0.0.2": KindLAN, "172.20.1.1": KindLAN,
		"100.88.12.4": KindTailscale, "fd7a:115c:a1e0::1": KindTailscale,
		"8.8.8.8": "", "127.0.0.1": "", "100.128.0.1": "",
	}
	for ip, want := range cases {
		if got := Classify(net.ParseIP(ip)); got != want {
			t.Errorf("%s => %q 期望 %q", ip, got, want)
		}
	}
}

func TestIsAllowedRemote(t *testing.T) {
	for addr, want := range map[string]bool{
		"127.0.0.1:5000": true, "[::1]:80": true, "192.168.1.9:1": true, "100.70.0.1:1": true,
		"8.8.8.8:443": false, "garbage": false, "[2001:db8::1]:80": false,
	} {
		if IsAllowedRemote(addr) != want {
			t.Errorf("%s 期望 %v", addr, want)
		}
	}
	for _, a := range Private() {
		if Classify(net.ParseIP(a.IP)) == "" {
			t.Fatalf("列出了公网地址 %s", a.IP)
		}
	}
	if HostPort("::1", 8443) != "[::1]:8443" {
		t.Fatal("IPv6 端口拼接")
	}
}

func TestListenerSetSync(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	var mu sync.Mutex
	addrs := []string{"127.0.0.1"}
	served := 0
	s := NewListenerSet(port, func() []string { mu.Lock(); defer mu.Unlock(); return addrs }, func(l net.Listener) {
		mu.Lock()
		served++
		mu.Unlock()
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	})
	s.Sync()
	s.Sync()
	if len(s.Addrs()) != 1 {
		t.Fatal("重复对齐不应重复监听")
	}
	c, err := net.Dial("tcp", HostPort("127.0.0.1", port))
	if err != nil {
		t.Fatal(err)
	}
	c.Close()
	mu.Lock()
	addrs = nil
	mu.Unlock()
	s.Sync()
	if len(s.Addrs()) != 0 {
		t.Fatal("地址消失后应关闭监听")
	}
	if _, err := net.Dial("tcp", HostPort("127.0.0.1", port)); err == nil {
		t.Fatal("监听应已关闭")
	}
}
