// 住宅出口分流脚本（HomeGuard、PocketDesk 通用，放在 Clash Verge 的「全局扩展脚本」里）
//
// 效果：
//   · Claude 桌面端、Claude Code、Codex 桌面端、Codex CLI、ChatGPT 桌面端发出的全部请求 → 住宅出口
//   · 谷歌相关请求，以及 Claude / ChatGPT 网页 → 住宅出口
//   · HomeGuard 的出口核验与体检探测 → 住宅出口，检测结果反映的就是 Claude 实际走的线路
//   · 其他所有请求 → 基础节点
//   · 住宅出口 = 先连基础节点，再从住宅代理出去，网站看到的是住宅 IP
//   · 默认不经过代理的只有：本机、局域网、Tailscale 组网内部、连接基础节点本身（这些本来就不上公网或无法代理）
//   · 防 DNS 与 IPv6 泄露：DNS 查询走基础节点且全程加密；IPv6 也由 TUN 接管
//
// 分组（Clash 里只显示这两组，订阅自带的分组保留但隐藏）：
//   基础节点：选一个机场节点，所有流量都先经过它
//   住宅出口：选一个住宅代理，它架在基础节点上面，只给上面列出的程序和网站用
//
// 用法：
//   1、只改下面「填写区」，其余不要动
//   2、Clash Verge → 订阅页 →「全局扩展脚本」→ 整份粘贴 → 保存
//   3、订阅自己的「扩展脚本」保持为空，里面如果也改规则，会覆盖这里的设置（订阅脚本比全局脚本后执行）
//   4、在「基础节点」组里选机场节点，在「住宅出口」组里选住宅代理
//   5、Clash Verge 设置里：TUN 模式、IPv6 保持打开，「DNS 覆写」保持关闭（打开会替换这里的防泄露设置）
// 换订阅、换节点不用改脚本；换住宅代理只改填写区。

