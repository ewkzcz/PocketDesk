/**
 * 多地址监听：对每个局域网、Tailscale 与回环地址单独监听，地址变化时增删监听。
 */
package netutil

import (
	"context"
	"log/slog"
	"net"
	"sync"
	"time"
)

/** ListenerSet：按地址管理的一组监听 */
type ListenerSet struct {
	port    int
	serve   func(net.Listener)
	list    func() []string
	mu      sync.Mutex
	active  map[string]net.Listener
	refresh time.Duration
}

/** NewListenerSet：serve 在每个新监听上阻塞运行，list 返回应监听的地址 */
func NewListenerSet(port int, list func() []string, serve func(net.Listener)) *ListenerSet {
	return &ListenerSet{port: port, serve: serve, list: list, active: map[string]net.Listener{}, refresh: 30 * time.Second}
}

/** DefaultAddrs：回环加全部局域网与 Tailscale 地址 */
func DefaultAddrs() []string {
	out := []string{"127.0.0.1"}
	for _, a := range Private() {
		out = append(out, a.IP)
	}
	return out
}

/**
 * Sync：对齐监听与当前地址
 *
 * 处理流程：
 * 1、为新出现的地址开启监听
 * 2、关闭已消失地址的监听
 */
func (s *ListenerSet) Sync() {
	want := map[string]bool{}
	for _, ip := range s.list() {
		want[ip] = true
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// 1、新增
	for ip := range want {
		if _, ok := s.active[ip]; ok {
			continue
		}
		ln, err := net.Listen("tcp", HostPort(ip, s.port))
		if err != nil {
			slog.Warn("监听失败", "addr", ip, "err", err)
			continue
		}
		s.active[ip] = ln
		go s.serve(ln)
	}
	// 2、移除
	for ip, ln := range s.active {
		if !want[ip] {
			ln.Close()
			delete(s.active, ip)
		}
	}
}

/** Run：定期对齐，直到上下文取消后关闭全部监听 */
func (s *ListenerSet) Run(ctx context.Context) {
	s.Sync()
	t := time.NewTicker(s.refresh)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			s.mu.Lock()
			for ip, ln := range s.active {
				ln.Close()
				delete(s.active, ip)
			}
			s.mu.Unlock()
			return
		case <-t.C:
			s.Sync()
		}
	}
}

/** Addrs：当前正在监听的地址 */
func (s *ListenerSet) Addrs() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.active))
	for ip := range s.active {
		out = append(out, ip)
	}
	return out
}
