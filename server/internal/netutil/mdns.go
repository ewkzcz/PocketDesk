/**
 * mDNS 广播：在局域网网卡上发布 _pocketdesk._tcp 服务，手机自动发现电脑，电脑 IP 变化也能找到。
 */
package netutil

import (
	"net"

	"github.com/grandcat/zeroconf"
)

/** ServiceType：mDNS 服务类型 */
const ServiceType = "_pocketdesk._tcp"

/** Announcer：mDNS 广播句柄 */
type Announcer struct {
	server *zeroconf.Server
}

/**
 * Announce：在局域网网卡上广播服务
 *
 * 处理流程：
 * 1、只选择有局域网地址的网卡
 * 2、TXT 记录携带证书指纹前缀与协议版本，便于手机核对
 */
func Announce(instance string, port int, fingerprint string) (*Announcer, error) {
	// 1、网卡
	seen := map[string]bool{}
	var ifaces []net.Interface
	for _, a := range Private() {
		if a.Kind != KindLAN || seen[a.Interface] {
			continue
		}
		if ifc, err := net.InterfaceByName(a.Interface); err == nil {
			ifaces = append(ifaces, *ifc)
			seen[a.Interface] = true
		}
	}
	// 2、广播
	fp := fingerprint
	if len(fp) > 16 {
		fp = fp[:16]
	}
	s, err := zeroconf.Register(instance, ServiceType, "local.", port, []string{"v=1", "fp=" + fp}, ifaces)
	if err != nil {
		return nil, err
	}
	return &Announcer{server: s}, nil
}

/** Close：停止广播 */
func (a *Announcer) Close() {
	if a != nil && a.server != nil {
		a.server.Shutdown()
	}
}
