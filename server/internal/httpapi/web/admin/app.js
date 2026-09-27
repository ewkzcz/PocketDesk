/**
 * 桌面端管理页：#pair 配对新手机、#settings/分区 主界面（含文件传输助手与手机文件）；定时刷新状态并弹出配对确认。
 */
(function () {
  'use strict';

  var state = null;
  var pairInfo = null;
  var pairTimer = null;
  var shownRequests = {};
  var lastView = '';
  var app = document.getElementById('app');
  var modalRoot = document.getElementById('modal-root');
  var SECTIONS = [
    ['overview', '概览', 'layout-grid'],
    ['assistant', '传输助手', 'send'],
    ['phone', '手机文件', 'hard-drive'],
    ['workspaces', '工作区', 'folder'],
    ['devices', '设备', 'smartphone'],
    ['transfer', '传输', 'arrow-up-down'],
    ['security', '安全', 'shield'],
    ['about', '关于', 'info']
  ];

  /** esc：转义 HTML */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /** api：调用管理接口，失败时抛出带提示文字的错误 */
  function api(method, path, body) {
    return fetch(path, {
      method: method,
      headers: body ? { 'Content-Type': 'application/json' } : {},
      body: body ? JSON.stringify(body) : undefined,
      credentials: 'same-origin'
    }).then(function (res) {
      return res.text().then(function (t) {
        var data = null;
        try { data = t ? JSON.parse(t) : null; } catch (e) { data = null; }
        if (!res.ok) { throw new Error((data && data.message) || '操作失败'); }
        return data;
      });
    });
  }

  /** toast：底部短提示 */
  var toastTimer = null;
  function toast(msg) {
    var el = document.getElementById('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2200);
  }

  /** ago：相对时间 */
  function ago(ms) {
    if (!ms) { return '从未在线'; }
    var d = (Date.now() - ms) / 1000;
    if (d < 60) { return '刚刚在线'; }
    if (d < 3600) { return Math.floor(d / 60) + ' 分钟前在线'; }
    if (d < 86400) { return Math.floor(d / 3600) + ' 小时前在线'; }
    return Math.floor(d / 86400) + ' 天前在线';
  }

  /** route：解析地址中的页面 */
  function route() {
    var h = location.hash.replace(/^#/, '');
    if (h === 'pair') { return { page: 'pair' }; }
    var m = /^settings\/(\w+)/.exec(h);
    return { page: 'settings', section: m ? m[1] : 'overview' };
  }

  /** load：拉取状态并刷新页面 */
  function load() {
    return api('GET', '/admin/api/state').then(function (s) {
      state = s;
      render();
      checkRequests();
    }).catch(function (e) { toast(e.message); });
  }

  /** render：按路由绘制 */
  function render() {
    if (!state) { return; }
    var r = route();
    document.title = r.page === 'pair' ? '配对新手机 · PocketDesk' : 'PocketDesk';
    if (r.page === 'pair') { app.innerHTML = pairView(); lastView = 'pair'; return; }
    // 定时刷新同一页面时保留滚动位置、不重放进入动画
    var main = app.querySelector('.pd-main');
    var top = main && lastView === r.section ? main.scrollTop : 0;
    app.innerHTML = settingsView(r.section);
    if (lastView === r.section) { app.querySelector('.pd-view').style.animation = 'none'; }
    app.querySelector('.pd-main').scrollTop = top;
    lastView = r.section;
    if (r.section === 'assistant') { chatRender(true); }
  }

  /** enter：进入分区时加载数据 */
  function enter(r) {
    if (r.section === 'security') { setTimeout(loadAudit, 0); }
    if (r.section === 'assistant') { chatLoad(); }
    if (r.section === 'phone') { phoneLoad(); }
  }

  /* ---------- 配对 ---------- */
  function pairView() {
    if (!pairInfo) {
      return '<div class="pd-pair"><div class="pd-pair-body"><div class="pd-pair-title">配对新手机</div><div class="pd-muted">正在生成配对码…</div></div></div>';
    }
    var addr = (pairInfo.addresses || [])[0] || '未检测到局域网地址';
    return '<div class="pd-pair"><div class="pd-pair-body">' +
      '<div class="pd-pair-title">配对新手机</div>' +
      '<div class="pd-qr"><img alt="配对二维码" src="' + esc(pairInfo.qr) + '"></div>' +
      '<div class="pd-muted" id="pair-left">' + countdownText() + '</div>' +
      '<div class="pd-card pd-steps">' +
      step(1, '在手机上打开 PocketDesk，进入「消息 → +」，点「扫一扫」') +
      step(2, '对准上方二维码扫描，或手动输入下方配对码') +
      step(3, '在电脑上点击「允许」完成配对') + '</div>' +
      '<div class="pd-card pd-codebox"><div><div class="pd-muted" style="font-size:11px">手动配对码</div><div class="pd-code">' + esc(pairInfo.code) + '</div></div>' +
      '<div class="pd-muted" style="font-size:11px;text-align:right">' + esc(pairInfo.hostName) + '<br><span class="pd-mono">' + esc(addr) + '</span></div></div>' +
      '<div class="pd-pair-foot"><button class="pd-btn" data-act="pair-refresh">换一个配对码</button><button class="pd-btn" data-act="pair-close">取消</button></div>' +
      '</div></div>';
  }
  function step(n, text) {
    return '<div class="pd-step"><div class="pd-stepnum">' + n + '</div><div>' + text + '</div></div>';
  }
  function countdownText() {
    if (!pairInfo) { return ''; }
    var left = Math.max(0, Math.floor((pairInfo.expiresAt - Date.now()) / 1000));
    if (left === 0) { return '配对码已过期，请点「换一个配对码」'; }
    var mm = String(Math.floor(left / 60)).padStart(2, '0');
    var ss = String(left % 60).padStart(2, '0');
    return '配对码 5 分钟内有效，剩余 <span class="pd-countdown">' + mm + ':' + ss + '</span>';
  }
  function startPair() {
    pairInfo = null;
    render();
    api('POST', '/admin/api/pair/start').then(function (p) {
      pairInfo = p;
      render();
      clearInterval(pairTimer);
      pairTimer = setInterval(function () {
        var el = document.getElementById('pair-left');
        if (el) { el.innerHTML = countdownText(); }
      }, 1000);
    }).catch(function (e) { toast(e.message); });
  }

  /* ---------- 主界面 ---------- */
  function settingsView(section) {
    var nav = SECTIONS.map(function (s) {
      return '<button class="pd-nav' + (s[0] === section ? ' active' : '') + '" data-go="settings/' + s[0] + '"' + (s[0] === section ? ' aria-current="page"' : '') + '>' + icon(s[2], 22) + '<span>' + s[1] + '</span></button>';
    }).join('');
    var view = ({ overview: overviewView, assistant: assistantView, phone: phoneView, workspaces: workspacesView, devices: devicesView, transfer: transferView, security: securityView, about: aboutView }[section] || overviewView)();
    var fill = section === 'assistant';
    return '<div class="pd-shell"><nav class="pd-rail"><div class="pd-logo">' + icon('monitor', 22) + '</div>' + nav +
      '<div class="pd-rail-gap"></div><button class="pd-rail-btn" data-go="pair" title="配对新手机" aria-label="配对新手机">' + icon('qr-code', 20) + '</button></nav>' +
      '<main class="pd-main' + (fill ? ' pd-main-fill' : '') + '">' + view[0] + '<div class="pd-view' + (fill ? ' pd-view-fill' : '') + '">' + view[1] + '</div></main></div>';
  }
  function head(title, sub, action) {
    return '<header class="pd-head"><div><div class="pd-h1">' + title + '</div>' + (sub ? '<div class="pd-sub">' + sub + '</div>' : '') + '</div>' + (action || '') + '</header>';
  }
  function tile(name, color) {
    return '<div class="pd-tile pd-tile-c" style="background:' + color + '">' + icon(name, 17) + '</div>';
  }

  function overviewView() {
    var addrs = (state.addresses || []).map(function (a) {
      return '<div class="pd-addr"><span class="pd-mono">' + esc(a.ip) + '</span><span class="pd-tag ' + (a.kind === 'tailscale' ? 'pd-tag-blue' : 'pd-tag-ok') + '">' + (a.kind === 'tailscale' ? 'Tailscale' : '局域网') + '</span></div>';
    }).join('') || '<span class="pd-muted">未检测到局域网或 Tailscale 地址</span>';
    var agents = (state.agents || []).map(function (a) {
      return '<div class="pd-card pd-agent' + (a.installed ? '' : ' off') + '"><img class="pd-avatar" src="/admin/avatars/' + esc(a.kind) + '.svg" alt="">' +
        '<div style="min-width:0"><div class="pd-agent-name">' + esc(a.label) + '</div><div class="pd-muted" style="font-size:12px">' + (a.installed ? esc(a.version || '已安装') : '未安装') + '</div></div></div>';
    }).join('');
    var online = state.devices.filter(function (d) { return d.online; }).length;
    var paired = state.devices.filter(function (d) { return !d.revoked; }).length;
    return [head('概览', '电脑端服务的运行状态', '<button class="pd-btn pd-btn-primary" data-go="pair">' + icon('qr-code', 16) + '配对新手机</button>'),
      '<div class="pd-hero"><div class="pd-hero-icon">' + icon('monitor', 28) + '</div>' +
      '<div class="pd-hero-main"><div class="pd-hero-name">' + esc(state.host.name) + '</div>' +
      '<div class="pd-hero-state"><span class="pd-dot"></span>运行中 · 端口 ' + state.host.port + '</div></div>' +
      '<div class="pd-stats"><div class="pd-stat"><b>' + online + '</b><span>在线手机</span></div>' +
      '<div class="pd-stat"><b>' + paired + '</b><span>已配对</span></div>' +
      '<div class="pd-stat"><b>' + state.workspaces.length + '</b><span>工作区</span></div></div></div>' +
      '<div class="pd-h2">连接</div><div class="pd-card"><dl class="pd-kv">' +
      '<dt>访问地址</dt><dd>' + addrs + '</dd>' +
      '<dt>证书指纹</dt><dd class="pd-mono" style="font-size:12px">' + esc(fmtFp(state.host.fingerprint)) + '</dd>' +
      '</dl></div>' +
      '<div class="pd-h2">AI 编程工具</div><div class="pd-agents">' + agents + '</div>'];
  }
  function fmtFp(fp) { return (fp || '').toUpperCase().match(/.{1,4}/g).join(' '); }

  function workspacesView() {
    var rows = state.workspaces.map(function (w) {
      return '<tr><td><div class="pd-name">' + tile('folder', 'var(--pd-tile-blue)') + esc(w.name) + '</div></td><td class="pd-path">' + esc(w.rootPath) + '</td>' +
        '<td><span class="pd-tag' + (w.readOnly ? '' : ' pd-tag-ok') + '">' + (w.readOnly ? '只读' : '读写') + '</span></td>' +
        '<td><div class="pd-actions"><button class="pd-link" data-act="ws-edit" data-id="' + esc(w.id) + '">编辑</button>' +
        '<button class="pd-link pd-link-danger" data-act="ws-del" data-id="' + esc(w.id) + '">删除</button></div></td></tr>';
    }).join('');
    var warns = state.workspaces.filter(function (w) { return w.warning; }).map(function (w) {
      return '<div class="pd-warn">' + icon('alert-triangle', 16) + '<div>' + esc(w.warning) + '</div></div>';
    }).join('');
    return [head('工作区', '手机上可访问的电脑文件夹', '<button class="pd-btn pd-btn-primary" data-act="ws-add">' + icon('plus', 16) + '添加工作区</button>'),
      '<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th>路径</th><th class="pd-col-tag">权限</th><th style="width:110px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有工作区，添加后手机才能浏览电脑上的文件</div>') + '</div>' + warns];
  }

  function devicesView() {
    var rows = state.devices.map(function (d) {
      var status = d.revoked ? '<span class="pd-tag">已吊销</span>' : d.online ? '<span class="pd-tag pd-tag-ok">在线</span>' : '<span class="pd-muted">' + ago(d.lastSeen) + '</span>';
      var color = d.revoked ? 'var(--pd-graphite)' : 'var(--pd-tile-teal)';
      return '<tr><td><div class="pd-name">' + tile('smartphone', color) + esc(d.name) + '</div></td><td class="pd-hide-s pd-muted">' + esc(platformName(d.platform)) + '</td><td>' + status + '</td>' +
        '<td>' + (d.revoked ? '' : '<button class="pd-link pd-link-danger" data-act="dev-revoke" data-id="' + esc(d.id) + '" data-name="' + esc(d.name) + '">吊销</button>') + '</td></tr>';
    }).join('');
    return [head('已配对设备', '吊销后该手机需要重新扫码配对', '<button class="pd-btn pd-btn-primary" data-go="pair">' + icon('qr-code', 16) + '配对新手机</button>'),
      '<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th class="pd-hide-s">系统</th><th>状态</th><th style="width:80px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有配对的手机</div>') + '</div>'];
  }
  function platformName(p) { return { ios: 'iOS', android: 'Android', web: '浏览器' }[p] || p || '未知'; }

  function transferView() {
    var c = state.config;
    var n = c.notify || {};
    return [head('传输', '文件收发目录与后台通知'),
      '<div class="pd-h2">目录</div><div class="pd-card"><div class="pd-form-grid">' +
      '<div class="pd-form-row"><div class="pd-field"><label for="inbox">收件目录（手机发来的文件）</label><input class="pd-input pd-mono" id="inbox" value="' + esc(c.transfer.inboxDir) + '"></div><button class="pd-btn" data-act="open-inbox" aria-label="打开收件目录">' + icon('folder-open', 16) + '</button></div>' +
      '</div>' + setting('pause', 'var(--pd-tile-amber)', '暂停所有传输', '暂停期间手机会自动等待，恢复后继续', 'pause-all', state.transfersPaused) + '</div>' +
      '<div class="pd-h2">后台通知</div><div class="pd-card"><div class="pd-form-grid">' +
      '<div class="pd-field"><label for="nkind">推送方式</label><select class="pd-input" id="nkind"><option value="">不推送</option><option value="ntfy"' + (n.kind === 'ntfy' ? ' selected' : '') + '>ntfy</option><option value="bark"' + (n.kind === 'bark' ? ' selected' : '') + '>Bark</option></select></div>' +
      '<div class="pd-field"><label for="nurl">服务地址</label><input class="pd-input" id="nurl" placeholder="https://ntfy.sh" value="' + esc(n.url) + '"></div>' +
      '<div class="pd-field"><label for="ntopic">主题或设备密钥</label><input class="pd-input" id="ntopic" value="' + esc(n.topic) + '"></div>' +
      '</div></div>' +
      '<div class="pd-savebar"><button class="pd-btn pd-btn-primary" data-act="save-transfer">保存</button></div>'];
  }

  function securityView() {
    var f = state.config.features;
    return [head('安全', '单独开关各项功能，终端可以访问整台电脑，默认关闭'),
      '<div class="pd-card">' +
      setting('bot', 'var(--pd-tile-indigo)', 'Agent 会话', '手机向电脑上的 AI 编程工具发送提示词', 'f-agents', f.agents) +
      setting('terminal', 'var(--pd-tile-ink)', '终端', '手机可在电脑上执行任意命令，每次进入需验证指纹或面容', 'f-terminal', f.terminal) +
      setting('pencil', 'var(--pd-tile-amber)', '文件编辑', '手机可保存、重命名、移动和删除工作区文件', 'f-fileEdit', f.fileEdit) +
      '<div class="pd-setting">' + tile('clock', 'var(--pd-tile-blue)') + '<div class="pd-setting-text"><div class="pd-setting-name">终端空闲自动结束</div><div class="pd-setting-desc">没有输入也没有连接超过设定小时数后结束</div></div>' +
      '<input class="pd-input" id="idle" type="number" min="1" max="720" style="width:90px" value="' + state.config.terminalIdleHours + '" aria-label="小时"></div>' +
      '</div>' +
      '<div class="pd-h2">操作记录</div><div class="pd-card" id="audit"><div class="pd-empty">正在加载…</div></div>'];
  }
  function setting(ic, color, name, desc, id, on) {
    return '<div class="pd-setting">' + tile(ic, color) + '<div class="pd-setting-text"><div class="pd-setting-name">' + name + '</div><div class="pd-setting-desc">' + desc + '</div></div>' + toggle(id, on) + '</div>';
  }
  function toggle(id, on) {
    return '<label class="pd-switch"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '><span></span></label>';
  }

  function aboutView() {
    return [head('关于', ''),
      '<div class="pd-card"><dl class="pd-kv">' +
      '<dt>版本</dt><dd>' + esc(state.host.version) + '</dd>' +
      '<dt>数据目录</dt><dd class="pd-mono" style="font-size:12px">' + esc(state.dataDir) + '</dd>' +
      '</dl></div><div class="pd-savebar" style="justify-content:flex-start"><button class="pd-btn pd-btn-danger" data-act="quit">' + icon('log-out', 16) + '退出服务</button></div>'];
  }

  /* ---------- 文件传输助手 ---------- */
  var chat = { items: [], last: 0, loaded: false };

  function assistantView() {
    return [head('文件传输助手', '和手机互传文字、图片与文件；拖进来或直接粘贴图片即可发送'),
      '<div class="pd-card pd-chat"><div class="pd-chat-list" id="chat-list">' + chatListHtml() + '</div>' +
      '<div class="pd-composer"><button class="pd-icon-btn" data-act="chat-attach" aria-label="发送文件" title="发送文件">' + icon('paperclip', 18) + '</button>' +
      '<textarea id="chat-input" class="pd-input" rows="1" placeholder="输入消息，Enter 发送，Shift + Enter 换行"></textarea>' +
      '<button class="pd-btn pd-btn-primary" data-act="chat-send">' + icon('send', 16) + '发送</button></div>' +
      '<input type="file" id="chat-file" multiple hidden></div>'];
  }

  /** chatLoad：首次取最近记录，之后只取新增 */
  function chatLoad() {
    return api('GET', '/admin/api/assistant/events' + (chat.loaded ? '?after=' + chat.last : '')).then(function (list) {
      var added = false;
      (list || []).sort(function (a, b) { return a.seq - b.seq; }).forEach(function (e) {
        if (e.seq > chat.last) { chat.items.push(e); chat.last = e.seq; added = true; }
      });
      var first = !chat.loaded;
      chat.loaded = true;
      if (added || first) { chatRender(first); }
    }).catch(function () {});
  }

  /** chatRender：重绘消息列表；原本在底部或首次加载时滚到底部 */
  function chatRender(first) {
    var el = document.getElementById('chat-list');
    if (!el) { return; }
    var bottom = first || el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    el.innerHTML = chatListHtml();
    if (bottom) { el.scrollTop = el.scrollHeight; }
    Array.prototype.forEach.call(el.querySelectorAll('img'), function (img) {
      img.addEventListener('load', function () { if (bottom) { el.scrollTop = el.scrollHeight; } }, { once: true });
    });
  }

  function isImage(name) { return /\.(png|jpe?g|gif|webp|bmp|heic|svg)$/i.test(name || ''); }
  function fmtSize(n) {
    if (!n && n !== 0) { return ''; }
    if (n < 1024) { return n + ' B'; }
    if (n < 1048576) { return (n / 1024).toFixed(0) + ' KB'; }
    if (n < 1073741824) { return (n / 1048576).toFixed(1) + ' MB'; }
    return (n / 1073741824).toFixed(2) + ' GB';
  }
  function fmtChatTime(ms) {
    var d = new Date(ms), now = new Date();
    var p = function (x) { return String(x).padStart(2, '0'); };
    var hm = p(d.getHours()) + ':' + p(d.getMinutes());
    return d.toDateString() === now.toDateString() ? hm : (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
  }

  function chatListHtml() {
    if (!chat.loaded) { return '<div class="pd-empty">正在加载…</div>'; }
    var out = '', lastAt = 0;
    chat.items.forEach(function (e) {
      var d = e.data || {}, mine, body;
      if (e.type === 'msg.user') {
        mine = false;
        body = '<div class="pd-bubble">' + esc(d.text) + '</div>';
      } else if (e.type === 'msg.host') {
        mine = true;
        body = '<div class="pd-bubble mine">' + esc(d.text) + '</div>';
      } else if (e.type === 'file') {
        mine = d.direction === 'down';
        var src = '/admin/api/assistant/file?seq=' + e.seq;
        body = isImage(d.name)
          ? '<button class="pd-chat-img" data-act="chat-preview" data-seq="' + e.seq + '" data-name="' + esc(d.name) + '"><img alt="' + esc(d.name) + '" src="' + src + '" loading="lazy"></button>'
          : '<div class="pd-filecard"><div class="pd-tile pd-tile-c" style="background:var(--pd-tile-blue)">' + icon('file', 18) + '</div>' +
            '<div class="pd-filecard-main"><div class="pd-filecard-name">' + esc(d.name) + '</div><div class="pd-muted">' + fmtSize(d.size) + '</div></div>' +
            '<div class="pd-filecard-acts"><button class="pd-link" data-act="chat-open" data-seq="' + e.seq + '">打开</button>' +
            '<button class="pd-link" data-act="chat-reveal" data-seq="' + e.seq + '">在文件夹中显示</button></div></div>';
      } else {
        return;
      }
      if (e.createdAt - lastAt > 5 * 60 * 1000) { out += '<div class="pd-chat-time">' + fmtChatTime(e.createdAt) + '</div>'; }
      lastAt = e.createdAt;
      var who = mine ? '<div class="pd-chat-avatar" style="background:var(--pd-tile-blue)">' + icon('monitor', 18) + '</div>'
        : '<div class="pd-chat-avatar" style="background:var(--pd-tile-teal)">' + icon('smartphone', 18) + '</div>';
      out += '<div class="pd-chat-row' + (mine ? ' mine' : '') + '">' + who + '<div class="pd-chat-body">' + body + '</div></div>';
    });
    return out || '<div class="pd-empty">发一条消息或拖入文件，手机上的文件传输助手马上就能收到</div>';
  }

  function chatSendText() {
    var el = document.getElementById('chat-input');
    var text = el.value;
    if (!text.trim()) { return; }
    el.value = '';
    chatGrow(el);
    api('POST', '/admin/api/assistant/text', { text: text }).then(chatLoad).catch(function (er) { el.value = text; toast(er.message); });
  }

  /** chatGrow：输入框随内容增高，最多 6 行 */
  function chatGrow(el) {
    el.style.height = 'auto';
    el.style.height = Math.min(el.scrollHeight, 150) + 'px';
  }

  /** uploadForm：以表单上传文件 */
  function uploadForm(url, files) {
    var fd = new FormData();
    files.forEach(function (f) { fd.append('file', f, f.name); });
    return fetch(url, { method: 'POST', body: fd, credentials: 'same-origin' }).then(function (res) {
      return res.json().catch(function () { return null; }).then(function (data) {
        if (!res.ok) { throw new Error((data && data.message) || '上传失败'); }
        return data;
      });
    });
  }

  function chatSendFiles(files) {
    if (!files.length) { return; }
    toast('正在发送 ' + files.length + ' 个文件…');
    uploadForm('/admin/api/assistant/files', files).then(function () { toast('已发送'); chatLoad(); }).catch(function (er) { toast(er.message); });
  }

  /** pastedFiles：剪贴板里的文件；截图等没有名字的图片按时间命名 */
  function pastedFiles(e) {
    var out = [];
    var items = (e.clipboardData && e.clipboardData.items) || [];
    Array.prototype.forEach.call(items, function (it) {
      if (it.kind !== 'file') { return; }
      var f = it.getAsFile();
      if (!f) { return; }
      if (!f.name || /^image\.\w+$/.test(f.name)) {
        var d = new Date(), p = function (x) { return String(x).padStart(2, '0'); };
        var ext = (f.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
        f = new File([f], '粘贴图片-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds()) + '.' + ext, { type: f.type });
      }
      out.push(f);
    });
    return out;
  }

  function imagePreview(title, src, actions) {
    modalRoot.innerHTML = '<div class="pd-scrim" data-act="modal-close"><div class="pd-preview" role="dialog" aria-modal="true" aria-label="' + esc(title) + '">' +
      '<img alt="' + esc(title) + '" src="' + src + '"><div class="pd-preview-bar"><span>' + esc(title) + '</span><div class="pd-actions">' + actions +
      '<button class="pd-icon-btn" data-act="modal-close" aria-label="关闭">' + icon('x', 18) + '</button></div></div></div></div>';
  }

  /* ---------- 手机文件 ---------- */
  var ph = { phones: null, dev: '', path: '', entries: [], root: '', error: '', loading: false };
  var TEXT_EXT = /\.(txt|md|markdown|json|js|ts|jsx|tsx|go|py|dart|java|kt|swift|c|h|cpp|rs|rb|php|sh|yaml|yml|toml|ini|conf|cfg|csv|log|xml|html|css|scss|sql|env)$/i;

  function phoneView() {
    var list = ph.phones || [];
    var sel = list.length > 1 ? '<select class="pd-input" id="phone-sel" aria-label="选择手机">' + list.map(function (p) {
      return '<option value="' + esc(p.id) + '"' + (p.id === ph.dev ? ' selected' : '') + '>' + esc(p.name) + (p.online ? '' : '（不在线）') + '</option>';
    }).join('') + '</select>' : '';
    var ready = ph.dev && !ph.error;
    var acts = '<div class="pd-actions">' + sel +
      (ready ? '<button class="pd-btn" data-act="phone-root">' + icon('folder-search', 16) + '更换目录</button>' +
        '<button class="pd-btn" data-act="phone-mkdir">' + icon('folder-plus', 16) + '新建文件夹</button>' +
        '<button class="pd-btn pd-btn-primary" data-act="phone-upload">' + icon('upload', 16) + '上传</button>' : '') +
      '<button class="pd-icon-btn" data-act="phone-refresh" aria-label="刷新" title="刷新">' + icon('refresh-cw', 16) + '</button></div>';
    return [head('手机文件', ph.root ? '<span class="pd-mono">' + esc(ph.root) + '</span>' : '管理手机上的工作空间：上传、删除、新建文件夹、编辑文件', acts),
      '<input type="file" id="phone-file" multiple hidden>' + phoneBodyHtml()];
  }

  function phoneBodyHtml() {
    if (!ph.phones) { return '<div class="pd-card"><div class="pd-empty">正在连接手机…</div></div>'; }
    if (!ph.phones.length) { return '<div class="pd-card"><div class="pd-empty">还没有配对的手机</div></div>'; }
    if (ph.error) { return '<div class="pd-warn">' + icon('alert-triangle', 16) + '<div>' + esc(ph.error) + '</div></div>'; }
    var parts = ph.path ? ph.path.split('/') : [];
    var crumbs = '<button class="pd-link" data-act="phone-cd" data-path="">工作空间</button>' + parts.map(function (p, i) {
      return '<span class="pd-crumb-sep">/</span><button class="pd-link" data-act="phone-cd" data-path="' + esc(parts.slice(0, i + 1).join('/')) + '">' + esc(p) + '</button>';
    }).join('');
    var rows = ph.entries.map(function (e) {
      var p = (ph.path ? ph.path + '/' : '') + e.name;
      var tile = e.isDir ? tileHtml('folder', 'var(--pd-tile-blue)') : isImage(e.name) ? tileHtml('image', 'var(--pd-tile-teal)') : tileHtml('file', 'var(--pd-tile-indigo)');
      return '<tr><td><button class="pd-name pd-name-btn" data-act="phone-open" data-path="' + esc(p) + '" data-dir="' + (e.isDir ? 1 : 0) + '">' + tile + '<span>' + esc(e.name) + '</span></button></td>' +
        '<td class="pd-muted pd-nowrap pd-hide-s">' + (e.isDir ? '' : fmtSize(e.size)) + '</td><td class="pd-muted pd-nowrap pd-hide-s">' + (e.modTime ? fmtTime(e.modTime).slice(0, 16) : '') + '</td>' +
        '<td><div class="pd-actions">' + (e.isDir ? '' : '<button class="pd-link" data-act="phone-fetch" data-path="' + esc(p) + '">存到电脑</button>') +
        '<button class="pd-link" data-act="phone-rename" data-path="' + esc(p) + '" data-name="' + esc(e.name) + '">重命名</button>' +
        '<button class="pd-link pd-link-danger" data-act="phone-delete" data-path="' + esc(p) + '" data-name="' + esc(e.name) + '">删除</button></div></td></tr>';
    }).join('');
    return '<div class="pd-crumbs">' + crumbs + (ph.loading ? '<span class="pd-muted" style="margin-left:8px">加载中…</span>' : '') + '</div>' +
      '<div class="pd-card pd-drop">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th class="pd-hide-s" style="width:90px">大小</th><th class="pd-hide-s" style="width:140px">修改时间</th><th style="width:200px">操作</th></tr>' + rows + '</table>'
        : '<div class="pd-empty">这个文件夹是空的，把文件拖进来即可上传到手机</div>') + '</div>';
  }
  function tileHtml(name, color) { return '<span class="pd-tile pd-tile-c" style="background:' + color + '">' + icon(name, 16) + '</span>'; }

  /** phoneCall：转给手机的操作 */
  function phoneCall(op, args) { return api('POST', '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/call', { op: op, args: args || {} }); }
  function phoneFileUrl(p) { return '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/file?path=' + encodeURIComponent(p); }

  /** phoneLoad：刷新手机列表并读取当前目录 */
  function phoneLoad() {
    ph.loading = true;
    phoneRedraw();
    return api('GET', '/admin/api/phones').then(function (list) {
      ph.phones = list || [];
      if (!ph.phones.some(function (p) { return p.id === ph.dev; })) {
        var on = ph.phones.filter(function (p) { return p.online; })[0] || ph.phones[0];
        ph.dev = on ? on.id : '';
        ph.path = '';
      }
      if (!ph.dev) { return; }
      var cur = ph.phones.filter(function (p) { return p.id === ph.dev; })[0];
      if (!cur.online) { ph.error = '手机不在线，请在手机上打开 PocketDesk'; return; }
      return phoneCall('list', { path: ph.path }).then(function (r) {
        ph.entries = r.entries || [];
        ph.root = r.root || '';
        ph.error = '';
      });
    }).catch(function (er) { ph.error = er.message; }).then(function () { ph.loading = false; phoneRedraw(); });
  }
  function phoneRedraw() { if (route().section === 'phone') { render(); } }

  function phoneUpload(files) {
    if (!files.length || !ph.dev) { return; }
    toast('正在上传 ' + files.length + ' 个文件到手机…');
    uploadForm('/admin/api/phone/' + encodeURIComponent(ph.dev) + '/upload?dir=' + encodeURIComponent(ph.path), files)
      .then(function () { toast('已上传到手机'); phoneLoad(); }).catch(function (er) { toast(er.message); });
  }

  function phoneParent(p) { var i = p.lastIndexOf('/'); return i < 0 ? '' : p.slice(0, i); }

  /** phoneOpen：图片预览，文本在窗口里编辑，其他格式存到电脑后用默认程序打开 */
  function phoneOpen(p) {
    var name = p.split('/').pop();
    if (isImage(name)) {
      imagePreview(name, phoneFileUrl(p), '<button class="pd-btn" data-act="phone-fetch" data-path="' + esc(p) + '">' + icon('download', 16) + '存到电脑</button>');
      return;
    }
    if (!TEXT_EXT.test(name)) {
      toast('正在从手机取文件…');
      api('POST', '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/fetch', { path: p, open: true }).catch(function (er) { toast(er.message); });
      return;
    }
    fetch(phoneFileUrl(p), { credentials: 'same-origin' }).then(function (res) {
      if (!res.ok) { return res.json().then(function (d) { throw new Error((d && d.message) || '读取失败'); }); }
      return res.text();
    }).then(function (text) {
      modalRoot.innerHTML = '<div class="pd-scrim"><div class="pd-dialog pd-editor" role="dialog" aria-modal="true" aria-label="' + esc(name) + '">' +
        '<div class="pd-dialog-head"><div class="pd-dialog-title">' + esc(name) + '</div><button class="pd-icon-btn" data-act="modal-close" aria-label="关闭">' + icon('x', 18) + '</button></div>' +
        '<textarea id="edit-text" class="pd-input pd-mono" spellcheck="false"></textarea>' +
        '<div class="pd-dialog-foot"><button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="phone-save" data-path="' + esc(p) + '">' + icon('save', 16) + '保存到手机</button></div></div></div>';
      var ta = document.getElementById('edit-text');
      ta.value = text;
      ta.focus();
    }).catch(function (er) { toast(er.message); });
  }

  /** phoneRootPicker：浏览手机存储选择工作空间目录 */
  function phoneRootPicker(p) {
    phoneCall('browse', { path: p || '' }).then(function (r) {
      var dirs = (r.dirs || []).map(function (d) {
        return '<button class="pd-pick-row" data-act="phone-browse" data-path="' + esc(r.path + '/' + d) + '">' + icon('folder', 16) + '<span>' + esc(d) + '</span></button>';
      }).join('') || '<div class="pd-empty">没有子文件夹</div>';
      modal('选择手机工作空间',
        '<div class="pd-mono pd-muted" style="font-size:12px;word-break:break-all">' + esc(r.path) + '</div>' +
        (r.parent ? '<button class="pd-pick-row" data-act="phone-browse" data-path="' + esc(r.parent) + '">' + icon('chevron-left', 16) + '<span>上一级</span></button>' : '') +
        '<div class="pd-pick-list">' + dirs + '</div>',
        '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="phone-setroot" data-path="' + esc(r.path) + '">使用这个文件夹</button>');
    }).catch(function (er) { toast(er.message); });
  }

  /** fmtTime：固定为中文 24 小时制，不随浏览器语言变化 */
  function fmtTime(ms) {
    var d = new Date(ms);
    var p = function (n) { return String(n).padStart(2, '0'); };
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  /** loadAudit：安全页的操作记录 */
  function loadAudit() {
    var el = document.getElementById('audit');
    if (!el) { return; }
    api('GET', '/admin/api/audit').then(function (list) {
      var names = {};
      state.devices.forEach(function (d) { names[d.id] = d.name; });
      if (!list.length) { el.innerHTML = '<div class="pd-empty">暂无记录</div>'; return; }
      el.innerHTML = '<table class="pd-table pd-audit"><tr><th>时间</th><th>设备</th><th>操作</th><th class="pd-hide-s">详情</th></tr>' + list.slice(0, 100).map(function (a) {
        var detail = JSON.stringify(a.detail) || '';
        if (detail.length > 160) { detail = detail.slice(0, 160) + '…'; }
        return '<tr><td class="pd-nowrap">' + fmtTime(a.createdAt) + '</td><td class="pd-nowrap">' + esc(names[a.deviceId] || '电脑') + '</td><td class="pd-nowrap">' + esc(a.action) + '</td>' +
          '<td class="pd-hide-s pd-path">' + esc(detail) + '</td></tr>';
      }).join('') + '</table>';
    });
  }

  /* ---------- 弹窗 ---------- */
  function modal(title, body, foot) {
    modalRoot.innerHTML = '<div class="pd-scrim"><div class="pd-dialog" role="dialog" aria-modal="true" aria-label="' + esc(title) + '">' +
      '<div class="pd-dialog-head"><div class="pd-dialog-title">' + esc(title) + '</div><button class="pd-icon-btn" data-act="modal-close" aria-label="关闭">' + icon('x', 18) + '</button></div>' +
      '<div class="pd-modal-body">' + body + '</div><div class="pd-dialog-foot">' + foot + '</div></div></div>';
    var first = modalRoot.querySelector('input,button.pd-btn-primary');
    if (first) { first.focus(); }
  }
  function closeModal() { modalRoot.innerHTML = ''; }

  function workspaceForm(w) {
    w = w || { id: '', name: '', rootPath: '', readOnly: false };
    modal(w.id ? '编辑工作区' : '添加工作区',
      '<div class="pd-field"><label for="wname">名称</label><input class="pd-input" id="wname" value="' + esc(w.name) + '" placeholder="例如 payments"></div>' +
      '<div class="pd-field"><label for="wpath">文件夹路径</label><input class="pd-input pd-mono" id="wpath" value="' + esc(w.rootPath) + '" placeholder="~/Workspace/payments"></div>' +
      '<label class="pd-check"><input type="checkbox" id="wro"' + (w.readOnly ? ' checked' : '') + '>只读（手机上不能修改）</label>',
      '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="ws-save" data-id="' + esc(w.id) + '">保存</button>');
  }

  function confirmBox(title, text, okLabel, onOk) {
    modal(title, '<div>' + text + '</div>', '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-danger" id="confirm-ok">' + okLabel + '</button>');
    document.getElementById('confirm-ok').onclick = function () { closeModal(); onOk(); };
  }

  /** checkRequests：有手机请求配对时弹窗确认 */
  function checkRequests() {
    (state.pending || []).forEach(function (req) {
      if (shownRequests[req.id]) { return; }
      shownRequests[req.id] = true;
      modal('配对请求', '<div style="display:flex;gap:12px;align-items:center"><div class="pd-tile" style="width:40px;height:40px">' + icon('smartphone', 20) + '</div>' +
        '<div>是否允许「' + esc(req.name) + '」配对？<div class="pd-muted" style="font-size:12px">允许后这台手机可以访问已授权的工作区并控制 AI 编程工具</div></div></div>',
        '<button class="pd-btn" data-act="req" data-id="' + esc(req.id) + '" data-allow="0">拒绝</button><button class="pd-btn pd-btn-primary" data-act="req" data-id="' + esc(req.id) + '" data-allow="1">允许</button>');
    });
  }

  /* ---------- 事件 ---------- */
  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-go],[data-act]');
    if (!t) { return; }
    if (t.dataset.go) {
      location.hash = t.dataset.go;
      return;
    }
    var act = t.dataset.act;
    var id = t.dataset.id;
    switch (act) {
      case 'modal-close':
        if (t.classList.contains('pd-scrim') && e.target !== t) { return; }
        closeModal();
        break;
      case 'chat-send': chatSendText(); break;
      case 'chat-attach': document.getElementById('chat-file').click(); break;
      case 'chat-preview':
        imagePreview(t.dataset.name, '/admin/api/assistant/file?seq=' + t.dataset.seq,
          '<button class="pd-btn" data-act="chat-open" data-seq="' + t.dataset.seq + '">' + icon('external-link', 16) + '打开</button>' +
          '<button class="pd-btn" data-act="chat-reveal" data-seq="' + t.dataset.seq + '">' + icon('folder-open', 16) + '在文件夹中显示</button>');
        break;
      case 'chat-open':
      case 'chat-reveal':
        api('POST', '/admin/api/assistant/open', { seq: +t.dataset.seq, reveal: act === 'chat-reveal' }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-refresh': phoneLoad(); break;
      case 'phone-cd': ph.path = t.dataset.path; phoneLoad(); break;
      case 'phone-open':
        if (t.dataset.dir === '1') { ph.path = t.dataset.path; phoneLoad(); } else { phoneOpen(t.dataset.path); }
        break;
      case 'phone-upload': document.getElementById('phone-file').click(); break;
      case 'phone-fetch':
        toast('正在从手机取文件…');
        api('POST', '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/fetch', { path: t.dataset.path }).then(function (r) { toast('已存到 ' + r.path); }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-mkdir':
        modal('新建文件夹', '<div class="pd-field"><label for="mkname">名称</label><input class="pd-input" id="mkname"></div>',
          '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="phone-mkdir-ok">新建</button>');
        break;
      case 'phone-mkdir-ok':
        phoneCall('mkdir', { path: ph.path, name: document.getElementById('mkname').value.trim() }).then(function () { closeModal(); phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-rename':
        modal('重命名', '<div class="pd-field"><label for="rnname">新名称</label><input class="pd-input" id="rnname" value="' + esc(t.dataset.name) + '"></div>',
          '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="phone-rename-ok" data-path="' + esc(t.dataset.path) + '">确定</button>');
        break;
      case 'phone-rename-ok':
        phoneCall('rename', { path: t.dataset.path, name: document.getElementById('rnname').value.trim() }).then(function () { closeModal(); phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-delete':
        confirmBox('删除', '确定从手机上删除「' + esc(t.dataset.name) + '」？删除后无法恢复。', '删除', function () {
          phoneCall('delete', { paths: [t.dataset.path] }).then(function () { toast('已删除'); phoneLoad(); }).catch(function (er) { toast(er.message); });
        });
        break;
      case 'phone-save':
        var p = t.dataset.path;
        var blob = new File([document.getElementById('edit-text').value], p.split('/').pop(), { type: 'text/plain' });
        uploadForm('/admin/api/phone/' + encodeURIComponent(ph.dev) + '/upload?overwrite=1&dir=' + encodeURIComponent(phoneParent(p)), [blob])
          .then(function () { closeModal(); toast('已保存到手机'); phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-root': phoneRootPicker(''); break;
      case 'phone-browse': phoneRootPicker(t.dataset.path); break;
      case 'phone-setroot':
        phoneCall('setRoot', { path: t.dataset.path }).then(function () { closeModal(); toast('已更换手机工作空间'); ph.path = ''; phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      case 'pair-close':
        api('POST', '/admin/api/pair/cancel');
        clearInterval(pairTimer);
        pairInfo = null;
        location.hash = 'settings/devices';
        break;
      case 'pair-refresh': startPair(); break;
      case 'open-inbox': api('POST', '/admin/api/open', { which: 'inbox' }).catch(function (er) { toast(er.message); }); break;
      case 'quit':
        confirmBox('退出服务', '退出后手机将无法连接这台电脑，直到服务再次启动。', '退出', function () {
          api('POST', '/admin/api/quit').then(function () { app.innerHTML = '<div class="pd-center"><div class="pd-muted">服务已退出，可以关闭此窗口</div></div>'; });
        });
        break;
      case 'ws-add': workspaceForm(); break;
      case 'ws-edit': workspaceForm(state.workspaces.filter(function (w) { return w.id === id; })[0]); break;
      case 'ws-save':
        api('POST', '/admin/api/workspaces', { id: id, name: document.getElementById('wname').value, rootPath: document.getElementById('wpath').value, readOnly: document.getElementById('wro').checked })
          .then(function () { closeModal(); toast('已保存'); load(); }).catch(function (er) { toast(er.message); });
        break;
      case 'ws-del':
        confirmBox('删除工作区', '只移除这个工作区的配置，电脑上的文件不会被删除。', '删除', function () {
          api('DELETE', '/admin/api/workspaces/' + encodeURIComponent(id)).then(function () { toast('已删除'); load(); }).catch(function (er) { toast(er.message); });
        });
        break;
      case 'dev-revoke':
        confirmBox('吊销设备', '吊销后「' + esc(t.dataset.name) + '」将立即断开，需要重新扫码配对。', '吊销', function () {
          api('DELETE', '/admin/api/devices/' + encodeURIComponent(id)).then(function () { toast('已吊销'); load(); }).catch(function (er) { toast(er.message); });
        });
        break;
      case 'save-transfer':
        api('PATCH', '/admin/api/config', {
          inboxDir: document.getElementById('inbox').value.trim(),
          notify: { kind: document.getElementById('nkind').value, url: document.getElementById('nurl').value.trim(), topic: document.getElementById('ntopic').value.trim() }
        }).then(function (r) { toast('已保存'); load(); }).catch(function (er) { toast(er.message); });
        break;
      case 'req':
        api('POST', '/admin/api/pair/' + encodeURIComponent(id), { allow: t.dataset.allow === '1' }).then(function () {
          closeModal();
          toast(t.dataset.allow === '1' ? '已允许配对' : '已拒绝');
          if (t.dataset.allow === '1' && route().page === 'pair') { location.hash = 'settings/devices'; }
          setTimeout(load, 600);
        }).catch(function (er) { closeModal(); toast(er.message); });
        break;
    }
  });

  document.addEventListener('change', function (e) {
    var t = e.target;
    if (t.id === 'chat-file' || t.id === 'phone-file') {
      var files = Array.prototype.slice.call(t.files || []);
      t.value = '';
      if (t.id === 'chat-file') { chatSendFiles(files); } else { phoneUpload(files); }
      return;
    }
    if (t.id === 'phone-sel') {
      ph.dev = t.value;
      ph.path = '';
      phoneLoad();
      return;
    }
    if (t.id === 'pause-all') {
      api('POST', '/admin/api/transfers/pause', { paused: t.checked }).then(load);
    } else if (/^f-/.test(t.id)) {
      var f = Object.assign({}, state.config.features);
      f[t.id.slice(2)] = t.checked;
      api('PATCH', '/admin/api/config', { features: f }).then(function () { toast('已更新'); load(); }).catch(function (er) { toast(er.message); });
    } else if (t.id === 'idle') {
      var v = parseInt(t.value, 10);
      if (v > 0) { api('PATCH', '/admin/api/config', { terminalIdleHours: v }).then(function () { toast('已更新'); }); }
    }
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && modalRoot.innerHTML) { closeModal(); }
    if (e.target.id === 'chat-input' && e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      chatSendText();
    }
  });
  document.addEventListener('input', function (e) {
    if (e.target.id === 'chat-input') { chatGrow(e.target); }
  });

  // 粘贴与拖入：文件传输助手里发给手机，手机文件里上传到当前目录
  function dropTarget() {
    var s = route().section;
    return route().page === 'settings' && !modalRoot.innerHTML && (s === 'assistant' || (s === 'phone' && ph.dev && !ph.error)) ? s : '';
  }
  function sendFiles(files) {
    if (dropTarget() === 'assistant') { chatSendFiles(files); } else { phoneUpload(files); }
  }
  document.addEventListener('paste', function (e) {
    if (!dropTarget()) { return; }
    var files = pastedFiles(e);
    if (!files.length) { return; }
    e.preventDefault();
    sendFiles(files);
  });
  document.addEventListener('dragover', function (e) {
    if (!dropTarget()) { return; }
    e.preventDefault();
    app.classList.add('pd-dragging');
  });
  document.addEventListener('dragleave', function (e) {
    if (!e.relatedTarget) { app.classList.remove('pd-dragging'); }
  });
  document.addEventListener('drop', function (e) {
    app.classList.remove('pd-dragging');
    if (!dropTarget()) { return; }
    e.preventDefault();
    sendFiles(Array.prototype.slice.call((e.dataTransfer && e.dataTransfer.files) || []));
  });

  window.addEventListener('hashchange', function () {
    var r = route();
    // 切换页面时关闭普通弹窗，保留配对请求确认
    if (modalRoot.innerHTML && !modalRoot.querySelector('[data-act="req"]')) { closeModal(); }
    if (r.page === 'pair') { startPair(); } else { clearInterval(pairTimer); render(); }
    enter(r);
  });

  load().then(function () {
    var r = route();
    if (r.page === 'pair') { startPair(); }
    enter(r);
  });
  // 文件传输助手打开时每 2 秒取新消息
  setInterval(function () {
    var r = route();
    if (r.page === 'settings' && r.section === 'assistant') { chatLoad(); }
  }, 2000);
  // 定时刷新：只在纯展示页重绘，表单页只检查配对请求，避免冲掉未保存的输入
  setInterval(function () {
    api('GET', '/admin/api/state').then(function (s) {
      state = s;
      var r = route();
      var live = r.page === 'settings' && (r.section === 'overview' || r.section === 'devices');
      if (live && !modalRoot.innerHTML) { render(); }
      checkRequests();
    }).catch(function () {});
  }, 3000);
})();
