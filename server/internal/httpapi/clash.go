/**
 * Clash TUN 兼容：电脑开着 Clash 的 TUN 模式时，Tailscale 自己的加密隧道与手机发来的请求不能再被代理接管，
 * 否则手机连不上；Claude Code 等命令行工具的流量仍走 Clash（住宅出口）。这里提供可粘贴到 Clash 扩展脚本里的配置。
 */
package httpapi

import "net/http"

/**
 * clashScript：Clash Verge / Mihomo 的扩展脚本
 *
 * 只做放行，不改代理节点：
 * 1、Tailscale 网段与 Tailscale 自己的进程、域名直连，隧道才能建立并保持直连
 * 2、TUN 不接管 Tailscale 网段，手机发来的请求与电脑的回包不经过代理
 * 3、Tailscale 域名不走 fake-ip，避免被解析成假地址
 * Claude Code 的流量没有被放行，仍然走原来的规则与住宅出口。
 */
const clashScript = `// PocketDesk：让 Tailscale 与 Clash TUN 共存
// 使用：Clash Verge → 订阅页 → 「全局扩展脚本」→ 粘贴保存（不要粘贴到某个订阅自己的「扩展脚本」里，会覆盖你原来的脚本）。
// 它和你订阅里的脚本各自独立运行，只往配置里追加放行规则；不改节点，也不影响 Claude Code 走住宅出口。
// 如果你的客户端没有「全局扩展脚本」，就把下面 main 里的内容原样放进你自己 main 的最前面，不要出现两个 main。
function main(config) {
  const direct = [
    'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve',
    'IP-CIDR6,fd7a:115c:a1e0::/48,DIRECT,no-resolve',
    'DOMAIN-SUFFIX,tailscale.com,DIRECT',
    'DOMAIN-SUFFIX,tailscale.io,DIRECT',
    'DOMAIN-SUFFIX,ts.net,DIRECT',
    'PROCESS-NAME,tailscaled,DIRECT',
    'PROCESS-NAME,Tailscale,DIRECT',
    'PROCESS-NAME,tailscaled.exe,DIRECT',
    'PROCESS-NAME,tailscale-ipn.exe,DIRECT',
    'PROCESS-NAME,PocketDesk,DIRECT',
    'PROCESS-NAME,PocketDesk.exe,DIRECT',
  ];
  // 放在最前面（Clash 按顺序匹配）；已经有的不重复添加
  const rest = (config.rules || []).filter((r) => !direct.includes(r));
  config.rules = direct.concat(rest);

  // TUN 不接管 Tailscale 网段
  config.tun = config.tun || {};
  const exclude = new Set(config.tun['route-exclude-address'] || []);
  ['100.64.0.0/10', 'fd7a:115c:a1e0::/48'].forEach((x) => exclude.add(x));
  config.tun['route-exclude-address'] = Array.from(exclude);

  // Tailscale 域名不用 fake-ip
  config.dns = config.dns || {};
  const filter = new Set(config.dns['fake-ip-filter'] || []);
  ['+.tailscale.com', '+.tailscale.io', '+.ts.net'].forEach((x) => filter.add(x));
  config.dns['fake-ip-filter'] = Array.from(filter);

  // 嗅探不改写 Tailscale 域名
  config.sniffer = config.sniffer || {};
  const skip = new Set(config.sniffer['skip-domain'] || []);
  ['+.tailscale.com', '+.tailscale.io', '+.ts.net'].forEach((x) => skip.add(x));
  config.sniffer['skip-domain'] = Array.from(skip);
  return config;
}
`

/** adminClashScript：返回 Clash 扩展脚本，桌面端复制后粘贴到 Clash */
func (s *Server) adminClashScript(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]string{"script": clashScript})
}
