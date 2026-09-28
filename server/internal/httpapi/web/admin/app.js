/**
 * 桌面端：布局对齐微信桌面版——左侧图标栏、中间列表、右侧内容。
 * 会话、聊天、审批、文件传输助手与手机端共用同一组接口（以「电脑」身份），两端记录与状态保持一致；
 * 桌面端特有：生成配对二维码、管理手机工作空间、电脑端设置。
 */
(function () {
  'use strict';

  var P = '/admin/p';
  var app = document.getElementById('app');
  var modalRoot = document.getElementById('modal-root');
  var AGENT = { claude: 'Claude Code', codex: 'Codex', pi: 'Pi', dsh: 'DSH' };
  var SETTINGS = [
    ['overview', '概览', 'layout-grid'],
    ['workspaces', '工作区', 'folder'],
    ['devices', '已配对设备', 'smartphone'],
    ['transfer', '传输', 'arrow-up-down'],
    ['security', '安全', 'shield'],
    ['appearance', '外观', 'palette'],
    ['about', '关于', 'info']
  ];

  /* ---------- 基础工具 ---------- */

  /** esc：转义 HTML */
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  /** api：调用接口，失败时抛出带提示文字的错误 */
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

  var toastTimer = null;
  function toast(msg) {
    var el = document.getElementById('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { el.classList.remove('show'); }, 1800);
  }

  /** store：本机偏好（未读数、已删除的消息、外观），读写失败时忽略 */
  function load(key, def) {
    try { var v = localStorage.getItem(key); return v ? JSON.parse(v) : def; } catch (e) { return def; }
  }
  function save(key, v) {
    try { localStorage.setItem(key, JSON.stringify(v)); } catch (e) { /* 无痕模式等情况不保存 */ }
  }

  /** copyText：复制到剪贴板 */
  function copyText(text) {
    var done = function () { toast('已复制'); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { copyFallback(text); done(); });
    } else {
      copyFallback(text);
      done();
    }
  }
  function copyFallback(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* 忽略 */ }
    ta.remove();
  }

  function pad(n) { return String(n).padStart(2, '0'); }
  /** fmtTime：固定为中文 24 小时制 */
  function fmtTime(ms) {
    var d = new Date(ms);
    return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
  }
  /** listTime：会话列表时间（今天显示时分，昨天显示「昨天」，其余显示月/日） */
  function listTime(ms) {
    if (!ms) { return ''; }
    var d = new Date(ms), now = new Date();
    if (d.toDateString() === now.toDateString()) { return pad(d.getHours()) + ':' + pad(d.getMinutes()); }
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) { return '昨天'; }
    return d.getFullYear() === now.getFullYear() ? (d.getMonth() + 1) + '/' + d.getDate() : d.getFullYear() % 100 + '/' + (d.getMonth() + 1) + '/' + d.getDate();
  }
  /** chatTime：聊天中的时间分隔 */
  function chatTime(ms) {
    var d = new Date(ms), now = new Date();
    var hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (d.toDateString() === now.toDateString()) { return hm; }
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) { return '昨天 ' + hm; }
    return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
  }
  function fmtSize(n) {
    if (!n && n !== 0) { return ''; }
    if (n < 1024) { return n + ' B'; }
    if (n < 1048576) { return (n / 1024).toFixed(1) + ' K'; }
    if (n < 1073741824) { return (n / 1048576).toFixed(1) + ' M'; }
    return (n / 1073741824).toFixed(2) + ' G';
  }
  function isImage(name) { return /\.(png|jpe?g|gif|webp|bmp|svg)$/i.test(name || ''); }
  function oneLine(s, n) {
    var t = String(s || '').replace(/\s+/g, ' ').trim();
    return t.length > n ? t.slice(0, n) + '…' : t;
  }

  /* ---------- 外观 ---------- */
  function applyTheme() {
    var t = load('pd.theme', 'system');
    if (t === 'system') { document.documentElement.removeAttribute('data-theme'); } else { document.documentElement.setAttribute('data-theme', t); }
  }
  applyTheme();

  /* ---------- Markdown ---------- */

  /** inline：行内格式（先转义再替换） */
  function inline(s) {
    var codes = [];
    s = esc(s).replace(/`([^`]+)`/g, function (_, c) { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
      .replace(/~~([^~]+)~~/g, '<del>$1</del>')
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noreferrer">$1</a>');
    return s.replace(/\u0000(\d+)\u0000/g, function (_, i) { return '<code>' + codes[+i] + '</code>'; });
  }

  /** md：把 Agent 回复的 Markdown 转为 HTML（标题、列表、引用、表格、代码块） */
  function md(src) {
    var lines = String(src || '').replace(/\r\n?/g, '\n').split('\n');
    var out = [], i = 0, para = [];
    function flush() { if (para.length) { out.push('<p>' + para.map(inline).join('<br>') + '</p>'); para = []; } }
    while (i < lines.length) {
      var l = lines[i];
      var fence = /^\s*```\s*([\w+-]*)/.exec(l);
      if (fence) {
        flush();
        var code = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        out.push('<div class="pd-code"><div class="pd-code-bar"><span>' + esc(fence[1] || '代码') + '</span><button class="pd-icon-btn" data-act="copy-code" title="复制代码" aria-label="复制代码">' + icon('copy', 14) + '</button></div><pre><code>' + esc(code.join('\n')) + '</code></pre></div>');
        continue;
      }
      var h = /^(#{1,6})\s+(.*)$/.exec(l);
      if (h) { flush(); var lv = Math.min(h[1].length, 4); out.push('<h' + lv + '>' + inline(h[2]) + '</h' + lv + '>'); i++; continue; }
      if (/^\s*(---|\*\*\*|___)\s*$/.test(l)) { flush(); out.push('<hr>'); i++; continue; }
      if (/^\s*>/.test(l)) {
        flush();
        var q = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) { q.push(lines[i].replace(/^\s*>\s?/, '')); i++; }
        out.push('<blockquote>' + md(q.join('\n')) + '</blockquote>');
        continue;
      }
      if (/^\s*\|.*\|\s*$/.test(l) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
        flush();
        var cells = function (row) { return row.trim().replace(/^\||\|$/g, '').split('|').map(function (c) { return c.trim(); }); };
        var head = cells(l);
        i += 2;
        var rows = [];
        while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) { rows.push(cells(lines[i])); i++; }
        out.push('<table><tr>' + head.map(function (c) { return '<th>' + inline(c) + '</th>'; }).join('') + '</tr>' +
          rows.map(function (r) { return '<tr>' + r.map(function (c) { return '<td>' + inline(c) + '</td>'; }).join('') + '</tr>'; }).join('') + '</table>');
        continue;
      }
      var li = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(l);
      if (li) {
        flush();
        var ordered = /\d/.test(li[2]);
        var items = [];
        while (i < lines.length) {
          var m = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(lines[i]);
          if (!m) {
            if (/^\s{2,}\S/.test(lines[i]) && items.length) { items[items.length - 1] += '\n' + lines[i].trim(); i++; continue; }
            break;
          }
          items.push(m[3]);
          i++;
        }
        out.push((ordered ? '<ol>' : '<ul>') + items.map(function (t) {
          var task = /^\[( |x|X)\]\s+(.*)$/.exec(t);
          return '<li>' + (task ? (task[1] === ' ' ? '☐ ' : '☑ ') + inline(task[2]) : inline(t).replace(/\n/g, '<br>')) + '</li>';
        }).join('') + (ordered ? '</ol>' : '</ul>'));
        continue;
      }
      if (!l.trim()) { flush(); i++; continue; }
      para.push(l);
      i++;
    }
    flush();
    return out.join('');
  }

  /* ---------- 头像 ---------- */
  function avatarHtml(kind, small) {
    var cls = 'pd-avatar' + (small ? ' pd-avatar-s' : '');
    if (AGENT[kind]) { return '<div class="' + cls + '"><img alt="" src="/admin/avatars/' + kind + '.svg"></div>'; }
    if (kind === 'assistant') { return '<div class="' + cls + '" style="background:var(--pd-tile-green)">' + icon('send', small ? 18 : 20) + '</div>'; }
    if (kind === 'terminal') { return '<div class="' + cls + '" style="background:var(--pd-tile-ink)">' + icon('terminal', small ? 18 : 20) + '</div>'; }
    if (kind === 'phone') { return '<div class="' + cls + '" style="background:var(--pd-tile-teal)">' + icon('smartphone', small ? 18 : 20) + '</div>'; }
    if (kind === 'host') { return '<div class="' + cls + '" style="background:var(--pd-accent)">' + icon('monitor', small ? 18 : 20) + '</div>'; }
    return '<div class="' + cls + '" style="background:var(--pd-tile-indigo)">' + icon('bot', 20) + '</div>';
  }
  function tileHtml(name, color) { return '<span class="pd-tile" style="background:' + color + '">' + icon(name, 16) + '</span>'; }

  /* ---------- 状态 ---------- */
  var host = null;               // 电脑端状态（设置页用）
  var sessions = [];             // 会话列表，与手机端相同
  var logs = {};                 // 会话 ID → { events, last, loaded }
  var unread = load('pd.unread', {});
  var hidden = load('pd.hidden', {});
  var query = '';
  var pending = [];              // 当前会话待发送的附件 { name, path }
  var shownRequests = {};
  var pairInfo = null, pairTimer = null;

  /** route：#chat/会话、#phone、#settings/分区、#pair */
  function route() {
    var h = location.hash.replace(/^#/, '');
    if (h === 'pair') { return { page: 'pair' }; }
    var m = /^settings\/?(\w*)/.exec(h);
    if (m) { return { page: 'settings', section: m[1] || 'overview' }; }
    if (h === 'phone') { return { page: 'phone' }; }
    m = /^chat\/(.+)$/.exec(h);
    return { page: 'chat', sid: m ? decodeURIComponent(m[1]) : '' };
  }

  function session(id) { return sessions.filter(function (s) { return s.id === id; })[0]; }
  function isAgent(s) { return !!AGENT[s.kind]; }

  /** title：列表与标题栏的会话名（与手机端规则一致） */
  function title(s) {
    if (!s) { return ''; }
    if (s.kind === 'assistant') { return '文件传输助手'; }
    var label = AGENT[s.kind] || (s.kind === 'terminal' ? '终端' : s.kind);
    var t = (s.title || '').trim();
    if (!t || t === label) { return s.kind === 'terminal' ? '终端' : label + ' · 新会话'; }
    return t.indexOf(label + ' · ') === 0 ? t : label + ' · ' + t;
  }

  function totalUnread() { return sessions.reduce(function (n, s) { return n + (unread[s.id] || 0); }, 0); }
  function setUnread(id, n) {
    if (n) { unread[id] = n; } else { delete unread[id]; }
    save('pd.unread', unread);
    var t = totalUnread();
    document.title = (t ? '(' + t + ') ' : '') + 'PocketDesk';
  }

  /** countsUnread：桌面端视角算作新消息的事件（手机发来的也算） */
  function countsUnread(e) {
    var d = e.data || {};
    switch (e.type) {
      case 'msg.done': case 'approval.request': case 'error': return true;
      case 'msg.user': return e.session === 'assistant';
      case 'file': return d.direction === 'up';
      default: return false;
    }
  }

  /** summarize：按事件更新列表中的状态与摘要（与手机端规则一致） */
  function summarize(s, e) {
    var d = e.data || {};
    var at = e.createdAt || Date.now();
    s.lastSeq = Math.max(s.lastSeq || 0, e.seq || 0);
    switch (e.type) {
      case 'state': s.state = d.state; s.updatedAt = at; break;
      case 'msg.user': s.preview = (e.session === 'assistant' ? '手机：' : '你：') + oneLine(d.text, 60); s.updatedAt = at; break;
      case 'msg.host': s.preview = '电脑：' + oneLine(d.text, 60); s.updatedAt = at; break;
      case 'msg.done': s.preview = oneLine(d.text, 60); s.updatedAt = at; break;
      case 'approval.request': s.preview = '待确认：' + oneLine(d.summary, 50); s.updatedAt = at; break;
      case 'error': s.preview = '出错：' + oneLine(d.message, 50); s.updatedAt = at; break;
      case 'diff.summary': s.preview = '已完成：改动了 ' + (d.files || []).length + ' 个文件'; s.updatedAt = at; break;
      case 'file': s.preview = (isImage(d.name) ? '[图片] ' : '[文件] ') + d.name; s.updatedAt = at; break;
      case 'session.model': s.model = d.model; break;
    }
  }

  function loadSessions() {
    return api('GET', P + '/api/sessions').then(function (list) {
      sessions = list || [];
      renderList();
      if (route().page === 'chat') { renderHead(); }
    });
  }

  /** loadLog：会话最近的记录 */
  function loadLog(id) {
    var lg = logs[id] || (logs[id] = { events: [], last: 0, loaded: false });
    if (lg.loaded) { return Promise.resolve(lg); }
    return api('GET', P + '/api/sessions/' + encodeURIComponent(id) + '/events?before=' + Number.MAX_SAFE_INTEGER + '&limit=2000').then(function (evs) {
      (evs || []).sort(function (a, b) { return a.seq - b.seq; }).forEach(function (e) {
        if (e.seq > lg.last) { lg.events.push(e); lg.last = e.seq; }
      });
      lg.loaded = true;
      return lg;
    });
  }

  /**
   * buildItems：事件合成聊天条目（与手机端 ChatLog 规则一致）
   *
   * 流式片段合并为一条回复，工具开始与结束合并为一张卡片，审批请求与结果合并。
   */
  function buildItems(events) {
    var items = [], by = {};
    function add(key, it) { it.at = it.at || 0; items.push(it); if (key) { by[key] = it; } }
    events.forEach(function (e) {
      var d = e.data || {}, cur;
      var base = { seq: e.seq, at: e.createdAt };
      switch (e.type) {
        case 'msg.user':
          add(null, Object.assign(base, { t: 'user', text: d.text || '', attachments: d.attachments || [], queued: !!d.queued, delegate: d.delegate || '', phone: e.session === 'assistant' }));
          break;
        case 'msg.host':
          add(null, Object.assign(base, { t: 'host', text: d.text || '' }));
          break;
        case 'msg.delta':
          cur = by['m:' + d.id];
          if (cur) { cur.text += d.text || ''; } else { add('m:' + d.id, Object.assign(base, { t: 'agent', text: d.text || '', streaming: true })); }
          break;
        case 'msg.done':
          cur = by['m:' + d.id];
          if (cur) { cur.text = d.text || cur.text; cur.streaming = false; } else { add('m:' + d.id, Object.assign(base, { t: 'agent', text: d.text || '', streaming: false })); }
          break;
        case 'thinking':
          cur = by['t:' + d.id];
          if (!cur) {
            if (d.done && !d.text) { break; }
            cur = Object.assign(base, { t: 'think', text: '', done: false });
            add('t:' + d.id, cur);
          }
          if (d.delta) { cur.text += d.text || ''; } else if (d.text) { cur.text = d.text; }
          if (d.done) { cur.done = true; }
          break;
        case 'tool.start':
          add('tool:' + d.id, Object.assign(base, { t: 'tool', name: d.name, kind: d.kind, summary: d.summary || d.name, input: d.input || {}, output: '', done: false, error: false }));
          break;
        case 'tool.end':
          cur = by['tool:' + d.id];
          if (cur) { cur.output = d.output || ''; cur.error = !!d.isError; cur.done = true; }
          break;
        case 'approval.request':
          add('ap:' + d.id, Object.assign(base, { t: 'approval', id: d.id, tool: d.tool, kind: d.kind, summary: d.summary, input: d.input || {}, status: '' }));
          break;
        case 'approval.done':
          cur = by['ap:' + d.id];
          if (cur) { cur.status = d.status; }
          break;
        case 'diff.summary':
          add(null, Object.assign(base, { t: 'diff', files: d.files || [] }));
          break;
        case 'error':
          add(null, Object.assign(base, { t: 'sys', text: d.message, error: true, retryable: !!d.retryable }));
          break;
        case 'system':
          if (d.text) { add(null, Object.assign(base, { t: 'sys', text: d.text })); }
          break;
        case 'file':
          add(null, Object.assign(base, { t: 'file', up: d.direction === 'up', name: d.name, size: d.size, path: d.path }));
          break;
      }
    });
    var hid = hidden[events.length && events[0].session] || [];
    return items.filter(function (it) { return hid.indexOf(it.seq) < 0; });
  }

  /* ---------- 实时通道 ---------- */
  var sock = null, sockRetry = 1, refreshTimer = null;

  function connect() {
    var url = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + P + '/ws';
    var ws;
    try { ws = new WebSocket(url); } catch (e) { return; }
    sock = ws;
    ws.onopen = function () {
      var cursors = {};
      Object.keys(logs).forEach(function (id) { if (logs[id].loaded) { cursors[id] = logs[id].last; } });
      ws.send(JSON.stringify({ type: 'hello', cursors: cursors }));
    };
    ws.onmessage = function (ev) {
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.type === 'ping') { ws.send(JSON.stringify({ type: 'pong' })); return; }
      if (m.type === 'ready') { sockRetry = 1; return; }
      onEvent(m);
    };
    ws.onclose = function () {
      if (sock !== ws) { return; }
      sock = null;
      setTimeout(connect, Math.min(sockRetry, 15) * 1000);
      sockRetry *= 2;
    };
  }

  /** onEvent：实时事件更新列表、未读与打开中的聊天 */
  function onEvent(e) {
    if (!e.session) {
      if (e.type === 'session.created' || e.type === 'session.updated') {
        clearTimeout(refreshTimer);
        refreshTimer = setTimeout(loadSessions, 300);
      } else if (e.type === 'session.preview' && e.data) {
        var s0 = session(e.data.session);
        if (s0) { s0.preview = e.data.preview; renderList(); }
      }
      return;
    }
    var lg = logs[e.session];
    if (lg && lg.loaded) {
      if (e.seq <= lg.last) { return; }
      lg.events.push(e);
      lg.last = e.seq;
    }
    var s = session(e.session);
    if (!s) { clearTimeout(refreshTimer); refreshTimer = setTimeout(loadSessions, 300); return; }
    summarize(s, e);
    var r = route();
    var viewing = r.page === 'chat' && r.sid === e.session && document.visibilityState === 'visible';
    if (countsUnread(e) && !viewing) { setUnread(e.session, (unread[e.session] || 0) + 1); }
    scheduleList();
    if (r.page === 'chat' && r.sid === e.session) { scheduleChat(); if (e.type === 'state' || e.type === 'session.model') { renderHead(); } }
  }

  // 流式片段频繁，合并到下一帧再重绘
  var listFrame = 0, chatFrame = 0;
  function scheduleList() { if (!listFrame) { listFrame = requestAnimationFrame(function () { listFrame = 0; renderList(); renderRail(); }); } }
  function scheduleChat() { if (!chatFrame) { chatFrame = requestAnimationFrame(function () { chatFrame = 0; renderMsgs(false); }); } }

  /* ---------- 整体布局 ---------- */

  /**
   * render：按路由绘制三栏
   *
   * 处理流程：
   * 1、配对页单独占满窗口（独立的配对窗口使用）
   * 2、其余为图标栏 + 列表 + 内容，各部分可单独刷新
   */
  function render() {
    var r = route();
    // 1、配对
    if (r.page === 'pair') {
      app.innerHTML = '<div class="pd-pair">' + pairBody() + '</div>';
      return;
    }
    // 2、三栏
    app.innerHTML = '<div class="pd-shell"><nav class="pd-rail" id="rail"></nav><aside class="pd-list" id="list"></aside><main class="pd-main" id="main"></main></div>';
    renderRail();
    renderList();
    renderMain();
  }

  function renderRail() {
    var el = document.getElementById('rail');
    if (!el) { return; }
    var r = route(), n = totalUnread();
    var btn = function (go, ic, label, active, badge) {
      return '<button class="pd-rail-btn' + (active ? ' active' : '') + '" data-go="' + go + '" title="' + label + '" aria-label="' + label + '">' + icon(ic, 24) +
        (badge ? '<span class="pd-badge">' + (badge > 99 ? '99+' : badge) + '</span>' : '') + '</button>';
    };
    el.innerHTML = '<div class="pd-me" title="' + esc(host ? host.host.name : '') + '">' + icon('monitor', 20) + '</div>' +
      btn('chat', 'message-circle', '消息', r.page === 'chat', n) +
      btn('phone', 'hard-drive', '手机文件', r.page === 'phone', 0) +
      '<div class="pd-rail-gap"></div>' +
      '<button class="pd-rail-btn" data-act="pair" title="配对新手机" aria-label="配对新手机">' + icon('smartphone', 22) + '</button>' +
      btn('settings', 'menu', '设置', r.page === 'settings', 0);
  }

  function renderList() {
    var el = document.getElementById('list');
    if (!el) { return; }
    var r = route();
    el.classList.toggle('narrow', r.page === 'settings');
    if (r.page === 'chat') {
      var body = document.getElementById('rows');
      if (!body) {
        el.innerHTML = '<div class="pd-list-top"><label class="pd-search">' + icon('search', 14) + '<input id="search" placeholder="搜索" value="' + esc(query) + '"></label>' +
          '<button class="pd-plus" data-act="new" title="新建会话" aria-label="新建会话">' + icon('plus', 16) + '</button></div><div class="pd-list-body" id="rows"></div>';
        body = el.querySelector('.pd-list-body');
      }
      body.innerHTML = sessionRows(r.sid);
    } else if (r.page === 'phone') {
      el.innerHTML = '<div class="pd-list-top"><div class="pd-list-title">手机</div></div><div class="pd-list-body">' + phoneRows() + '</div>';
    } else {
      el.innerHTML = '<div class="pd-list-top"><div class="pd-list-title">设置</div></div><div class="pd-list-body">' + SETTINGS.map(function (s) {
        return '<button class="pd-row' + (r.section === s[0] ? ' active' : '') + '" style="height:48px" data-go="settings/' + s[0] + '">' +
          '<span style="color:' + (r.section === s[0] ? 'inherit' : 'var(--pd-text-2)') + '">' + icon(s[2], 20) + '</span><span class="pd-row-title">' + s[1] + '</span></button>';
      }).join('') + '</div>';
    }
  }

  /** sessionRows：会话列表（置顶在前，按更新时间排列） */
  function sessionRows(active) {
    var q = query.trim().toLowerCase();
    var list = sessions.slice().sort(function (a, b) {
      if (!!b.pinned !== !!a.pinned) { return b.pinned ? 1 : -1; }
      return (b.updatedAt || 0) - (a.updatedAt || 0);
    }).filter(function (s) { return !q || (title(s) + ' ' + (s.preview || '')).toLowerCase().indexOf(q) >= 0; });
    if (!list.length) { return '<div class="pd-empty">' + (q ? '没有找到' : '还没有会话') + '</div>'; }
    return list.map(function (s) {
      var n = unread[s.id] || 0;
      var waiting = s.state === 'awaiting';
      var sub = esc(s.preview || '');
      if (waiting) { sub = '<span class="pd-red">[待审批]</span> ' + esc((s.preview || '').replace(/^待确认：/, '')); }
      else if (s.state === 'running') { sub = '执行中' + (s.preview ? ' · ' + sub : '…'); }
      var mark = n ? '<span class="pd-badge">' + (n > 99 ? '99+' : n) + '</span>' : waiting ? '<span class="pd-dot"></span>' : '';
      return '<button class="pd-row' + (s.id === active ? ' active' : '') + (s.pinned && s.id !== active ? ' pinned' : '') + '" data-go="chat/' + encodeURIComponent(s.id) + '" data-sid="' + esc(s.id) + '">' +
        '<div class="pd-row-avatar">' + avatarHtml(s.kind) + mark + '</div>' +
        '<div class="pd-row-main"><div class="pd-row-line"><span class="pd-row-title">' + esc(title(s)) + '</span>' + (s.autoApprove ? '<span class="pd-tag-auto">免审批</span>' : '') +
        '<span class="pd-row-time">' + listTime(s.updatedAt) + '</span></div><div class="pd-row-sub">' + (sub || '&nbsp;') + '</div></div></button>';
    }).join('');
  }

  function renderMain() {
    var el = document.getElementById('main');
    if (!el) { return; }
    var r = route();
    if (r.page === 'chat') { renderChat(); }
    else if (r.page === 'phone') { el.innerHTML = phoneMain(); }
    else { el.innerHTML = settingsMain(r.section); if (r.section === 'security') { loadAudit(); } }
  }

  /* ---------- 聊天窗口 ---------- */

  function renderChat() {
    var el = document.getElementById('main');
    var r = route(), s = session(r.sid);
    if (!s) {
      el.innerHTML = '<div class="pd-empty-main">' + icon('message-circle', 88) + '</div>';
      return;
    }
    var composer = s.kind === 'terminal' ? '<div class="pd-sys" style="margin:16px">终端请在手机上使用</div>' :
      '<div class="pd-composer pd-drop"><div class="pd-tools">' +
      '<button class="pd-icon-btn" data-act="attach" title="发送文件" aria-label="发送文件">' + icon('folder', 20) + '</button>' +
      '<button class="pd-icon-btn" data-act="attach-image" title="发送图片" aria-label="发送图片">' + icon('image', 20) + '</button>' +
      (isAgent(s) ? '<button class="pd-icon-btn" data-act="interrupt" title="打断" aria-label="打断"' + (s.state === 'running' || s.state === 'awaiting' ? '' : ' disabled') + '>' + icon('square', 18) + '</button>' : '') +
      '</div><div class="pd-pending" id="pending"></div><textarea id="input" placeholder=""></textarea>' +
      '<div class="pd-composer-foot"><span class="pd-hint">Enter 发送，Shift + Enter 换行；可直接粘贴或拖入图片、文件</span>' +
      '<button class="pd-btn pd-btn-primary" id="send" data-act="send" disabled>发送</button></div>' +
      '<input type="file" id="file-any" multiple hidden><input type="file" id="file-img" accept="image/*" multiple hidden></div>';
    el.innerHTML = '<header class="pd-head" id="head"></header><div class="pd-msgs" id="msgs"><div class="pd-empty">正在加载…</div></div>' + composer;
    renderHead();
    renderPending();
    var draft = load('pd.draft', {})[s.id];
    var input = document.getElementById('input');
    if (input) { input.value = draft || ''; syncSend(); input.focus(); }
    loadLog(s.id).then(function () { if (route().sid === s.id) { renderMsgs(true); } }).catch(function (e) { toast(e.message); });
  }

  function renderHead() {
    var el = document.getElementById('head');
    var s = session(route().sid);
    if (!el || !s) { return; }
    var sub = [];
    if (isAgent(s)) {
      if (s.state === 'running') { sub.push('执行中'); } else if (s.state === 'awaiting') { sub.push('等待你确认'); }
      if (s.model) { sub.push(s.model); }
      if (s.autoApprove) { sub.push('免审批'); }
    } else if (s.kind === 'assistant') {
      var phones = host ? host.devices.filter(function (d) { return d.online && !d.revoked; }) : [];
      sub.push(phones.length ? '手机在线' : '手机不在线，消息会在手机上线后送达');
    }
    el.innerHTML = '<div class="pd-head-main"><div class="pd-head-title">' + esc(title(s)) + '</div>' + (sub.length ? '<div class="pd-head-sub">' + esc(sub.join(' · ')) + '</div>' : '') + '</div>' +
      '<div class="pd-head-acts"><button class="pd-icon-btn" data-act="chat-more" title="更多" aria-label="更多">' + icon('menu', 18) + '</button></div>';
  }

  /** renderMsgs：重绘消息；原本在底部或首次打开时滚到底部 */
  function renderMsgs(first) {
    var el = document.getElementById('msgs');
    var sid = route().sid, lg = logs[sid];
    if (!el || !lg || !lg.loaded) { return; }
    var bottom = first || el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    var items = buildItems(lg.events.length ? lg.events : [{ session: sid }]);
    var s = session(sid);
    var out = '', lastAt = 0;
    items.forEach(function (it) {
      if (it.at && it.at - lastAt > 5 * 60 * 1000) { out += '<div class="pd-msg-time">' + chatTime(it.at) + '</div>'; }
      if (it.at) { lastAt = it.at; }
      out += itemHtml(it, s);
    });
    el.innerHTML = out || '<div class="pd-empty">' + (s && s.kind === 'assistant' ? '发一条消息或拖入文件，手机上的文件传输助手马上就能收到' : '还没有消息') + '</div>';
    if (bottom) { el.scrollTop = el.scrollHeight; }
    Array.prototype.forEach.call(el.querySelectorAll('img'), function (img) {
      if (!img.complete) { img.addEventListener('load', function () { if (bottom) { el.scrollTop = el.scrollHeight; } }, { once: true }); }
    });
    if (unread[sid] && document.visibilityState === 'visible') { setUnread(sid, 0); renderList(); renderRail(); }
  }

  /** itemHtml：一条消息；「我」在右侧，Agent 与手机在左侧 */
  function itemHtml(it, s) {
    var mine, body, who;
    var agentKind = s ? s.kind : '';
    switch (it.t) {
      case 'user':
        mine = !it.phone;
        body = (it.delegate ? '<div class="pd-queued">@' + esc(AGENT[it.delegate] || it.delegate) + '</div>' : '') +
          '<div class="pd-bubble plain">' + esc(it.text) + '</div>' +
          (it.attachments.length ? '<div class="pd-attach">' + it.attachments.map(function (a) { return '<span>' + esc(a.split('/').pop()) + '</span>'; }).join('') + '</div>' : '') +
          (it.queued ? '<div class="pd-queued">排队中，Agent 空闲后发送</div>' : '');
        who = mine ? 'host' : 'phone';
        break;
      case 'host':
        mine = true; who = 'host';
        body = '<div class="pd-bubble plain">' + esc(it.text) + '</div>';
        break;
      case 'agent':
        mine = false; who = agentKind;
        body = '<div class="pd-bubble pd-md">' + md(it.text) + (it.streaming ? ' <span class="pd-muted">▍</span>' : '') + '</div>';
        break;
      case 'think':
        return '<div class="pd-msg" data-seq="' + it.seq + '"><div style="width:var(--pd-chat-avatar)"></div><div class="pd-msg-body"><details class="pd-think"><summary>' + icon('brain', 14) + (it.done ? '思考过程' : '正在思考…') + '</summary><pre>' + esc(it.text) + '</pre></details></div></div>';
      case 'tool':
        var input = it.input && typeof it.input.command === 'string' && Object.keys(it.input).length <= 2 ? it.input.command : JSON.stringify(it.input, null, 2);
        return '<div class="pd-msg" data-seq="' + it.seq + '"><div style="width:var(--pd-chat-avatar)"></div><div class="pd-msg-body"><details class="pd-tool' + (it.error ? ' err' : '') + '"><summary>' + icon(toolIcon(it.kind), 14) + '<span>' + esc(it.summary) + '</span>' +
          (it.done ? '' : icon('loader', 14)) + '</summary>' + (input && input !== '{}' ? '<pre>' + esc(input) + '</pre>' : '') + (it.output ? '<pre>' + esc(it.output) + '</pre>' : '') + '</details></div></div>';
      case 'approval':
        mine = false; who = agentKind;
        var detail = it.input && typeof it.input.command === 'string' ? it.input.command : (it.summary || JSON.stringify(it.input, null, 2));
        body = '<div class="pd-approval"><div class="pd-approval-title">' + icon('shield-alert', 16) + approvalTitle(it.kind) + '<span class="pd-muted" style="margin-left:auto;font-weight:400">' + esc(it.tool) + '</span></div>' +
          '<pre>' + esc(detail) + '</pre>' + (it.status ? '<div class="pd-approval-done">' + approvalStatus(it.status) + '</div>' :
          '<div class="pd-approval-acts"><button class="pd-btn pd-btn-primary" data-act="decide" data-id="' + esc(it.id) + '" data-action="allow">允许</button>' +
          '<button class="pd-btn" data-act="decide" data-id="' + esc(it.id) + '" data-action="deny">拒绝</button>' +
          '<button class="pd-link" data-act="decide" data-id="' + esc(it.id) + '" data-action="always">本会话总是允许此类操作</button></div>') + '</div>';
        break;
      case 'diff':
        mine = false; who = agentKind;
        body = '<div class="pd-card-msg"><div style="display:flex;align-items:center;gap:6px;margin-bottom:6px">' + icon('git-compare', 16) + '改动了 ' + it.files.length + ' 个文件</div>' +
          it.files.map(function (f) { return '<div class="pd-diff-row"><span>' + esc(f.path) + '</span><span class="pd-add">+' + (f.added || 0) + '</span><span class="pd-del">-' + (f.removed || 0) + '</span></div>'; }).join('') + '</div>';
        break;
      case 'sys':
        return '<div class="pd-sys' + (it.error ? ' err' : '') + '" data-seq="' + it.seq + '">' + esc(it.text) + (it.retryable ? ' <button class="pd-link" data-act="retry">重试</button>' : '') + '</div>';
      case 'file':
        mine = !it.up; who = mine ? 'host' : 'phone';
        body = fileHtml(it);
        break;
      default:
        return '';
    }
    return '<div class="pd-msg' + (mine ? ' mine' : '') + '" data-seq="' + it.seq + '">' + avatarHtml(who, true) + '<div class="pd-msg-body">' + body + '</div></div>';
  }

  function toolIcon(kind) {
    return { command: 'terminal', exec: 'terminal', bash: 'terminal', shell: 'terminal', read: 'file-text', write: 'pencil', edit: 'pencil', search: 'search', grep: 'search', glob: 'search', web: 'external-link', fetch: 'external-link', task: 'bot', agent: 'bot' }[kind] || 'wrench';
  }
  function approvalTitle(kind) {
    return { command: '要执行命令', exec: '要执行命令', edit: '要修改文件', write: '要写入文件', read: '要读取文件', web: '要访问网络', fetch: '要访问网络' }[kind] || '需要你确认';
  }
  function approvalStatus(st) {
    return { allowed: '已允许', allow: '已允许', always: '已允许（本会话总是允许）', denied: '已拒绝', deny: '已拒绝', expired: '已过期', canceled: '已取消' }[st] || '已处理';
  }

  /** fileHtml：文件消息；图片直接显示，其他文件显示卡片 */
  function fileHtml(it) {
    var src = '/admin/api/assistant/file?seq=' + it.seq;
    if (isImage(it.name)) {
      return '<button class="pd-img" data-act="preview" data-seq="' + it.seq + '" data-name="' + esc(it.name) + '"><img alt="' + esc(it.name) + '" src="' + src + '" loading="lazy"></button>';
    }
    var ext = (/\.(\w+)$/.exec(it.name || '') || ['', 'FILE'])[1].toUpperCase().slice(0, 4);
    var color = { PDF: '#F4524D', DOC: '#2B7BF0', DOCX: '#2B7BF0', XLS: '#1FA463', XLSX: '#1FA463', PPT: '#F07A2B', PPTX: '#F07A2B', ZIP: '#9B6DE0', MD: '#5A6475', TXT: '#5A6475' }[ext] || '#8A94A6';
    return '<div class="pd-file"><div class="pd-file-main"><div style="flex:1;min-width:0"><div class="pd-file-name">' + esc(it.name) + '</div><div class="pd-file-size">' + fmtSize(it.size) + '</div></div>' +
      '<div class="pd-file-ext" style="background:' + color + '">' + esc(ext) + '</div></div>' +
      '<div class="pd-file-foot"><button class="pd-link" data-act="file-open" data-seq="' + it.seq + '">打开</button><button class="pd-link" data-act="file-reveal" data-seq="' + it.seq + '">在文件夹中显示</button></div></div>';
  }

  function renderPending() {
    var el = document.getElementById('pending');
    if (!el) { return; }
    el.innerHTML = pending.map(function (p, i) {
      return '<span>' + esc(p.name) + '<button class="pd-icon-btn" style="width:18px;height:18px" data-act="unpend" data-i="' + i + '" aria-label="移除">' + icon('x', 12) + '</button></span>';
    }).join('');
    syncSend();
  }

  function syncSend() {
    var input = document.getElementById('input'), btn = document.getElementById('send');
    if (input && btn) { btn.disabled = !input.value.trim() && !pending.length; }
  }

  /**
   * send：发送当前输入
   *
   * 文件传输助手：文字以「电脑」身份发给手机；Agent 会话：与手机相同的发消息接口，附件路径随消息一起发送。
   */
  function send() {
    var s = session(route().sid);
    var input = document.getElementById('input');
    if (!s || !input) { return; }
    var text = input.value;
    if (!text.trim() && !pending.length) { return; }
    input.value = '';
    saveDraft(s.id, '');
    syncSend();
    var p;
    if (s.kind === 'assistant') {
      p = api('POST', '/admin/api/assistant/text', { text: text });
    } else {
      var att = pending.map(function (x) { return x.path; });
      pending = [];
      renderPending();
      p = api('POST', P + '/api/sessions/' + encodeURIComponent(s.id) + '/messages', { text: text, attachments: att, clientId: 'desk-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8) });
    }
    p.catch(function (e) { input.value = text; syncSend(); toast(e.message); });
  }

  function saveDraft(id, text) {
    var d = load('pd.draft', {});
    if (text) { d[id] = text; } else { delete d[id]; }
    save('pd.draft', d);
  }

  /** sendFiles：文件传输助手直接发给手机；Agent 会话先作为附件，随下一条消息发送 */
  function sendFiles(files) {
    var s = session(route().sid);
    if (!s || !files.length) { return; }
    if (s.kind === 'assistant') {
      toast('正在发送 ' + files.length + ' 个文件…');
      uploadForm('/admin/api/assistant/files', files).catch(function (e) { toast(e.message); });
      return;
    }
    uploadForm('/admin/api/sessions/' + encodeURIComponent(s.id) + '/attach', files).then(function (r) {
      (r.paths || []).forEach(function (p) { pending.push({ name: p.split('/').pop(), path: p }); });
      renderPending();
      var input = document.getElementById('input');
      if (input) { input.focus(); }
    }).catch(function (e) { toast(e.message); });
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
        var d = new Date();
        var ext = (f.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
        f = new File([f], '粘贴图片-' + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + '-' + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds()) + '.' + ext, { type: f.type });
      }
      out.push(f);
    });
    return out;
  }

  /** chatText：会话的全部文字（复制全部对话） */
  function chatText(sid) {
    var lg = logs[sid];
    if (!lg) { return ''; }
    return buildItems(lg.events).map(function (it) {
      switch (it.t) {
        case 'user': return (it.phone ? '手机：' : '我：') + it.text;
        case 'host': return '电脑：' + it.text;
        case 'agent': return it.text;
        case 'tool': return '[' + it.summary + ']' + (it.output ? '\n' + it.output : '');
        case 'sys': return it.text;
        case 'file': return '[文件] ' + it.name;
        default: return '';
      }
    }).filter(Boolean).join('\n\n');
  }

  /** itemText：一条消息的文字 */
  function itemText(sid, seq) {
    var lg = logs[sid];
    var it = lg && buildItems(lg.events).filter(function (x) { return x.seq === seq; })[0];
    if (!it) { return ''; }
    return it.text || it.output || it.name || '';
  }

  /** popMenu：在指定位置弹出菜单 */
  function popMenu(x, y, items) {
    closeMenu();
    var m = document.createElement('div');
    m.className = 'pd-menu';
    m.id = 'menu';
    m.innerHTML = items.map(function (it) {
      return it === '-' ? '<hr>' : '<button data-menu="' + it[0] + '"' + (it[2] ? ' class="danger"' : '') + '>' + (it[3] ? icon(it[3], 16) : '') + esc(it[1]) + '</button>';
    }).join('');
    document.body.appendChild(m);
    var w = m.offsetWidth, h = m.offsetHeight;
    m.style.left = Math.min(x, window.innerWidth - w - 8) + 'px';
    m.style.top = Math.min(y, window.innerHeight - h - 8) + 'px';
    return new Promise(function (resolve) { menuResolve = resolve; });
  }
  var menuResolve = null;
  function closeMenu() {
    var m = document.getElementById('menu');
    if (m) { m.remove(); }
    if (menuResolve) { var r = menuResolve; menuResolve = null; r(null); }
  }

  /* ---------- 手机文件 ---------- */
  var ph = { phones: null, dev: '', path: '', entries: [], root: '', error: '', loading: false };
  var TEXT_EXT = /\.(txt|md|markdown|json|js|ts|jsx|tsx|go|py|dart|java|kt|swift|c|h|cpp|rs|rb|php|sh|yaml|yml|toml|ini|conf|cfg|csv|log|xml|html|css|scss|sql|env)$/i;

  function phoneRows() {
    if (!ph.phones) { return '<div class="pd-empty">正在读取…</div>'; }
    if (!ph.phones.length) { return '<div class="pd-empty">还没有配对的手机</div>'; }
    return ph.phones.map(function (p) {
      return '<button class="pd-row' + (p.id === ph.dev ? ' active' : '') + '" data-act="phone-pick" data-id="' + esc(p.id) + '"><div class="pd-row-avatar">' + avatarHtml('phone') + '</div>' +
        '<div class="pd-row-main"><div class="pd-row-line"><span class="pd-row-title">' + esc(p.name) + '</span></div><div class="pd-row-sub">' + (p.online ? '在线' : '不在线') + '</div></div></button>';
    }).join('');
  }

  function phoneMain() {
    var ready = ph.dev && !ph.error;
    var head = '<header class="pd-head"><div class="pd-head-main"><div class="pd-head-title">手机文件</div><div class="pd-head-sub pd-mono">' + esc(ph.root || '管理手机上的工作空间') + '</div></div><div class="pd-head-acts">' +
      (ready ? '<button class="pd-btn" data-act="phone-root">' + icon('folder-search', 16) + '更换目录</button><button class="pd-btn" data-act="phone-mkdir">' + icon('folder-plus', 16) + '新建文件夹</button>' +
        '<button class="pd-btn pd-btn-primary" data-act="phone-upload">' + icon('upload', 16) + '上传</button>' : '') +
      '<button class="pd-icon-btn" data-act="phone-refresh" title="刷新" aria-label="刷新">' + icon('refresh-cw', 16) + '</button></div></header>';
    var body;
    if (!ph.phones) { body = '<div class="pd-empty">正在连接手机…</div>'; }
    else if (!ph.phones.length) { body = '<div class="pd-empty">还没有配对的手机</div>'; }
    else if (ph.error) { body = '<div class="pd-warn">' + icon('alert-triangle', 16) + '<div>' + esc(ph.error) + '</div></div>'; }
    else {
      var parts = ph.path ? ph.path.split('/') : [];
      var crumbs = '<button class="pd-link" data-act="phone-cd" data-path="">工作空间</button>' + parts.map(function (p, i) {
        return '<span>/</span><button class="pd-link" data-act="phone-cd" data-path="' + esc(parts.slice(0, i + 1).join('/')) + '">' + esc(p) + '</button>';
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
      body = '<div class="pd-crumbs">' + crumbs + (ph.loading ? '<em class="pd-muted" style="margin-left:8px;font-style:normal">加载中…</em>' : '') + '</div>' +
        '<div class="pd-card pd-drop">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th class="pd-hide-s" style="width:90px">大小</th><th class="pd-hide-s" style="width:140px">修改时间</th><th style="width:190px">操作</th></tr>' + rows + '</table>' :
          '<div class="pd-empty">这个文件夹是空的，把文件拖进来即可上传到手机</div>') + '</div>';
    }
    return head + '<div class="pd-page"><div class="pd-page-inner" style="max-width:none">' + body + '</div></div><input type="file" id="phone-file" multiple hidden>';
  }

  function phoneCall(op, args) { return api('POST', '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/call', { op: op, args: args || {} }); }
  function phoneFileUrl(p) { return '/admin/api/phone/' + encodeURIComponent(ph.dev) + '/file?path=' + encodeURIComponent(p); }
  function phoneParent(p) { var i = p.lastIndexOf('/'); return i < 0 ? '' : p.slice(0, i); }
  function phoneRedraw() { if (route().page === 'phone') { renderList(); renderMain(); } }

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

  function phoneUpload(files) {
    if (!files.length || !ph.dev) { return; }
    toast('正在上传 ' + files.length + ' 个文件到手机…');
    uploadForm('/admin/api/phone/' + encodeURIComponent(ph.dev) + '/upload?dir=' + encodeURIComponent(ph.path), files)
      .then(function () { toast('已上传到手机'); phoneLoad(); }).catch(function (er) { toast(er.message); });
  }

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
        '<textarea id="edit-text" class="pd-input" spellcheck="false"></textarea>' +
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

  /* ---------- 设置 ---------- */

  function settingsMain(section) {
    var name = (SETTINGS.filter(function (s) { return s[0] === section; })[0] || SETTINGS[0])[1];
    var body = host ? ({ overview: overviewView, workspaces: workspacesView, devices: devicesView, transfer: transferView, security: securityView, appearance: appearanceView, about: aboutView }[section] || overviewView)() : ['', ''];
    return '<header class="pd-head"><div class="pd-head-main"><div class="pd-head-title">' + name + '</div></div>' + (body[1] ? '<div class="pd-head-acts">' + body[1] + '</div>' : '') + '</header>' +
      '<div class="pd-page"><div class="pd-page-inner">' + (host ? body[0] : '<div class="pd-empty">正在读取…</div>') + '</div></div>';
  }

  function setting(ic, color, name, desc, id, on) {
    return '<div class="pd-setting">' + tileHtml(ic, color) + '<div class="pd-setting-text"><div>' + name + '</div><div class="pd-setting-desc">' + desc + '</div></div>' + toggle(id, on) + '</div>';
  }
  function toggle(id, on) { return '<label class="pd-switch"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '><span></span></label>'; }
  function fmtFp(fp) { return ((fp || '').toUpperCase().match(/.{1,4}/g) || []).join(' '); }
  function platformName(p) { return { ios: 'iOS', android: 'Android', web: '浏览器' }[p] || p || '未知'; }
  function ago(ms) {
    if (!ms) { return '从未在线'; }
    var d = (Date.now() - ms) / 1000;
    if (d < 60) { return '刚刚在线'; }
    if (d < 3600) { return Math.floor(d / 60) + ' 分钟前在线'; }
    if (d < 86400) { return Math.floor(d / 3600) + ' 小时前在线'; }
    return Math.floor(d / 86400) + ' 天前在线';
  }

  function overviewView() {
    if (!host) { return ['', '']; }
    var online = host.devices.filter(function (d) { return d.online; }).length;
    var paired = host.devices.filter(function (d) { return !d.revoked; }).length;
    var addrs = (host.addresses || []).map(function (a) {
      return '<div><span class="pd-mono">' + esc(a.ip) + '</span> <span class="pd-tag' + (a.kind === 'tailscale' ? '' : ' pd-tag-ok') + '">' + (a.kind === 'tailscale' ? 'Tailscale' : '局域网') + '</span></div>';
    }).join('') || '<span class="pd-muted">未检测到局域网或 Tailscale 地址</span>';
    var agents = (host.agents || []).map(function (a) {
      return '<div class="pd-agent' + (a.installed ? '' : ' off') + '">' + avatarHtml(a.kind) + '<div style="min-width:0"><div>' + esc(a.label) + '</div><div class="pd-muted" style="font-size:12px">' + (a.installed ? esc(a.version || '已安装') : '未安装') + '</div></div></div>';
    }).join('');
    return ['<div class="pd-hero"><div class="pd-hero-icon">' + icon('monitor', 26) + '</div><div><div class="pd-hero-name">' + esc(host.host.name) + '</div><div class="pd-hero-state"><i></i>运行中 · 端口 ' + host.host.port + '</div></div>' +
      '<div class="pd-stats"><div><b>' + online + '</b><span>在线手机</span></div><div><b>' + paired + '</b><span>已配对</span></div><div><b>' + host.workspaces.length + '</b><span>工作区</span></div></div></div>' +
      '<div class="pd-h2">连接</div><div class="pd-card"><dl class="pd-kv"><dt>访问地址</dt><dd>' + addrs + '</dd><dt>证书指纹</dt><dd class="pd-mono" style="font-size:12px">' + esc(fmtFp(host.host.fingerprint)) + '</dd></dl></div>' +
      '<div class="pd-h2">AI 编程工具</div><div class="pd-agents">' + agents + '</div>',
      '<button class="pd-btn pd-btn-primary" data-act="pair">' + icon('qr-code', 16) + '配对新手机</button>'];
  }

  function workspacesView() {
    var rows = host.workspaces.map(function (w) {
      return '<tr><td><div class="pd-name">' + tileHtml('folder', 'var(--pd-tile-blue)') + esc(w.name) + '</div></td><td class="pd-path">' + esc(w.rootPath) + '</td>' +
        '<td><span class="pd-tag' + (w.readOnly ? '' : ' pd-tag-ok') + '">' + (w.readOnly ? '只读' : '读写') + '</span></td>' +
        '<td><div class="pd-actions"><button class="pd-link" data-act="ws-edit" data-id="' + esc(w.id) + '">编辑</button><button class="pd-link pd-link-danger" data-act="ws-del" data-id="' + esc(w.id) + '">删除</button></div></td></tr>';
    }).join('');
    var warns = host.workspaces.filter(function (w) { return w.warning; }).map(function (w) { return '<div class="pd-warn">' + icon('alert-triangle', 16) + '<div>' + esc(w.warning) + '</div></div>'; }).join('');
    return ['<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th>路径</th><th style="width:70px">权限</th><th style="width:100px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有工作区</div>') + '</div>' + warns,
      '<button class="pd-btn pd-btn-primary" data-act="ws-add">' + icon('plus', 16) + '添加工作区</button>'];
  }

  function devicesView() {
    var rows = host.devices.map(function (d) {
      var status = d.revoked ? '<span class="pd-tag">已吊销</span>' : d.online ? '<span class="pd-tag pd-tag-ok">在线</span>' : '<span class="pd-muted">' + ago(d.lastSeen) + '</span>';
      var act = d.revoked ? '<button class="pd-link pd-link-danger" data-act="dev-remove" data-id="' + esc(d.id) + '" data-name="' + esc(d.name) + '">删除</button>'
        : '<button class="pd-link pd-link-danger" data-act="dev-revoke" data-id="' + esc(d.id) + '" data-name="' + esc(d.name) + '">吊销</button>';
      return '<tr><td><div class="pd-name">' + tileHtml('smartphone', d.revoked ? 'var(--pd-tile-ink)' : 'var(--pd-tile-teal)') + esc(d.name) + '</div></td><td class="pd-muted pd-hide-s">' + esc(platformName(d.platform)) + '</td><td>' + status + '</td><td>' + act + '</td></tr>';
    }).join('');
    return ['<div class="pd-card">' + (rows ? '<table class="pd-table"><tr><th>名称</th><th class="pd-hide-s">系统</th><th>状态</th><th style="width:70px">操作</th></tr>' + rows + '</table>' : '<div class="pd-empty">还没有配对的手机</div>') + '</div>' +
      '<div class="pd-muted" style="font-size:12px;margin:10px 2px">吊销后该手机需要重新扫码配对；已吊销的设备可以从列表中删除。</div>',
      '<button class="pd-btn pd-btn-primary" data-act="pair">' + icon('qr-code', 16) + '配对新手机</button>'];
  }

  function transferView() {
    var c = host.config, n = c.notify || {};
    return ['<div class="pd-h2">收件目录</div><div class="pd-card"><div class="pd-form-grid" style="grid-template-columns:1fr">' +
      '<div class="pd-form-row"><div class="pd-field"><label for="inbox">两端互传的文件存到这里的日期文件夹</label><input class="pd-input pd-mono" id="inbox" value="' + esc(c.transfer.inboxDir) + '"></div>' +
      '<button class="pd-btn" data-act="open-inbox" aria-label="打开收件目录">' + icon('folder-open', 16) + '</button></div></div>' +
      '<div class="pd-setting">' + tileHtml('pause', 'var(--pd-tile-amber)') + '<div class="pd-setting-text"><div>暂停所有传输</div><div class="pd-setting-desc">暂停期间手机会自动等待，恢复后继续</div></div>' + toggle('pause-all', host.transfersPaused) + '</div></div>' +
      '<div class="pd-h2">后台通知</div><div class="pd-card"><div class="pd-form-grid">' +
      '<div class="pd-field"><label for="nkind">推送方式</label><select class="pd-input" id="nkind"><option value="">不推送</option><option value="ntfy"' + (n.kind === 'ntfy' ? ' selected' : '') + '>ntfy</option><option value="bark"' + (n.kind === 'bark' ? ' selected' : '') + '>Bark</option></select></div>' +
      '<div class="pd-field"><label for="nurl">服务地址</label><input class="pd-input" id="nurl" placeholder="https://ntfy.sh" value="' + esc(n.url) + '"></div>' +
      '<div class="pd-field"><label for="ntopic">主题或设备密钥</label><input class="pd-input" id="ntopic" value="' + esc(n.topic) + '"></div></div></div>' +
      '<div class="pd-savebar"><button class="pd-btn pd-btn-primary" data-act="save-transfer">保存</button></div>', ''];
  }

  function securityView() {
    var f = host.config.features;
    return ['<div class="pd-card">' +
      setting('bot', 'var(--pd-tile-indigo)', 'Agent 会话', '向电脑上的 AI 编程工具发送提示词', 'f-agents', f.agents) +
      setting('terminal', 'var(--pd-tile-ink)', '终端', '手机可在电脑上执行任意命令，每次进入需验证指纹或面容', 'f-terminal', f.terminal) +
      setting('pencil', 'var(--pd-tile-amber)', '文件编辑', '可保存、重命名、移动和删除工作区文件', 'f-fileEdit', f.fileEdit) +
      '<div class="pd-setting">' + tileHtml('clock', 'var(--pd-tile-blue)') + '<div class="pd-setting-text"><div>终端空闲自动结束</div><div class="pd-setting-desc">没有输入也没有连接超过设定小时数后结束</div></div>' +
      '<input class="pd-input" id="idle" type="number" min="1" max="720" style="width:80px" value="' + host.config.terminalIdleHours + '" aria-label="小时"></div></div>' +
      '<div class="pd-h2">操作记录</div><div class="pd-card" id="audit"><div class="pd-empty">正在加载…</div></div>', ''];
  }

  function appearanceView() {
    var t = load('pd.theme', 'system');
    return ['<div class="pd-card"><div class="pd-setting">' + tileHtml('palette', 'var(--pd-tile-indigo)') + '<div class="pd-setting-text"><div>外观</div><div class="pd-setting-desc">浅色、深色或跟随系统</div></div>' +
      '<div class="pd-seg">' + [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']].map(function (x) {
        return '<button class="' + (t === x[0] ? 'active' : '') + '" data-act="theme" data-theme="' + x[0] + '">' + x[1] + '</button>';
      }).join('') + '</div></div></div>', ''];
  }

  function aboutView() {
    return ['<div class="pd-card"><dl class="pd-kv"><dt>版本</dt><dd>' + esc(host.host.version) + '</dd><dt>数据目录</dt><dd class="pd-mono" style="font-size:12px">' + esc(host.dataDir) + '</dd></dl></div>' +
      '<div class="pd-savebar" style="justify-content:flex-start"><button class="pd-btn pd-btn-danger" data-act="quit">' + icon('log-out', 16) + '退出服务</button></div>', ''];
  }

  function loadAudit() {
    api('GET', '/admin/api/audit').then(function (list) {
      var el = document.getElementById('audit');
      if (!el) { return; }
      var names = { desktop: '电脑' };
      host.devices.forEach(function (d) { names[d.id] = d.name; });
      if (!list.length) { el.innerHTML = '<div class="pd-empty">暂无记录</div>'; return; }
      el.innerHTML = '<table class="pd-table" style="font-size:12px"><tr><th>时间</th><th>设备</th><th>操作</th><th class="pd-hide-s">详情</th></tr>' + list.slice(0, 100).map(function (a) {
        var detail = JSON.stringify(a.detail) || '';
        if (detail.length > 160) { detail = detail.slice(0, 160) + '…'; }
        return '<tr><td class="pd-nowrap">' + fmtTime(a.createdAt) + '</td><td class="pd-nowrap">' + esc(names[a.deviceId] || '电脑') + '</td><td class="pd-nowrap">' + esc(a.action) + '</td><td class="pd-hide-s pd-path">' + esc(detail) + '</td></tr>';
      }).join('') + '</table>';
    }).catch(function () {});
  }

  /* ---------- 配对 ---------- */
  function pairBody() {
    if (!pairInfo) { return '<div class="pd-pair-body"><div class="pd-pair-title">配对新手机</div><div class="pd-muted">正在生成配对码…</div></div>'; }
    var addr = (pairInfo.addresses || [])[0] || '未检测到局域网地址';
    return '<div class="pd-pair-body"><div class="pd-pair-title">配对新手机</div>' +
      '<div class="pd-qr"><img alt="配对二维码" src="' + esc(pairInfo.qr) + '"></div><div class="pd-muted" id="pair-left">' + countdownText() + '</div>' +
      '<div class="pd-steps"><div class="pd-step"><div class="pd-stepnum">1</div><div>在手机上打开 PocketDesk，点消息页右上角「+ → 扫一扫」</div></div>' +
      '<div class="pd-step"><div class="pd-stepnum">2</div><div>对准上方二维码扫描，或手动输入下方配对码</div></div>' +
      '<div class="pd-step"><div class="pd-stepnum">3</div><div>在电脑上点击「允许」完成配对</div></div></div>' +
      '<div class="pd-codebox"><div><div class="pd-muted" style="font-size:11px">手动配对码</div><div class="pd-code-big">' + esc(pairInfo.code) + '</div></div>' +
      '<div class="pd-muted" style="font-size:11px;text-align:right">' + esc(pairInfo.hostName) + '<br><span class="pd-mono">' + esc(addr) + '</span></div></div>' +
      '<div style="display:flex;gap:8px"><button class="pd-btn" data-act="pair-refresh">换一个配对码</button><button class="pd-btn" data-act="pair-close">关闭</button></div></div>';
  }
  function countdownText() {
    if (!pairInfo) { return ''; }
    var left = Math.max(0, Math.floor((pairInfo.expiresAt - Date.now()) / 1000));
    if (left === 0) { return '配对码已过期，请点「换一个配对码」'; }
    return '配对码 5 分钟内有效，剩余 <span class="pd-countdown">' + pad(Math.floor(left / 60)) + ':' + pad(left % 60) + '</span>';
  }
  /** startPair：生成配对码；主窗口里以弹窗显示，独立配对窗口占满 */
  function startPair() {
    pairInfo = null;
    showPair();
    api('POST', '/admin/api/pair/start').then(function (p) {
      pairInfo = p;
      showPair();
      clearInterval(pairTimer);
      pairTimer = setInterval(function () { var el = document.getElementById('pair-left'); if (el) { el.innerHTML = countdownText(); } }, 1000);
    }).catch(function (e) { toast(e.message); });
  }
  function showPair() {
    if (route().page === 'pair') { render(); return; }
    modalRoot.innerHTML = '<div class="pd-scrim"><div class="pd-dialog" style="width:460px;background:var(--pd-chat)">' + pairBody() + '</div></div>';
  }
  function closePair() {
    api('POST', '/admin/api/pair/cancel').catch(function () {});
    clearInterval(pairTimer);
    pairInfo = null;
    if (route().page === 'pair') { location.hash = 'settings/devices'; } else { closeModal(); }
  }

  /* ---------- 弹窗 ---------- */
  function modal(t, body, foot) {
    modalRoot.innerHTML = '<div class="pd-scrim"><div class="pd-dialog" role="dialog" aria-modal="true" aria-label="' + esc(t) + '">' +
      '<div class="pd-dialog-head"><div class="pd-dialog-title">' + esc(t) + '</div><button class="pd-icon-btn" data-act="modal-close" aria-label="关闭">' + icon('x', 18) + '</button></div>' +
      '<div class="pd-modal-body">' + body + '</div><div class="pd-dialog-foot">' + foot + '</div></div></div>';
    var first = modalRoot.querySelector('input,button.pd-btn-primary');
    if (first) { first.focus(); }
  }
  function closeModal() { modalRoot.innerHTML = ''; }
  function confirmBox(t, text, okLabel, onOk) {
    modal(t, '<div>' + text + '</div>', '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-danger" id="confirm-ok">' + okLabel + '</button>');
    document.getElementById('confirm-ok').onclick = function () { closeModal(); onOk(); };
  }
  function imagePreview(t, src, actions) {
    modalRoot.innerHTML = '<div class="pd-scrim" data-act="modal-close"><div class="pd-preview" role="dialog" aria-modal="true" aria-label="' + esc(t) + '">' +
      '<img alt="' + esc(t) + '" src="' + src + '"><div class="pd-preview-bar"><span>' + esc(t) + '</span><div class="pd-actions">' + actions +
      '<button class="pd-icon-btn" data-act="modal-close" aria-label="关闭">' + icon('x', 18) + '</button></div></div></div></div>';
  }
  function workspaceForm(w) {
    w = w || { id: '', name: '', rootPath: '', readOnly: false };
    modal(w.id ? '编辑工作区' : '添加工作区',
      '<div class="pd-field"><label for="wname">名称</label><input class="pd-input" id="wname" value="' + esc(w.name) + '"></div>' +
      '<div class="pd-field"><label for="wpath">文件夹路径</label><input class="pd-input pd-mono" id="wpath" value="' + esc(w.rootPath) + '" placeholder="/Users/me/Projects/demo"></div>' +
      '<label class="pd-check"><input type="checkbox" id="wro"' + (w.readOnly ? ' checked' : '') + '>只读（手机上不能修改）</label>',
      '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="ws-save" data-id="' + esc(w.id) + '">保存</button>');
  }

  /** newSession：选择 Agent 与工作区后新建会话（与手机端相同的接口） */
  function newSession(kind, auto) {
    api('GET', P + '/api/ws').then(function (list) {
      var ws = (list || []).filter(function (w) { return !w.system; });
      if (!ws.length) { toast('请先在设置里添加工作区'); return; }
      modal('新建 ' + AGENT[kind] + (auto ? ' 免审批' : '') + ' 会话',
        '<div class="pd-muted" style="font-size:12px">选择工作区</div><div class="pd-pick-list">' + ws.map(function (w, i) {
          return '<button class="pd-pick-row' + (i === 0 ? ' active' : '') + '" data-act="ws-pick" data-id="' + esc(w.id) + '">' + icon(w.isDefault ? 'folder-open' : 'folder', 16) +
            '<span style="flex:1;min-width:0"><div>' + esc(w.name) + (w.isDefault ? ' <span class="pd-muted" style="font-size:12px">默认</span>' : '') + '</div><div class="pd-path">' + esc(w.rootPath) + '</div></span></button>';
        }).join('') + '</div>',
        '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="create" data-kind="' + kind + '" data-auto="' + (auto ? 1 : 0) + '">新建</button>');
    }).catch(function (e) { toast(e.message); });
  }

  /* ---------- 电脑端状态与配对请求 ---------- */
  function loadHost() {
    return api('GET', '/admin/api/state').then(function (s) {
      var first = !host;
      host = s;
      checkRequests();
      var r = route();
      // 首次读到状态时绘制设置页；之后只刷新纯展示的分区，避免冲掉正在编辑的输入
      if (r.page === 'settings' && !modalRoot.innerHTML && (first || r.section === 'overview' || r.section === 'devices')) { renderMain(); }
      if (r.page === 'chat') { renderHead(); }
      if (!document.getElementById('rail') && r.page !== 'pair') { render(); }
    }).catch(function () {});
  }

  /** checkRequests：有手机请求配对时弹窗确认 */
  function checkRequests() {
    (host.pending || []).forEach(function (req) {
      if (shownRequests[req.id]) { return; }
      shownRequests[req.id] = true;
      modal('配对请求', '<div style="display:flex;gap:12px;align-items:center">' + avatarHtml('phone') +
        '<div>是否允许「' + esc(req.name) + '」配对？<div class="pd-muted" style="font-size:12px">允许后这台手机可以访问已授权的工作区并控制 AI 编程工具</div></div></div>',
        '<button class="pd-btn" data-act="req" data-id="' + esc(req.id) + '" data-allow="0">拒绝</button><button class="pd-btn pd-btn-primary" data-act="req" data-id="' + esc(req.id) + '" data-allow="1">允许</button>');
    });
  }

  /* ---------- 事件 ---------- */
  document.addEventListener('click', function (e) {
    var mi = e.target.closest('[data-menu]');
    if (mi) {
      var r0 = menuResolve;
      menuResolve = null;
      closeMenu();
      if (r0) { r0(mi.dataset.menu); }
      return;
    }
    closeMenu();
    var t = e.target.closest('[data-go],[data-act]');
    if (!t) { return; }
    if (t.dataset.go) {
      location.hash = t.dataset.go;
      return;
    }
    var act = t.dataset.act, id = t.dataset.id, sid = route().sid;
    switch (act) {
      case 'modal-close':
        if (t.classList.contains('pd-scrim') && e.target !== t) { return; }
        closeModal();
        break;
      case 'pair': startPair(); break;
      case 'pair-refresh': startPair(); break;
      case 'pair-close': closePair(); break;
      case 'req':
        api('POST', '/admin/api/pair/' + encodeURIComponent(id), { allow: t.dataset.allow === '1' }).then(function () {
          closeModal();
          toast(t.dataset.allow === '1' ? '已允许配对' : '已拒绝');
          if (t.dataset.allow === '1' && pairInfo) { clearInterval(pairTimer); pairInfo = null; }
          setTimeout(loadHost, 600);
        }).catch(function (er) { closeModal(); toast(er.message); });
        break;
      // 聊天
      case 'send': send(); break;
      case 'attach': document.getElementById('file-any').click(); break;
      case 'attach-image': document.getElementById('file-img').click(); break;
      case 'unpend': pending.splice(+t.dataset.i, 1); renderPending(); break;
      case 'interrupt':
        api('POST', P + '/api/sessions/' + encodeURIComponent(sid) + '/interrupt').then(function () { toast('已打断'); }).catch(function (er) { toast(er.message); });
        break;
      case 'retry':
        api('POST', P + '/api/sessions/' + encodeURIComponent(sid) + '/retry').catch(function (er) { toast(er.message); });
        break;
      case 'decide':
        api('POST', P + '/api/approvals/' + encodeURIComponent(id), { action: t.dataset.action }).catch(function (er) { toast(er.message); });
        break;
      case 'copy-code':
        copyText(t.closest('.pd-code').querySelector('code').textContent);
        break;
      case 'preview':
        imagePreview(t.dataset.name, '/admin/api/assistant/file?seq=' + t.dataset.seq,
          '<button class="pd-btn" data-act="file-open" data-seq="' + t.dataset.seq + '">' + icon('external-link', 16) + '打开</button>' +
          '<button class="pd-btn" data-act="file-reveal" data-seq="' + t.dataset.seq + '">' + icon('folder-open', 16) + '在文件夹中显示</button>');
        break;
      case 'file-open':
      case 'file-reveal':
        api('POST', '/admin/api/assistant/open', { seq: +t.dataset.seq, reveal: act === 'file-reveal' }).catch(function (er) { toast(er.message); });
        break;
      case 'chat-more':
        var rect = t.getBoundingClientRect(), s = session(sid);
        popMenu(rect.right - 170, rect.bottom + 4, [['copy-all', '复制全部对话', false, 'copy'], ['pin', s && s.pinned ? '取消置顶' : '置顶聊天', false, 'pin']]).then(function (k) { chatMenu(k, sid); });
        break;
      case 'new':
        var rc = t.getBoundingClientRect();
        var installed = (host && host.agents || []).filter(function (a) { return a.installed; }).map(function (a) { return a.kind; });
        if (!installed.length) { installed = Object.keys(AGENT); }
        var items = installed.map(function (k) { return ['new:' + k, '新建 ' + AGENT[k] + ' 会话', false, 'message-circle']; });
        installed.filter(function (k) { return k === 'claude' || k === 'codex'; }).forEach(function (k) { items.push(['auto:' + k, AGENT[k] + ' 免审批', false, 'shield-alert']); });
        items.push('-', ['pair', '配对新手机', false, 'qr-code']);
        popMenu(rc.left, rc.bottom + 4, items).then(function (k) {
          if (!k) { return; }
          if (k === 'pair') { startPair(); return; }
          var p = k.split(':');
          newSession(p[1], p[0] === 'auto');
        });
        break;
      case 'ws-pick':
        Array.prototype.forEach.call(modalRoot.querySelectorAll('[data-act="ws-pick"]'), function (b) { b.classList.toggle('active', b === t); });
        break;
      case 'create':
        var pick = modalRoot.querySelector('[data-act="ws-pick"].active');
        api('POST', P + '/api/sessions', { kind: t.dataset.kind, workspaceId: pick.dataset.id, cwd: '.', autoApprove: t.dataset.auto === '1' }).then(function (s2) {
          closeModal();
          sessions.push(s2);
          location.hash = 'chat/' + encodeURIComponent(s2.id);
        }).catch(function (er) { toast(er.message); });
        break;
      // 手机文件
      case 'phone-pick': ph.dev = id; ph.path = ''; phoneLoad(); break;
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
        var f = new File([document.getElementById('edit-text').value], p.split('/').pop(), { type: 'text/plain' });
        uploadForm('/admin/api/phone/' + encodeURIComponent(ph.dev) + '/upload?overwrite=1&dir=' + encodeURIComponent(phoneParent(p)), [f])
          .then(function () { closeModal(); toast('已保存到手机'); phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      case 'phone-root': phoneRootPicker(''); break;
      case 'phone-browse': phoneRootPicker(t.dataset.path); break;
      case 'phone-setroot':
        phoneCall('setRoot', { path: t.dataset.path }).then(function () { closeModal(); toast('已更换手机工作空间'); ph.path = ''; phoneLoad(); }).catch(function (er) { toast(er.message); });
        break;
      // 设置
      case 'theme': save('pd.theme', t.dataset.theme); applyTheme(); renderMain(); break;
      case 'open-inbox': api('POST', '/admin/api/open', { which: 'inbox' }).catch(function (er) { toast(er.message); }); break;
      case 'save-transfer':
        api('PATCH', '/admin/api/config', {
          inboxDir: document.getElementById('inbox').value.trim(),
          notify: { kind: document.getElementById('nkind').value, url: document.getElementById('nurl').value.trim(), topic: document.getElementById('ntopic').value.trim() }
        }).then(function () { toast('已保存'); loadHost(); }).catch(function (er) { toast(er.message); });
        break;
      case 'quit':
        confirmBox('退出服务', '退出后手机将无法连接这台电脑，直到服务再次启动。', '退出', function () {
          api('POST', '/admin/api/quit').then(function () { app.innerHTML = '<div class="pd-center"><div class="pd-muted">服务已退出，可以关闭此窗口</div></div>'; });
        });
        break;
      case 'ws-add': workspaceForm(); break;
      case 'ws-edit': workspaceForm(host.workspaces.filter(function (w) { return w.id === id; })[0]); break;
      case 'ws-save':
        api('POST', '/admin/api/workspaces', { id: id, name: document.getElementById('wname').value, rootPath: document.getElementById('wpath').value, readOnly: document.getElementById('wro').checked })
          .then(function () { closeModal(); toast('已保存'); loadHost().then(renderMain); }).catch(function (er) { toast(er.message); });
        break;
      case 'ws-del':
        confirmBox('删除工作区', '只移除这个工作区的配置，电脑上的文件不会被删除。', '删除', function () {
          api('DELETE', '/admin/api/workspaces/' + encodeURIComponent(id)).then(function () { toast('已删除'); loadHost().then(renderMain); }).catch(function (er) { toast(er.message); });
        });
        break;
      case 'dev-revoke':
        confirmBox('吊销设备', '吊销后「' + esc(t.dataset.name) + '」将立即断开，需要重新扫码配对。', '吊销', function () {
          api('DELETE', '/admin/api/devices/' + encodeURIComponent(id)).then(function () { toast('已吊销'); loadHost().then(renderMain); }).catch(function (er) { toast(er.message); });
        });
        break;
      case 'dev-remove':
        confirmBox('删除设备', '从列表中删除「' + esc(t.dataset.name) + '」的记录。', '删除', function () {
          api('POST', '/admin/api/devices/' + encodeURIComponent(id) + '/remove').then(function () { toast('已删除'); loadHost().then(renderMain); }).catch(function (er) { toast(er.message); });
        });
        break;
    }
  });

  /** chatMenu：聊天窗口右上角菜单 */
  function chatMenu(k, sid) {
    var s = session(sid);
    if (k === 'copy-all') { copyText(chatText(sid)); }
    if (k === 'pin' && s) {
      api('PATCH', P + '/api/sessions/' + encodeURIComponent(sid), { pinned: !s.pinned }).then(function (s2) { s.pinned = s2.pinned; renderList(); }).catch(function (er) { toast(er.message); });
    }
  }

  // 右键：消息可复制、删除、复制全部；会话可置顶、标为已读或未读
  document.addEventListener('contextmenu', function (e) {
    var msg = e.target.closest('.pd-msg,.pd-sys');
    var row = e.target.closest('.pd-row[data-sid]');
    if (!msg && !row) { return; }
    e.preventDefault();
    if (msg) {
      var sid = route().sid, seq = +msg.dataset.seq;
      var sel = String(window.getSelection() || '');
      var items = [];
      if (sel) { items.push(['copy-sel', '复制选中的文字', false, 'copy']); }
      items.push(['copy', '复制', false, 'copy'], ['copy-all', '复制全部对话', false, 'copy'], '-', ['delete', '删除', true, 'trash']);
      popMenu(e.clientX, e.clientY, items).then(function (k) {
        if (k === 'copy-sel') { copyText(sel); }
        if (k === 'copy') { copyText(itemText(sid, seq)); }
        if (k === 'copy-all') { copyText(chatText(sid)); }
        if (k === 'delete') {
          (hidden[sid] = hidden[sid] || []).push(seq);
          save('pd.hidden', hidden);
          renderMsgs(false);
        }
      });
      return;
    }
    var s = session(row.dataset.sid);
    popMenu(e.clientX, e.clientY, [['pin', s.pinned ? '取消置顶' : '置顶', false, 'pin'], [unread[s.id] ? 'read' : 'unread', unread[s.id] ? '标为已读' : '标为未读', false, 'message-circle']]).then(function (k) {
      if (k === 'pin') { chatMenu('pin', s.id); }
      if (k === 'read') { setUnread(s.id, 0); renderList(); renderRail(); }
      if (k === 'unread') { setUnread(s.id, 1); renderList(); renderRail(); }
    });
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') { closeMenu(); if (modalRoot.innerHTML) { if (pairInfo && route().page !== 'pair') { closePair(); } else { closeModal(); } } }
    if (e.target.id === 'input' && e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send();
    }
  });
  document.addEventListener('input', function (e) {
    if (e.target.id === 'input') { syncSend(); saveDraft(route().sid, e.target.value); }
    if (e.target.id === 'search') { query = e.target.value; renderList(); }
  });

  document.addEventListener('change', function (e) {
    var t = e.target;
    if (t.id === 'file-any' || t.id === 'file-img' || t.id === 'phone-file') {
      var files = Array.prototype.slice.call(t.files || []);
      t.value = '';
      if (t.id === 'phone-file') { phoneUpload(files); } else { sendFiles(files); }
      return;
    }
    if (t.id === 'pause-all') { api('POST', '/admin/api/transfers/pause', { paused: t.checked }).then(loadHost); }
    else if (/^f-/.test(t.id)) {
      var f = Object.assign({}, host.config.features);
      f[t.id.slice(2)] = t.checked;
      api('PATCH', '/admin/api/config', { features: f }).then(function () { toast('已更新'); loadHost(); }).catch(function (er) { toast(er.message); });
    } else if (t.id === 'idle') {
      var v = parseInt(t.value, 10);
      if (v > 0) { api('PATCH', '/admin/api/config', { terminalIdleHours: v }).then(function () { toast('已更新'); }); }
    }
  });

  // 粘贴与拖入：聊天中发送（Agent 会话作为附件），手机文件中上传到当前目录
  function dropTarget() {
    var r = route();
    if (modalRoot.innerHTML) { return ''; }
    if (r.page === 'chat' && session(r.sid) && session(r.sid).kind !== 'terminal') { return 'chat'; }
    if (r.page === 'phone' && ph.dev && !ph.error) { return 'phone'; }
    return '';
  }
  document.addEventListener('paste', function (e) {
    var tgt = dropTarget();
    if (!tgt) { return; }
    var files = pastedFiles(e);
    if (!files.length) { return; }
    e.preventDefault();
    if (tgt === 'chat') { sendFiles(files); } else { phoneUpload(files); }
  });
  document.addEventListener('dragover', function (e) {
    if (!dropTarget()) { return; }
    e.preventDefault();
    app.classList.add('pd-dragging');
  });
  document.addEventListener('dragleave', function (e) { if (!e.relatedTarget) { app.classList.remove('pd-dragging'); } });
  document.addEventListener('drop', function (e) {
    app.classList.remove('pd-dragging');
    var tgt = dropTarget();
    if (!tgt) { return; }
    e.preventDefault();
    var files = Array.prototype.slice.call((e.dataTransfer && e.dataTransfer.files) || []);
    if (tgt === 'chat') { sendFiles(files); } else { phoneUpload(files); }
  });
  document.addEventListener('visibilitychange', function () { if (document.visibilityState === 'visible' && route().page === 'chat') { renderMsgs(false); } });

  var lastPage = '';
  window.addEventListener('hashchange', function () {
    var r = route();
    closeMenu();
    if (modalRoot.innerHTML && !modalRoot.querySelector('[data-act="req"]') && !pairInfo) { closeModal(); }
    if (r.page === 'pair') { startPair(); return; }
    pending = [];
    // 同一页面内切换会话只刷新列表与聊天，保留图标栏
    if (lastPage === r.page && document.getElementById('rail')) {
      renderRail();
      renderList();
      renderMain();
    } else {
      render();
    }
    lastPage = r.page;
    if (r.page === 'phone') { phoneLoad(); }
  });

  /* ---------- 启动 ---------- */
  if (!location.hash) { history.replaceState(null, '', '#chat'); }
  var r0 = route();
  lastPage = r0.page;
  render();
  if (r0.page === 'pair') { startPair(); }
  loadHost().then(function () {
    loadSessions().then(function () {
      if (route().page === 'chat' && !route().sid) {
        var first = sessions.filter(function (s) { return s.kind === 'assistant'; })[0];
        if (first) { location.hash = 'chat/' + encodeURIComponent(first.id); }
      } else if (route().page === 'chat') { renderMain(); }
    });
  });
  if (r0.page === 'phone') { phoneLoad(); }
  connect();
  setUnread('', 0);
  // 电脑端状态（在线手机、配对请求）每 3 秒刷新
  setInterval(loadHost, 3000);
})();