function main(config) {
  // ==================== 填写区 ====================
  // 住宅代理：可填多个，在「住宅出口」组里切换；按 Clash 的代理写法填，类型和字段不限（socks5、http、vless 等）
  // 不用填 dialer-proxy，脚本会让它经「基础节点」连出
  const RESIDENTIAL = [
    { name: '🏠 住宅出口 01', type: 'socks5', server: '填写地址', port: 0, username: '填写用户名', password: '填写密码' }
  ];

  // 走住宅出口的网站（按域名后缀）；不需要的删掉即可
  const RESIDENTIAL_DOMAINS = [
    // Claude
    'anthropic.com', 'claude.ai', 'claude.com', 'claudeusercontent.com',
    // ChatGPT / Codex
    'openai.com', 'chatgpt.com', 'oaistatic.com', 'oaiusercontent.com',
    // 谷歌
    'google.com', 'googleapis.com', 'gstatic.com', 'googleusercontent.com', 'ggpht.com', 'gvt1.com', 'gvt2.com',
    'googlevideo.com', 'youtube.com', 'ytimg.com', 'youtu.be', 'withgoogle.com', 'google.dev', 'gmail.com',
    'googlesource.com', 'android.com', 'firebaseio.com', 'goo.gl', 'recaptcha.net', 'googletagmanager.com',
    'google-analytics.com', 'doubleclick.net', 'googleadservices.com', 'gemini.google.com'
  ];
  // ===============================================

  const BASE = '基础节点';
  const RES_GROUP = '住宅出口';

  // HomeGuard 核验出口、体检（出口、时区、WebRTC）用的网址：跟 Claude 走同一条线路，检测结果才有意义
  // （这些探测由 curl 发出，没法按程序区分，只能按网址）
  const CHECK_DOMAINS = [
    'ipify.org', 'icanhazip.com', 'ipinfo.io', 'ifconfig.me', 'ip.sb', 'myip.com', 'ip-api.com', 'ipapi.co'
  ];
  const CHECK_HOSTS = [
    'www.cloudflare.com', 'stun.cloudflare.com',
    // 「国内视角」探测
    'members.3322.org', 'whois.pconline.com.cn', 'qifu-api.baidubce.com', 'api.live.bilibili.com', 'www.taobao.com'
  ];

  // 走住宅出口的程序，按程序所在路径匹配（macOS、Windows 通用，不区分大小写）
  const RESIDENTIAL_APPS = [
    '(?i)/claude\\.app/',          // Claude 桌面端，以及它自带的 Claude Code
    '(?i)/claude/versions/',       // Claude Code CLI（官方安装方式）
    '(?i)/codex\\.app/',           // Codex 桌面端
    '(?i)/codex$',                 // Codex CLI
    '(?i)/chatgpt\\.app/',         // ChatGPT 桌面端（含 Codex）
    '(?i)\\\\(claude|codex|chatgpt)\\.exe$', // Windows 上的 Claude、Claude Code、Codex、ChatGPT
    '(?i)/homeguard\\.app/'        // HomeGuard
  ];

  // 1、住宅代理：没填完整的跳过；全部经基础节点连出
  const filled = (p) => p && p.server && p.port && String(p.server).indexOf('填写') < 0;
  // 默认开 UDP、只用 IPv4，填了的以填写为准；一律经基础节点连出
  const residential = RESIDENTIAL.filter(filled).map((p) => Object.assign({ udp: true, 'ip-version': 'ipv4' }, p, { 'dialer-proxy': BASE }));
  const resNames = residential.map((p) => p.name);

  // 2、基础节点候选：订阅里的节点，去掉流量、到期提示这类假节点
  const INFO = /剩余|到期|套餐|流量|官网|重置|expire|traffic|reset/i;
  config.proxies = (config.proxies || []).filter((p) => resNames.indexOf(p.name) < 0);
  const nodes = config.proxies.map((p) => p.name).filter((n) => !INFO.test(n));
  config.proxies = config.proxies.concat(residential);

  // 3、分组：订阅自带的分组保留（别的脚本可能引用它们），只是隐藏；规则里只用下面两组
  //    默认选第一项：基础节点默认机场节点，住宅出口默认住宅代理；最后一项是手动退路
  //    （住宅出口可退到只走基础节点，基础节点可退到直连，选了就会暴露对应 IP，需自己确认）
  const mine = [BASE, RES_GROUP];
  const others = (config['proxy-groups'] || []).filter((g) => mine.indexOf(g.name) < 0).map((g) => Object.assign({}, g, { hidden: true }));
  config['proxy-groups'] = [
    { name: BASE, type: 'select', proxies: nodes.concat(['DIRECT']) },
    { name: RES_GROUP, type: 'select', proxies: resNames.concat([BASE]) }
  ].concat(others);

  // 4、规则：整份替换
  const local = [
    'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
    'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
    'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,169.254.0.0/16,DIRECT,no-resolve',
    'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve',       // Tailscale 组网内部
    'IP-CIDR6,fd7a:115c:a1e0::/48,DIRECT,no-resolve'  // Tailscale 组网内部（IPv6）
  ];
  config.rules = local.concat(
    // 拦截 QUIC，浏览器会改用 TCP，确保按规则走代理
    ['AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'],
    RESIDENTIAL_APPS.map((r) => 'PROCESS-PATH-REGEX,' + r + ',' + RES_GROUP),
    RESIDENTIAL_DOMAINS.concat(CHECK_DOMAINS).map((d) => 'DOMAIN-SUFFIX,' + d + ',' + RES_GROUP),
    CHECK_HOSTS.map((d) => 'DOMAIN,' + d + ',' + RES_GROUP),
    ['GEOSITE,google,' + RES_GROUP, 'MATCH,' + BASE]
  );
  // 按程序分流需要识别每个连接来自哪个程序
  config['find-process-mode'] = 'always';

  // 5、防泄露
  // IPv6 要开着：开着 TUN 才会接管 IPv6，关掉反而让 IPv6 绕过 Clash 用真实地址直连（Clash Verge 设置里的 IPv6 开关也要开）
  config.ipv6 = true;
  // DNS 只给 IPv4 地址，查询按规则走基础节点；启动与解析节点用的 DNS 全部加密、写死 IP，不发任何明文 DNS
  config.dns = config.dns || {};
  Object.assign(config.dns, {
    enable: true,
    ipv6: false,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'respect-rules': true,
    'prefer-h3': false,
    'use-system-hosts': false,
    'default-nameserver': ['tls://223.5.5.5:853', 'tls://1.12.12.12:853'],
    'proxy-server-nameserver': ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query'],
    nameserver: ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'],
    'nameserver-policy': { '+.ts.net': '100.100.100.100' }
  });
  const filter = new Set(config.dns['fake-ip-filter'] || []);
  ['+.ts.net', '+.local', '+.lan', 'localhost'].forEach((x) => filter.add(x));
  config.dns['fake-ip-filter'] = Array.from(filter);

  // 6、Tailscale：组网内部不进 TUN
  config.tun = config.tun || {};
  const exclude = new Set(config.tun['route-exclude-address'] || []);
  ['100.64.0.0/10', 'fd7a:115c:a1e0::/48'].forEach((x) => exclude.add(x));
  config.tun['route-exclude-address'] = Array.from(exclude);
  // 嗅探：浏览器自带加密 DNS 时连接只有 IP，从 TLS / HTTP 里认出域名，谷歌、Claude 才能按域名走住宅出口
  // 认出的域名只用来匹配规则，仍连接程序原本选的 IP：微信等应用的连接绑定在具体服务器上，改连域名解析出的其他服务器会导致消息、图片、文件发不出去
  config.sniffer = config.sniffer || {};
  Object.assign(config.sniffer, {
    enable: true,
    'force-dns-mapping': true,
    'parse-pure-ip': true,
    'override-destination': false,
    sniff: { HTTP: { ports: [80, '8080-8880'] }, TLS: { ports: [443, 8443] }, QUIC: { ports: [443, 8443] } }
  });
  const skip = new Set(config.sniffer['skip-domain'] || []);
  skip.add('+.ts.net');
  config.sniffer['skip-domain'] = Array.from(skip);
  return config;
}
