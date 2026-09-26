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
