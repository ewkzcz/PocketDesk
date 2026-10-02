/**
 * 手机浏览器应急网页（功能子集）：配对、会话列表、聊天与审批、文件传输助手收发文字和文件。
 */
(function () {
  'use strict';

  var TOKEN_KEY = 'pd.token';
  var AGENT = {
    claude: { short: 'CC', color: '#D97757', label: 'Claude Code' },
    codex: { short: 'CX', color: '#10A37F', label: 'Codex' },
    pi: { short: 'Pi', color: '#6B5BFF', label: 'Pi' },
    dsh: { short: 'DS', color: '#4D6BFE', label: 'DSH' },
    terminal: { short: '', color: '#333333', label: '终端', icon: 'terminal' },
    assistant: { short: '', color: '#07C160', label: '文件传输助手', icon: 'send' }
  };
  var app = document.getElementById('app');
  var token = null;
  try { token = localStorage.getItem(TOKEN_KEY); } catch (e) { token = null; }
  var sessions = [];
  var models = {};
  var current = null;
  var ws = null;
  var wsRetry = 1000;

  /** esc：转义 HTML */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  var toastTimer;
  function toast(msg) {
    var el = document.getElementById('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 2000);
  }

  /** api：带令牌调用接口 */
  function api(method, path, body) {
    var headers = { 'Authorization': 'Bearer ' + token };
    if (body !== undefined) { headers['Content-Type'] = 'application/json'; }
    return fetch(path, { method: method, headers: headers, body: body !== undefined ? JSON.stringify(body) : undefined }).then(function (res) {
      return res.text().then(function (t) {
        var d = null;
        try { d = t ? JSON.parse(t) : null; } catch (e) { d = null; }
        if (res.status === 401) { logout(); }
        if (!res.ok) { throw new Error((d && d.message) || '操作失败'); }
        return d;
      });
    });
  }

  function logout() {
    token = null;
    try { localStorage.removeItem(TOKEN_KEY); } catch (e) { /* 忽略 */ }
    if (ws) { ws.close(); }
    renderLogin();
  }

  /** timeText：列表时间 */
  function timeText(ms) {
    if (!ms) { return ''; }
    var d = new Date(ms);
    var now = new Date();
    if (d.toDateString() === now.toDateString()) { return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0'); }
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) { return '昨天'; }
    return (d.getMonth() + 1) + '/' + d.getDate();
  }

  function sizeText(n) {
    if (n < 1024) { return n + ' B'; }
    if (n < 1048576) { return (n / 1024).toFixed(0) + ' KB'; }
    if (n < 1073741824) { return (n / 1048576).toFixed(1) + ' MB'; }
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  function avatar(kind) {
    var a = AGENT[kind] || AGENT.claude;
    if (!a.icon) { return '<img class="pd-avatar" src="/pwa/avatars/' + (AGENT[kind] ? kind : 'claude') + '.svg" alt="' + a.label + '">'; }
    return '<div class="pd-avatar" style="background:' + a.color + '">' + (a.icon ? icon(a.icon, 22) : a.short) + '</div>';
  }

  /* ---------- 配对 ---------- */
  function renderLogin() {
    app.innerHTML = '<div class="pd-bar"><div class="pd-bar-title">PocketDesk</div></div>' +
      '<div class="pd-login"><div class="pd-logo">' + icon('monitor', 32) + '</div>' +
      '<div style="font-size:17px;font-weight:600">输入配对码</div>' +
      '<div class="pd-hint">在电脑上打开「配对新手机」，把显示的 8 位配对码填到下面</div>' +
      '<input id="code" maxlength="9" autocomplete="off" autocapitalize="characters" placeholder="XXXX-XXXX" aria-label="配对码">' +
      '<button class="pd-send" id="pair">配对</button><div class="pd-hint" id="pair-hint"></div></div>';
    var btn = document.getElementById('pair');
    btn.onclick = function () {
      var code = document.getElementById('code').value.trim();
      if (code.replace(/[-\s]/g, '').length !== 8) { toast('请输入 8 位配对码'); return; }
      btn.disabled = true;
      document.getElementById('pair-hint').textContent = '请在电脑上点「允许」';
      fetch('/api/pair', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: code, name: '手机浏览器', platform: 'web' }) })
        .then(function (res) { return res.json().then(function (d) { if (!res.ok) { throw new Error(d.message); } return d; }); })
        .then(function (d) {
          token = d.token;
          try { localStorage.setItem(TOKEN_KEY, token); } catch (e) { /* 忽略 */ }
          start();
        }).catch(function (e) {
          btn.disabled = false;
          document.getElementById('pair-hint').textContent = e.message || '配对失败';
        });
    };
  }

  /* ---------- 会话列表 ---------- */
  function loadSessions() {
    return api('GET', '/api/sessions').then(function (list) {
      sessions = list.filter(function (s) { return s.kind !== 'terminal'; });
      if (!current) { renderList(); }
    });
  }

  function statusSide(s) {
    if (s.state === 'running') { return '<svg class="pd-icon pd-spin" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M21 12a9 9 0 1 1-6.22-8.56"/></svg>'; }
    if (s.state === 'awaiting') { return '<span class="pd-badge">待确认</span>'; }
    if (s.state === 'error') { return '<span style="color:var(--pd-danger)">' + icon('alert-circle', 16) + '</span>'; }
    return '';
  }

  function renderList() {
    var rows = sessions.map(function (s) {
      var sub = s.state === 'running' ? '<span style="color:var(--pd-accent)">执行中</span>' : esc(s.preview || '');
      return '<button class="pd-row" data-open="' + esc(s.id) + '">' + avatar(s.kind) +
        '<div class="pd-row-main"><div class="pd-row-title">' + esc(s.title) + '</div><div class="pd-row-sub">' + sub + '</div></div>' +
        '<div class="pd-row-side"><div class="pd-time">' + timeText(s.updatedAt) + '</div>' + statusSide(s) + '</div></button>';
    }).join('');
    app.innerHTML = '<div class="pd-bar"><div class="pd-bar-title">PocketDesk</div></div>' +
      '<div class="pd-scroll">' + (rows || '<div class="pd-empty">暂无会话，请在 App 中新建</div>') + '</div>';
  }

  /* ---------- 聊天 ---------- */
  /** newModel：一个会话的消息模型 */
  function newModel(sess) {
    return { sess: sess, items: [], byId: {}, lastSeq: 0, state: sess.state };
  }

  /** apply：把一条事件合并进消息模型 */
  function apply(m, e) {
    if (e.seq <= m.lastSeq) { return; }
    m.lastSeq = e.seq;
    var d = e.data || {};
    var find = function (key) { return m.byId[key]; };
    var add = function (key, item) { m.items.push(item); if (key) { m.byId[key] = item; } };
    switch (e.type) {
      case 'state': m.state = d.state; break;
      case 'msg.user': add(null, { kind: 'user', text: d.text, queued: d.queued, file: d.file }); break;
        break;
      case 'msg.delta':
        var it = find('m:' + d.id);
        break;
      case 'msg.done':
        var dn = find('m:' + d.id);
        if (dn) { dn.text = d.text; } else { add('m:' + d.id, { kind: 'agent', text: d.text }); }
        break;
      case 'tool.start': add('t:' + d.id, { kind: 'tool', name: d.name, summary: d.summary || d.name }); break;
      case 'tool.end':
        var t = find('t:' + d.id);
        if (t) { t.output = d.output; t.error = d.isError; t.done = true; }
        break;
      case 'approval.request': add('a:' + d.id, { kind: 'approval', id: d.id, summary: d.summary, tool: d.tool, status: 'pending' }); break;
      case 'approval.done':
        var a = find('a:' + d.id);
        if (a) { a.status = d.status; }
        break;
      case 'diff.summary': add(null, { kind: 'diff', files: d.files || [] }); break;
      case 'error': add(null, { kind: 'sys', text: d.message, error: true }); break;
      case 'system': add(null, { kind: 'sys', text: d.text }); break;
      case 'file': add(null, { kind: 'file', dir: d.direction, name: d.name, size: d.size, outboxId: d.outboxId }); break;
    }
  }

  function openChat(id) {
    var sess = sessions.filter(function (s) { return s.id === id; })[0];
    if (!sess) { return; }
    var m = models[id] || newModel(sess);
    models[id] = m;
    current = id;
    renderChat();
    api('GET', '/api/sessions/' + encodeURIComponent(id) + '/events?after=' + m.lastSeq + '&limit=2000').then(function (evs) {
      evs.forEach(function (e) { apply(m, e); });
      if (current === id) { renderChat(true); }
      sendHello();
    }).catch(function (e) { toast(e.message); });
  }

  function itemHTML(it, kind) {
    switch (it.kind) {
      case 'user':
        var body = esc(it.text || '');
        return '<div class="pd-line mine"><div class="pd-bubble mine">' + body + '</div></div>' + (it.queued ? '<div class="pd-queued">排队中</div>' : '');
      case 'agent':
        return '<div class="pd-line">' + avatar(kind) + '<div class="pd-stack"><div class="pd-bubble agent">' + esc(it.text) + '</div></div></div>';
      case 'tool':
        var ic = it.error ? 'alert-circle' : it.done ? 'check' : 'loader';
        return '<div class="pd-line"><div style="width:36px"></div><div class="pd-stack"><button class="pd-tool" data-toggle>' + icon('wrench', 16) + '<code>' + esc(it.summary) + '</code>' + icon(ic, 14) + '</button>' +
          (it.open && it.output ? '<div class="pd-tool-out">' + esc(it.output) + '</div>' : '') + '</div></div>';
      case 'approval':
        var decided = it.status !== 'pending';
        return '<div class="pd-line"><div style="width:36px"></div><div class="pd-card pd-approve"><div class="pd-card-title">' + icon('alert-triangle', 16) + '需要确认</div>' +
          '<pre>' + esc(it.summary) + '</pre>' +
          (decided ? '<div class="pd-decided">' + ({ allowed: '已允许', denied: '已拒绝', expired: '已超时，按拒绝处理' }[it.status] || it.status) + '</div>' :
            '<div class="pd-approve-btns"><button class="pd-btn pd-btn-primary" data-approve="' + esc(it.id) + '" data-action="allow">允许</button><button class="pd-btn" data-approve="' + esc(it.id) + '" data-action="deny">拒绝</button></div>' +
            '<button class="pd-always" data-approve="' + esc(it.id) + '" data-action="always">本会话总是允许此类操作</button>') + '</div></div>';
      case 'diff':
        return '<div class="pd-line"><div style="width:36px"></div><div class="pd-card"><div class="pd-card-title">本轮改动 · ' + it.files.length + ' 个文件</div>' +
          it.files.slice(0, 12).map(function (f) {
            var st = f.status === 'added' ? '<span class="pd-add">+' + f.added + ' 新建</span>' : '<span><span class="pd-add">+' + f.added + '</span> <span class="pd-del">-' + f.removed + '</span></span>';
            return '<div class="pd-diffrow"><code>' + esc(f.path) + '</code>' + st + '</div>';
          }).join('') + '</div></div>';
      case 'sys':
        return '<div class="pd-sys' + (it.error ? ' err' : '') + '">' + esc(it.text) + '</div>';
      case 'file':
        var mine = it.dir === 'up';
        return '<div class="pd-line' + (mine ? ' mine' : '') + '">' + (mine ? '' : avatar('assistant')) + '<div class="pd-file">' + icon('file', 22) +
          '<div style="min-width:0"><div class="pd-file-name">' + esc(it.name) + '</div><div class="pd-file-sub">' + sizeText(it.size || 0) + (mine ? ' · 已发送到电脑' : '') + '</div></div>' +
          (!mine && it.outboxId ? '<button class="pd-round" data-dl="' + esc(it.outboxId) + '" aria-label="下载">' + icon('download', 18) + '</button>' : '') + '</div></div>';
    }
    return '';
  }

  function renderChat(scroll) {
    var m = models[current];
    if (!m) { return; }
    var sess = m.sess;
    var chat = document.getElementById('chat');
    var atBottom = !chat || chat.scrollHeight - chat.scrollTop - chat.clientHeight < 80;
    var running = m.state === 'running' || m.state === 'awaiting';
    var sub = sess.kind === 'assistant' ? '' : '<small>' + esc(sess.cwd === '.' ? '工作区根目录' : sess.cwd) + (sess.model ? ' · ' + esc(sess.model) : '') + (running ? ' · 执行中' : '') + '</small>';
    var itemsHTML = m.items.map(function (it, i) { return '<div data-i="' + i + '">' + itemHTML(it, sess.kind) + '</div>'; }).join('');
    if (!chat) {
      app.innerHTML = '<div class="pd-bar"><button class="pd-bar-btn" data-back aria-label="返回">' + icon('chevron-left', 24) + '</button><div class="pd-bar-title" id="title"></div></div>' +
        '<div class="pd-chat" id="chat"></div>' +
        '<div class="pd-inputbar">' + (sess.kind === 'assistant' ? '<button class="pd-round" id="attach" aria-label="发送文件">' + icon('paperclip', 22) + '</button><input type="file" id="file" hidden multiple>' : '') +
        '<textarea id="text" rows="1" placeholder="输入消息…" aria-label="消息"></textarea><span id="action"></span></div>';
      chat = document.getElementById('chat');
      bindInput();
    }
    document.getElementById('title').innerHTML = esc(sess.title) + sub;
    chat.innerHTML = itemsHTML || '<div class="pd-sys">暂无消息</div>';
    var action = document.getElementById('action');
    var hasText = document.getElementById('text').value.trim() !== '';
    action.innerHTML = running && !hasText && sess.kind !== 'assistant' ? '<button class="pd-round" id="stop" aria-label="打断" style="color:var(--pd-danger)">' + icon('square', 20) + '</button>' : '<button class="pd-send" id="send"' + (hasText ? '' : ' disabled') + '>发送</button>';
    if (scroll || atBottom) { chat.scrollTop = chat.scrollHeight; }
  }

  function bindInput() {
    var ta = document.getElementById('text');
    ta.addEventListener('input', function () {
      ta.style.height = 'auto';
      ta.style.height = Math.min(ta.scrollHeight, 120) + 'px';
      var btn = document.getElementById('send');
      if (btn) { btn.disabled = ta.value.trim() === ''; } else { renderChat(); }
    });
    var file = document.getElementById('file');
    if (file) {
      document.getElementById('attach').onclick = function () { file.click(); };
      file.onchange = function () {
        Array.prototype.forEach.call(file.files, upload);
        file.value = '';
      };
    }
  }

  function send() {
    var ta = document.getElementById('text');
    var text = ta.value.trim();
    if (!text) { return; }
    var sess = models[current].sess;
    var p = sess.kind === 'assistant' ? api('POST', '/api/assistant/messages', { text: text }) : api('POST', '/api/sessions/' + encodeURIComponent(current) + '/messages', { text: text });
    ta.value = '';
    ta.style.height = 'auto';
    renderChat(true);
    p.catch(function (e) { toast(e.message); ta.value = text; });
  }

  /**
   * upload：用断点上传协议把文件发到电脑（每块 8MB）
   */
  function upload(f) {
    var meta = 'filename ' + b64(f.name) + ',filetype ' + b64(f.type || 'application/octet-stream') + ',target ' + b64('assistant');
    toast('正在发送 ' + f.name);
    fetch('/files/', { method: 'POST', headers: { 'Authorization': 'Bearer ' + token, 'Tus-Resumable': '1.0.0', 'Upload-Length': String(f.size), 'Upload-Metadata': meta } })
      .then(function (res) {
        if (res.status !== 201) { throw new Error('发送失败'); }
        var loc = res.headers.get('Location');
        var chunk = 8 * 1024 * 1024;
        var step = function (offset) {
          if (offset >= f.size && f.size > 0) { return Promise.resolve(); }
          if (f.size === 0) { return Promise.resolve(); }
          return fetch(loc, { method: 'PATCH', headers: { 'Authorization': 'Bearer ' + token, 'Tus-Resumable': '1.0.0', 'Upload-Offset': String(offset), 'Content-Type': 'application/offset+octet-stream' }, body: f.slice(offset, offset + chunk) })
            .then(function (r) {
              if (r.status !== 204) { throw new Error('发送失败'); }
              return step(parseInt(r.headers.get('Upload-Offset'), 10));
            });
        };
        return step(0);
      }).then(function () { toast('已发送 ' + f.name); }).catch(function (e) { toast(e.message); });
  }

  function b64(s) {
    var bytes = new TextEncoder().encode(s);
    var bin = '';
    bytes.forEach(function (b) { bin += String.fromCharCode(b); });
    return btoa(bin);
  }

  /* ---------- 实时事件 ---------- */
  function connect() {
    if (!token) { return; }
    var proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    ws = new WebSocket(proto + '//' + location.host + '/ws?token=' + encodeURIComponent(token));
    ws.onopen = function () { wsRetry = 1000; sendHello(); };
    ws.onmessage = function (ev) {
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.type === 'ping') { ws.send(JSON.stringify({ type: 'ping' })); return; }
      if (m.session) {
        var model = models[m.session];
        if (model) {
          apply(model, m);
          if (current === m.session) { renderChat(); }
        }
        if (m.type === 'state' || m.type === 'msg.done' || m.type === 'msg.user' || m.type === 'approval.request' || m.type === 'file') { scheduleList(); }
      } else if (/^session\./.test(m.type) || m.type === 'outbox.new') {
        scheduleList();
      }
    };
    ws.onclose = function () {
      ws = null;
      if (!token) { return; }
      setTimeout(connect, wsRetry);
      wsRetry = Math.min(wsRetry * 2, 30000);
    };
  }

  function sendHello() {
    if (!ws || ws.readyState !== 1) { return; }
    var cursors = {};
    Object.keys(models).forEach(function (k) { cursors[k] = models[k].lastSeq; });
    ws.send(JSON.stringify({ type: 'hello', cursors: cursors }));
  }

  var listTimer;
  function scheduleList() {
    clearTimeout(listTimer);
    listTimer = setTimeout(loadSessions, 300);
  }

  /* ---------- 交互 ---------- */
  document.addEventListener('click', function (e) {
    var t = e.target.closest('[data-open],[data-back],[data-approve],[data-toggle],[data-dl],#send,#stop');
    if (!t) { return; }
    if (t.dataset.open) { openChat(t.dataset.open); return; }
    if (t.hasAttribute('data-back')) { current = null; loadSessions(); renderList(); return; }
    if (t.id === 'send') { send(); return; }
    if (t.id === 'stop') { api('POST', '/api/sessions/' + encodeURIComponent(current) + '/interrupt').catch(function (er) { toast(er.message); }); return; }
    if (t.dataset.approve) {
      api('POST', '/api/approvals/' + encodeURIComponent(t.dataset.approve), { action: t.dataset.action }).catch(function (er) { toast(er.message); });
      return;
    }
    if (t.hasAttribute('data-toggle')) {
      var i = +t.closest('[data-i]').dataset.i;
      var it = models[current].items[i];
      it.open = !it.open;
      renderChat();
      return;
    }
    if (t.dataset.dl) { download(t.dataset.dl); }
  });

  var composing = false, composeEnd = 0;
  document.addEventListener('compositionstart', function () { composing = true; });
  document.addEventListener('compositionend', function () { composing = false; composeEnd = Date.now(); });
  document.addEventListener('keydown', function (e) {
    var ime = e.isComposing || e.keyCode === 229 || composing || Date.now() - composeEnd < 100;
    if (e.target.id === 'text' && e.key === 'Enter' && !e.shiftKey && !ime) {
      e.preventDefault();
      send();
    }
  });

  /** download：下载电脑发来的文件并确认收到 */
  function download(id) {
    fetch('/api/outbox/' + encodeURIComponent(id) + '/file?download=1', { headers: { 'Authorization': 'Bearer ' + token } }).then(function (res) {
      if (!res.ok) { throw new Error('下载失败'); }
      var name = decodeURIComponent((/filename\*=UTF-8''([^;]+)/.exec(res.headers.get('Content-Disposition') || '') || [])[1] || 'file');
      return res.blob().then(function (b) {
        var a = document.createElement('a');
        a.href = URL.createObjectURL(b);
        a.download = name;
        a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 10000);
        return api('POST', '/api/outbox/' + encodeURIComponent(id) + '/ack');
      });
    }).then(function () { toast('已保存'); }).catch(function (e) { toast(e.message); });
  }

  function start() {
    loadSessions().then(connect).catch(function (e) { toast(e.message); });
  }

  if (token) { start(); } else { renderLogin(); }
})();
