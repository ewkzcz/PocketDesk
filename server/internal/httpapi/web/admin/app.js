/**
 * 桌面端管理页：#pair 配对新手机、#settings/分区 设置窗口；定时刷新状态并弹出配对确认。
 */
(function () {
  'use strict';

  var state = null;
  var pairInfo = null;
  var pairTimer = null;
  var shownRequests = {};
  var app = document.getElementById('app');
  var modalRoot = document.getElementById('modal-root');
  var AGENT_COLORS = { claude: '#D97757', codex: '#10A37F', pi: '#6B5BFF', dsh: '#4D6BFE' };
  var AGENT_SHORT = { claude: 'CC', codex: 'CX', pi: 'Pi', dsh: 'DS' };
  var SECTIONS = [
    ['overview', '概览', 'layout-grid'],
    ['workspaces', '工作区', 'folder'],
    ['devices', '已配对设备', 'smartphone'],
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
    document.title = r.page === 'pair' ? '配对新手机 · PocketDesk' : 'PocketDesk 设置';
    if (r.page === 'pair') { app.innerHTML = pairView(); }
    else { app.innerHTML = settingsView(r.section); }
  }

  /* ---------- 配对窗口 ---------- */
  function pairView() {
    if (!pairInfo) {
      return '<div class="pd-center"><div class="pd-dialog"><div class="pd-dialog-head"><div class="pd-dialog-title">配对新手机</div></div>' +
        '<div class="pd-dialog-body"><div class="pd-muted">正在生成配对码…</div></div></div></div>';
    }
    var addr = (pairInfo.addresses || [])[0] || '未检测到局域网地址';
    return '<div class="pd-center"><div class="pd-dialog">' +
      '<div class="pd-dialog-head"><div class="pd-dialog-title">配对新手机</div><button class="pd-icon-btn" data-act="pair-close" aria-label="关闭">' + icon('x', 18) + '</button></div>' +
      '<div class="pd-dialog-body">' +
      '<div class="pd-qr"><img alt="配对二维码" src="' + esc(pairInfo.qr) + '"></div>' +
      '<div class="pd-muted" id="pair-left">' + countdownText() + '</div>' +
      '<div class="pd-steps">' +
      step(1, '在手机上打开 PocketDesk，进入「消息 → +」，点「扫一扫」') +
      step(2, '对准上方二维码扫描，或手动输入下方配对码') +
      step(3, '在电脑上点击「允许」完成配对') + '</div>' +
      '<div class="pd-codebox"><div><div class="pd-muted" style="font-size:11px">手动配对码</div><div class="pd-code">' + esc(pairInfo.code) + '</div></div>' +
      '<div class="pd-muted" style="font-size:11px;text-align:right">' + esc(pairInfo.hostName) + '<br>' + esc(addr) + '</div></div>' +
      '</div><div class="pd-dialog-foot"><button class="pd-btn" data-act="pair-refresh">换一个配对码</button><button class="pd-btn" data-act="pair-close">取消</button></div></div></div>';
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

  /* ---------- 设置窗口 ---------- */
  function settingsView(section) {
    var nav = SECTIONS.map(function (s) {
      return '<button class="pd-nav' + (s[0] === section ? ' active' : '') + '" data-go="settings/' + s[0] + '">' + icon(s[2], 16) + s[1] + '</button>';
    }).join('');
    var body = ({ overview: overviewView, workspaces: workspacesView, devices: devicesView, transfer: transferView, security: securityView, about: aboutView }[section] || overviewView)();
    return '<div class="pd-center"><div class="pd-window">' +
      '<div class="pd-window-head"><div class="pd-dialog-title">PocketDesk 设置</div></div>' +
      '<div class="pd-window-body"><nav class="pd-side">' + nav + '</nav><main class="pd-main">' + body + '</main></div></div></div>';
  }
  function head(title, sub, action) {
    return '<div class="pd-section-head"><div><div class="pd-h1">' + title + '</div><div class="pd-sub">' + sub + '</div></div>' + (action || '') + '</div>';
  }

  function overviewView() {
    var addrs = (state.addresses || []).map(function (a) {
      return '<div><span class="pd-mono">' + esc(a.ip) + '</span> <span class="pd-tag' + (a.kind === 'tailscale' ? '' : ' pd-tag-ok') + '">' + (a.kind === 'tailscale' ? 'Tailscale' : '局域网') + '</span></div>';
    }).join('') || '<span class="pd-muted">未检测到局域网或 Tailscale 地址</span>';
    var agents = (state.agents || []).map(function (a) {
      return '<div class="pd-agent"><div class="pd-avatar" style="background:' + AGENT_COLORS[a.kind] + '">' + AGENT_SHORT[a.kind] + '</div>' +
        '<div style="min-width:0"><div>' + esc(a.label) + '</div><div class="pd-muted" style="font-size:12px">' + (a.installed ? esc(a.version || '已安装') : '未安装') + '</div></div></div>';
    }).join('');
    var online = state.devices.filter(function (d) { return d.online; }).length;
    return head('概览', '电脑端服务的运行状态', '<button class="pd-btn pd-btn-primary" data-go="pair">' + icon('qr-code', 16) + '配对新手机</button>') +
      '<div class="pd-card"><dl class="pd-kv">' +
      '<dt>电脑名称</dt><dd>' + esc(state.host.name) + '</dd>' +
      '<dt>状态</dt><dd><span class="pd-status"><span class="pd-dot"></span>运行中 · 端口 ' + state.host.port + '</span></dd>' +
      '<dt>访问地址</dt><dd>' + addrs + '</dd>' +
      '<dt>在线手机</dt><dd>' + online + ' 台</dd>' +
      '<dt>证书指纹</dt><dd class="pd-mono" style="font-size:12px">' + esc(fmtFp(state.host.fingerprint)) + '</dd>' +
      '</dl></div>' +
      '<div class="pd-block" style="margin-top:24px"><div class="pd-h2">AI 编程工具</div><div class="pd-agents">' + agents + '</div></div>';
  }
  function fmtFp(fp) { return (fp || '').toUpperCase().match(/.{1,4}/g).join(' '); }

  function workspacesView() {
    var rows = state.workspaces.map(function (w) {
      return '<tr><td style="font-weight:500">' + esc(w.name) + '</td><td class="pd-path">' + esc(w.rootPath) + '</td>' +
        '<td><span class="pd-tag' + (w.readOnly ? '' : ' pd-tag-ok') + '">' + (w.readOnly ? '只读' : '读写') + '</span></td>' +
        '<td><div class="pd-actions"><button class="pd-link" data-act="ws-edit" data-id="' + esc(w.id) + '">编辑</button><span class="pd-sepdot">·</span>' +
        '<button class="pd-link pd-link-danger" data-act="ws-del" data-id="' + esc(w.id) + '">删除</button></div></td></tr>';
    }).join('');
    var warns = state.workspaces.filter(function (w) { return w.warning; }).map(function (w) {
      return '<div class="pd-warn">' + icon('alert-triangle', 16) + '<div>' + esc(w.warning) + '</div></div>';
    }).join('');
    return head('工作区', '手机上可访问的电脑文件夹', '<button class="pd-btn pd-btn-primary" data-act="ws-add">' + icon('plus', 16) + '添加工作区</button>') +
      '<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th>路径</th><th class="pd-col-tag">权限</th><th style="width:100px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有工作区，添加后手机才能浏览电脑上的文件</div>') + '</div>' + warns;
  }

  function devicesView() {
    var rows = state.devices.map(function (d) {
      var status = d.revoked ? '<span class="pd-tag">已吊销</span>' : d.online ? '<span class="pd-tag pd-tag-ok">在线</span>' : '<span class="pd-muted">' + ago(d.lastSeen) + '</span>';
      return '<tr><td style="font-weight:500">' + esc(d.name) + '</td><td class="pd-hide-s pd-muted">' + esc(platformName(d.platform)) + '</td><td>' + status + '</td>' +
        '<td>' + (d.revoked ? '' : '<button class="pd-link pd-link-danger" data-act="dev-revoke" data-id="' + esc(d.id) + '" data-name="' + esc(d.name) + '">吊销</button>') + '</td></tr>';
    }).join('');
    return head('已配对设备', '吊销后该手机需要重新扫码配对', '<button class="pd-btn pd-btn-primary" data-go="pair">' + icon('qr-code', 16) + '配对新手机</button>') +
      '<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th class="pd-hide-s">系统</th><th>状态</th><th style="width:80px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有配对的手机</div>') + '</div>';
  }
  function platformName(p) { return { ios: 'iOS', android: 'Android', web: '浏览器' }[p] || p || '未知'; }

  function transferView() {
    var c = state.config;
    var n = c.notify || {};
    return head('传输', '文件收发目录与后台通知') +
      '<div class="pd-h2">目录</div><div class="pd-card"><div class="pd-form-grid">' +
      '<div class="pd-form-row"><div class="pd-field"><label for="inbox">收件目录（手机发来的文件）</label><input class="pd-input pd-mono" id="inbox" value="' + esc(c.transfer.inboxDir) + '"></div><button class="pd-btn" data-act="open-inbox" aria-label="打开收件目录">' + icon('folder-open', 16) + '</button></div>' +
      '<div class="pd-form-row"><div class="pd-field"><label for="outbox">发件目录（放进来的文件会发给手机）</label><input class="pd-input pd-mono" id="outbox" value="' + esc(c.transfer.outboxDir) + '"></div><button class="pd-btn" data-act="open-outbox" aria-label="打开发件目录">' + icon('folder-open', 16) + '</button></div>' +
      '</div><div class="pd-setting"><div><div class="pd-setting-name">暂停所有传输</div><div class="pd-setting-desc">暂停期间手机会自动等待，恢复后继续</div></div>' + toggle('pause-all', state.transfersPaused) + '</div></div>' +
      '<div class="pd-h2" style="margin-top:24px">后台通知</div><div class="pd-card"><div class="pd-form-grid">' +
      '<div class="pd-field"><label for="nkind">推送方式</label><select class="pd-input" id="nkind"><option value="">不推送</option><option value="ntfy"' + (n.kind === 'ntfy' ? ' selected' : '') + '>ntfy</option><option value="bark"' + (n.kind === 'bark' ? ' selected' : '') + '>Bark</option></select></div>' +
      '<div class="pd-field"><label for="nurl">服务地址</label><input class="pd-input" id="nurl" placeholder="https://ntfy.sh" value="' + esc(n.url) + '"></div>' +
      '<div class="pd-field"><label for="ntopic">主题或设备密钥</label><input class="pd-input" id="ntopic" value="' + esc(n.topic) + '"></div>' +
      '</div></div>' +
      '<div style="margin-top:16px;display:flex;justify-content:flex-end"><button class="pd-btn pd-btn-primary" data-act="save-transfer">保存</button></div>';
  }

  function securityView() {
    var f = state.config.features;
    return head('安全', '单独开关各项功能，终端可以访问整台电脑，默认关闭') +
      '<div class="pd-card">' +
      setting('Agent 会话', '手机向电脑上的 AI 编程工具发送提示词', 'f-agents', f.agents) +
      setting('终端', '手机可在电脑上执行任意命令，每次进入需验证指纹或面容', 'f-terminal', f.terminal) +
      setting('文件编辑', '手机可保存、重命名、移动和删除工作区文件', 'f-fileEdit', f.fileEdit) +
      '<div class="pd-setting"><div><div class="pd-setting-name">终端空闲自动结束</div><div class="pd-setting-desc">没有输入也没有连接超过设定小时数后结束</div></div>' +
      '<input class="pd-input" id="idle" type="number" min="1" max="720" style="width:90px" value="' + state.config.terminalIdleHours + '" aria-label="小时"></div>' +
      '</div>' +
      '<div class="pd-h2" style="margin-top:24px">操作记录</div><div class="pd-card" id="audit"><div class="pd-empty">正在加载…</div></div>';
  }
  function setting(name, desc, id, on) {
    return '<div class="pd-setting"><div><div class="pd-setting-name">' + name + '</div><div class="pd-setting-desc">' + desc + '</div></div>' + toggle(id, on) + '</div>';
  }
  function toggle(id, on) {
    return '<label class="pd-switch"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '><span></span></label>';
  }

  function aboutView() {
    return head('关于', '') +
      '<div class="pd-card"><dl class="pd-kv">' +
      '<dt>版本</dt><dd>' + esc(state.host.version) + '</dd>' +
      '<dt>数据目录</dt><dd class="pd-mono" style="font-size:12px">' + esc(state.dataDir) + '</dd>' +
      '</dl></div><div style="margin-top:16px"><button class="pd-btn pd-btn-danger" data-act="quit">' + icon('log-out', 16) + '退出服务</button></div>';
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
      case 'modal-close': closeModal(); break;
      case 'pair-close':
        api('POST', '/admin/api/pair/cancel');
        clearInterval(pairTimer);
        pairInfo = null;
        location.hash = 'settings/devices';
        break;
      case 'pair-refresh': startPair(); break;
      case 'open-inbox': api('POST', '/admin/api/open', { which: 'inbox' }).catch(function (er) { toast(er.message); }); break;
      case 'open-outbox': api('POST', '/admin/api/open', { which: 'outbox' }).catch(function (er) { toast(er.message); }); break;
      case 'quit':
        confirmBox('退出服务', '退出后手机将无法连接这台电脑，直到服务再次启动。', '退出', function () {
          api('POST', '/admin/api/quit').then(function () { app.innerHTML = '<div class="pd-center"><div class="pd-muted">服务已退出，可以关闭此页面</div></div>'; });
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
          outboxDir: document.getElementById('outbox').value.trim(),
          notify: { kind: document.getElementById('nkind').value, url: document.getElementById('nurl').value.trim(), topic: document.getElementById('ntopic').value.trim() }
        }).then(function (r) { toast(r.restartRequired ? '已保存，目录变更在重启服务后生效' : '已保存'); load(); }).catch(function (er) { toast(er.message); });
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
  });

  window.addEventListener('hashchange', function () {
    var r = route();
    // 切换页面时关闭普通弹窗，保留配对请求确认
    if (modalRoot.innerHTML && !modalRoot.querySelector('[data-act="req"]')) { closeModal(); }
    if (r.page === 'pair') { startPair(); } else { clearInterval(pairTimer); render(); }
    if (r.section === 'security') { setTimeout(loadAudit, 0); }
  });

  load().then(function () {
    var r = route();
    if (r.page === 'pair') { startPair(); }
    if (r.section === 'security') { loadAudit(); }
  });
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
