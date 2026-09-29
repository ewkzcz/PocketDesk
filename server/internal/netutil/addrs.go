/**
 * 网络地址：只挑选局域网与 Tailscale 地址用于监听和配对二维码，绝不监听公网地址。
 */
package netutil

import (
	"net"
	"sort"
	"strconv"
	"strings"
)

/** Addr：一个可用的本机地址 */
type Addr struct {
	IP        string `json:"ip"`
	Interface string `json:"interface"`
	Kind      string `json:"kind"`
}

/** 地址类别 */
const (
	KindLAN       = "lan"
	KindTailscale = "tailscale"
)

/** tailscaleV4：Tailscale 使用的运营商级 NAT 网段 */
var tailscaleV4 = mustCIDR("100.64.0.0/10")

/** tailscaleV6：Tailscale 的 IPv6 网段 */
var tailscaleV6 = mustCIDR("fd7a:115c:a1e0::/48")

/** proxyTunV4：Clash / mihomo / Stash 等代理软件的虚拟网卡默认使用的网段（RFC 2544 测试网段） */
var proxyTunV4 = mustCIDR("198.18.0.0/15")

/** proxyTunNames：代理软件虚拟网卡常见的名字（小写包含即算） */
var proxyTunNames = []string{"clash", "mihomo", "meta", "verge", "stash", "singbox", "sing-box", "wintun"}

/** IsProxyTUN：这块网卡是不是代理软件（Clash 等）的 TUN 虚拟网卡 */
func IsProxyTUN(name string, ips []net.IP) bool {
	low := strings.ToLower(name)
	for _, n := range proxyTunNames {
		if strings.Contains(low, n) {
			return true
		}
	}
	for _, ip := range ips {
		if proxyTunV4.Contains(ip) {
			return true
		}
	}
	return false
}

/** mustCIDR：解析网段 */
func mustCIDR(s string) *net.IPNet {
	_, n, err := net.ParseCIDR(s)
	if err != nil {
		panic(err)
	}
	return n
}

/**
 * Classify：判断地址类别，公网与回环返回空
 *
 * 处理流程：
 * 1、Tailscale 网段优先
 * 2、RFC1918 私有 IPv4 与 IPv6 唯一本地地址视为局域网
 */
func Classify(ip net.IP) string {
	// 1、Tailscale
	if tailscaleV4.Contains(ip) || tailscaleV6.Contains(ip) {
		return KindTailscale
	}
	// 2、局域网
	if ip.IsPrivate() {
		return KindLAN
	}
	return ""
}

/**
 * Private：列出本机全部局域网与 Tailscale 地址
 *
 * 处理流程：
 * 1、遍历已启用的非回环网卡
 * 2、保留分类为局域网或 Tailscale 的地址（IPv6 仅保留 Tailscale，避免链路本地地址）
 * 3、局域网在前、Tailscale 在后排序
 */
func Private() []Addr {
	out := []Addr{}
	ifs, err := net.Interfaces()
	if err != nil {
		return out
	}
	// 1、网卡
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		tun := isTUN(ifc, addrs)
		// 2、分类
		for _, a := range addrs {
			ipn, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipn.IP
			kind := Classify(ip)
			if kind == "" || (ip.To4() == nil && kind != KindTailscale) {
				continue
			}
			// Clash 等的 TUN 网卡可能用 172.19.0.1 这类私有地址，不是真正的局域网，不能放进配对二维码
			if tun && kind == KindLAN {
				continue
			}
			out = append(out, Addr{IP: ip.String(), Interface: ifc.Name, Kind: kind})
		}
	}
	// 3、排序
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind == KindLAN
		}
		return out[i].IP < out[j].IP
	})
	return out
}

/** ipsOf：网卡地址里的 IP */
func ipsOf(addrs []net.Addr) []net.IP {
	var out []net.IP
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			out = append(out, n.IP)
		}
	}
	return out
}

/** isTUN：代理软件的 TUN 网卡（Tailscale 自己的网卡不算） */
func isTUN(ifc net.Interface, addrs []net.Addr) bool {
	ips := ipsOf(addrs)
	for _, ip := range ips {
		if Classify(ip) == KindTailscale {
			return false
		}
	}
	return IsProxyTUN(ifc.Name, ips)
}

/** ProxyTUNs：本机开启的代理 TUN 网卡名（如 Clash 的 TUN 模式），没有时为空 */
func ProxyTUNs() []string {
	var out []string
	ifs, err := net.Interfaces()
	if err != nil {
		return out
	}
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 || ifc.Flags&net.FlagLoopback != 0 {
			continue
		}
		if addrs, err := ifc.Addrs(); err == nil && isTUN(ifc, addrs) {
			out = append(out, ifc.Name)
		}
	}
	return out
}

/** HostPort：拼接地址与端口，IPv6 加方括号 */
func HostPort(ip string, port int) string {
	return net.JoinHostPort(ip, strconv.Itoa(port))
}

/** IsAllowedRemote：请求来源必须是回环、局域网或 Tailscale 地址 */
func IsAllowedRemote(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || Classify(ip) != ""
}
