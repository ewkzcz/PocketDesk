// PocketDesk 分流脚本（放在 Clash Verge 的「全局扩展脚本」里）
//
// 效果：
//   · Claude 桌面端、Claude Code、Codex 桌面端、Codex CLI 发出的全部请求 → 住宅出口
//   · 谷歌相关请求，以及 Claude / ChatGPT 网页 → 住宅出口
//   · 其他所有请求 → 第1跳
//   · 住宅出口 = 先连第1跳，再从住宅代理出去，网站看到的是住宅 IP
//   · 不经过代理的只有：本机、局域网、Tailscale 组网内部、连接第1跳节点本身（这些本来就不上公网或无法代理）
//
// 用法：
//   1、只改下面「填写区」，其余不要动
//   2、Clash Verge → 订阅页 →「全局扩展脚本」→ 整份粘贴 → 保存
//   3、订阅自己的「扩展脚本」保持为空，里面如果也改规则，会覆盖这里的设置（订阅脚本比全局脚本后执行）
//   4、在「第1跳」组里选前置节点，在「住宅出口」组里选住宅代理
// 换订阅、换节点不用改脚本；换住宅代理只改填写区。

function main(config) {
  // ==================== 填写区 ====================
  // 住宅代理：可填多个，在「住宅出口」组里切换；type 填 socks5 或 http
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

  const FIRST_HOP = '第1跳';
  const AUTO = '♻️ 第1跳自动';
  const RES_GROUP = '住宅出口';

  // 走住宅出口的程序，按程序所在路径匹配（macOS、Windows 通用，不区分大小写）
  const RESIDENTIAL_APPS = [
    '(?i)/claude\\.app/',          // Claude 桌面端，以及它自带的 Claude Code
    '(?i)/claude/versions/',       // Claude Code CLI（官方安装方式）
    '(?i)/codex\\.app/',           // Codex 桌面端
    '(?i)/codex$',                 // Codex CLI
    '(?i)\\\\(claude|codex)\\.exe$' // Windows 上的 Claude、Claude Code、Codex
  ];

  // 1、住宅代理：没填完整的跳过；全部经第1跳连出
  const filled = (p) => p && p.server && p.port && String(p.server).indexOf('填写') < 0;
  const residential = RESIDENTIAL.filter(filled).map((p) => Object.assign({}, p, {
    udp: true, 'dialer-proxy': FIRST_HOP, 'ip-version': 'ipv4'
  }));
  const resNames = residential.map((p) => p.name);

  // 2、第1跳候选：订阅里的节点，去掉流量、到期提示这类假节点
  const INFO = /剩余|到期|套餐|流量|官网|重置|expire|traffic|reset/i;
  config.proxies = (config.proxies || []).filter((p) => resNames.indexOf(p.name) < 0);
  const nodes = config.proxies.map((p) => p.name).filter((n) => !INFO.test(n));
  config.proxies = config.proxies.concat(residential);

  // 3、分组：没有可用节点或没填住宅代理时拒绝连接，宁可断网也不从别的出口出去
  const mine = [FIRST_HOP, AUTO, RES_GROUP];
  const groups = (config['proxy-groups'] || []).filter((g) => mine.indexOf(g.name) < 0);
  config['proxy-groups'] = [
    { name: FIRST_HOP, type: 'select', proxies: nodes.length ? [AUTO].concat(nodes) : ['REJECT'] },
    { name: RES_GROUP, type: 'select', proxies: resNames.length ? resNames : ['REJECT'] },
    { name: AUTO, type: 'url-test', proxies: nodes.length ? nodes : ['REJECT'], url: 'https://www.gstatic.com/generate_204', interval: 300, tolerance: 50 }
  ].concat(groups);

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
    RESIDENTIAL_DOMAINS.map((d) => 'DOMAIN-SUFFIX,' + d + ',' + RES_GROUP),
    ['GEOSITE,google,' + RES_GROUP, 'MATCH,' + FIRST_HOP]
  );
  // 按程序分流需要识别每个连接来自哪个程序
  config['find-process-mode'] = 'always';

  // 5、防泄露：关闭 IPv6，DNS 查询也按规则走代理
  config.ipv6 = false;
  config.dns = config.dns || {};
  Object.assign(config.dns, {
    enable: true,
    ipv6: false,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'respect-rules': true,
    'default-nameserver': ['223.5.5.5', '119.29.29.29'],
    'proxy-server-nameserver': ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query'],
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
  config.sniffer = config.sniffer || {};
  const skip = new Set(config.sniffer['skip-domain'] || []);
  skip.add('+.ts.net');
  config.sniffer['skip-domain'] = Array.from(skip);
  return config;
}
