/**
 * 桌面端扩展：八套界面风格与头像设置、通讯录（AI 好友与预设助手）、工具箱（剪切板、收藏夹、提示词）、
 * 完整的新建会话对话框、可缩放的看图窗口。由 app.js 初始化后调用，数据与手机端共用电脑上的同一份资料库。
 */
(function () {
  'use strict';

  var X = window.PDX = {};
  var c = null;
  var P = '/admin/p';

  /** init：接收主界面提供的工具函数 */
  X.init = function (ctx) { c = ctx; X.applyStyle(); };

  function esc(s) { return c.esc(s); }
  function icon(n, s) { return c.icon(n, s); }

  /* ---------- 风格 ---------- */

  X.STYLES = [
    ['wechat', '微信', '绿色气泡，通栏列表'],
    ['codex', 'Codex', '克制的单色，细描边，像开发工具'],
    ['qq', 'QQ', '蓝色侧栏，圆形头像，圆润气泡'],
    ['claude', 'Claude', '米白纸面，赤陶强调色，衬线标题'],
    ['glacier', '冰川玻璃', '渐变光斑，半透明玻璃，大圆角'],
    ['aurora', '极光', '夜空底色，紫青粉渐变光晕'],
    ['brutal', '新粗野', '粗黑描边，硬阴影，高饱和色块'],
    ['paper', '纸刊', '暖白纸张，衬线标题，朱红点缀']
  ];

  /** stored：读本机偏好（主界面初始化前也能用） */
  function stored(key, def) {
    try { var v = localStorage.getItem(key); return v ? JSON.parse(v) : def; } catch (e) { return def; }
  }

  function styleId() {
    var id = stored('pd.style', 'wechat');
    return X.STYLES.some(function (s) { return s[0] === id; }) ? id : 'wechat';
  }

  /** applyStyle：把当前风格写到页面根节点（微信风格是默认值，不写属性） */
  X.applyStyle = function () {
    var id = styleId();
    if (id === 'wechat') { document.documentElement.removeAttribute('data-style'); } else { document.documentElement.setAttribute('data-style', id); }
  };

  /** darkNow：当前实际是不是深色 */
  function darkNow() {
    var t = stored('pd.theme', 'system');
    if (t === 'dark') { return true; }
    if (t === 'light') { return false; }
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  /* ---------- 头像 ---------- */

  var PRESETS = [
    ['claude', 'Claude', 'logo-claude.svg'],
    ['codex', 'Codex', 'logo-codex.svg'],
    ['openai', 'OpenAI', 'logo-openai.svg'],
    ['gemini', 'Gemini', 'logo-gemini.svg'],
    ['deepseek', 'DeepSeek', 'logo-deepseek.svg'],
    ['pi', 'Pi', 'logo-pi.svg'],
    ['me', '默认', 'me.svg'],
    ['portrait-claude', '形象 橙', 'claude.svg'],
    ['portrait-codex', '形象 绿', 'codex.svg'],
    ['portrait-pi', '形象 紫', 'pi.svg'],
    ['portrait-dsh', '形象 蓝', 'dsh.svg']
  ];
  var DEFAULT_AVATAR = { me: 'preset:me', claude: 'preset:claude', codex: 'preset:codex', pi: 'preset:pi', dsh: 'preset:deepseek' };
  var AGENTS = [['claude', 'Claude Code'], ['codex', 'Codex'], ['pi', 'Pi'], ['dsh', 'DSH']];

  function presetFile(id) {
    var p = PRESETS.filter(function (x) { return x[0] === id; })[0];
    return p ? '/admin/avatars/' + p[2] : '';
  }

  /** avatarSrc：某个头像的图片地址（预设图或自己上传的图片），没有时为空 */
  function avatarSrc(key) {
    var s = c.load('pd.avatar.' + key, '') || DEFAULT_AVATAR[key] || '';
    if (!s) { return ''; }
    return s.indexOf('preset:') === 0 ? presetFile(s.slice(7)) : s;
  }

  /** avatarHtml：会话类型（或「host」代表我）对应的头像，没有可用图片时返回空，由主界面画默认图标 */
  X.avatarHtml = function (kind, small) {
    var src = avatarSrc(kind === 'host' ? 'me' : kind);
    if (!src) { return ''; }
    return '<div class="pd-avatar' + (small ? ' pd-avatar-s' : '') + '"><img alt="" src="' + esc(src) + '"></div>';
  };

  /** sessionAvatar：模板会话显示模板头像，其余按类型 */
  X.sessionAvatar = function (s, small) {
    var ref = s && parsePreset(s.preset);
    if (!ref) { return ''; }
    return '<div class="pd-avatar' + (small ? ' pd-avatar-s' : '') + '" style="background:' + esc(colorCss(ref.color)) + '">' + icon(ICONS[ref.icon] || 'sparkles', small ? 18 : 20) + '</div>';
  };

  function pickAvatar(key, title) {
    var cur = c.load('pd.avatar.' + key, '') || DEFAULT_AVATAR[key] || '';
    c.modal(title,
      '<div class="pd-av-grid">' + PRESETS.map(function (p) {
        return '<button class="pd-av-item' + (cur === 'preset:' + p[0] ? ' on' : '') + '" data-act="av-set" data-key="' + key + '" data-spec="preset:' + p[0] + '"><div class="pd-avatar"><img alt="" src="/admin/avatars/' + p[2] + '"></div><span>' + esc(p[1]) + '</span></button>';
      }).join('') + '</div>' +
      '<input type="file" id="av-file" class="pd-file-input" accept="image/*" data-key="' + key + '" tabindex="-1" aria-hidden="true">',
      '<button class="pd-btn" data-act="av-default" data-key="' + key + '">' + icon('rotate-ccw', 16) + '恢复默认</button><button class="pd-btn" data-act="av-upload">' + icon('image', 16) + '选择图片…</button>');
  }

  function setAvatar(key, spec) {
    if (spec) { c.save('pd.avatar.' + key, spec); } else { c.save('pd.avatar.' + key, ''); }
    c.closeModal();
    c.redrawAll();
  }

  /** squareImage：把选中的图片裁成正方形并缩小，转成可保存的图片数据 */
  function squareImage(file, size, done) {
    var fr = new FileReader();
    fr.onload = function () {
      var img = new Image();
      img.onload = function () {
        var cv = document.createElement('canvas');
        cv.width = cv.height = size;
        var s = Math.min(img.width, img.height);
        cv.getContext('2d').drawImage(img, (img.width - s) / 2, (img.height - s) / 2, s, s, 0, 0, size, size);
        done(cv.toDataURL('image/jpeg', 0.9));
      };
      img.onerror = function () { c.toast('无法读取这张图片'); };
      img.src = fr.result;
    };
    fr.readAsDataURL(file);
  }

  /* ---------- 外观页 ---------- */

  function previewHtml(id, mode) {
    return '<div class="pd-pv" data-pv="' + id + '" data-pvmode="' + mode + '"><div class="pd-pv-rail"><i class="me"></i><i></i><i></i></div>' +
      '<div class="pd-pv-list"><b></b><b class="on"></b><b></b></div>' +
      '<div class="pd-pv-main"><div class="pd-pv-msg"><i class="av"></i><span class="bb"></span></div><div class="pd-pv-msg mine"><span class="bb mine"></span><i class="av me"></i></div></div></div>';
  }

  /** appearanceHtml：外观设置（风格、明暗、头像） */
  X.appearanceHtml = function () {
    var t = c.load('pd.theme', 'system'), cur = styleId(), mode = darkNow() ? 'dark' : 'light';
    var cards = X.STYLES.map(function (s) {
      return '<button class="pd-style-card' + (cur === s[0] ? ' on' : '') + '" data-act="style-set" data-id="' + s[0] + '" aria-label="' + esc(s[1]) + '风格">' + previewHtml(s[0], mode) +
        '<div class="pd-style-name">' + esc(s[1]) + (cur === s[0] ? icon('check', 14) : '') + '</div><div class="pd-style-desc">' + esc(s[2]) + '</div></button>';
    }).join('');
    var avs = [['me', '我的头像']].concat(AGENTS.map(function (a) { return [a[0], a[1] + ' 的头像']; })).map(function (a) {
      return '<div class="pd-setting"><div class="pd-setting-text">' + esc(a[1]) + '</div><button class="pd-avatar-btn" data-act="av-open" data-key="' + a[0] + '" data-title="设置' + esc(a[1]) + '" aria-label="' + esc(a[1]) + '">' + (X.avatarHtml(a[0] === 'me' ? 'host' : a[0]) || '') + '</button></div>';
    }).join('');
    return ['<div class="pd-h2">界面风格</div><div class="pd-style-grid">' + cards + '</div>' +
      '<div class="pd-h2">明暗</div><div class="pd-card"><div class="pd-setting">' + c.tile('palette', 'var(--pd-tile-indigo)') + '<div class="pd-setting-text"><div>外观</div><div class="pd-setting-desc">浅色、深色或跟随系统</div></div>' +
      '<div class="pd-seg">' + [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']].map(function (x) {
        return '<button class="' + (t === x[0] ? 'active' : '') + '" data-act="theme" data-theme="' + x[0] + '">' + x[1] + '</button>';
      }).join('') + '</div></div></div>' +
      '<div class="pd-h2">头像</div><div class="pd-card">' + avs + '</div>' +
      '<div class="pd-muted" style="font-size:12px;margin:8px 2px 0">内置了几家 AI 的标志，也可以选一张自己的图片。</div>', ''];
  };

  /* ---------- 预设助手 ---------- */

  var ICONS = { languages: 'languages', scanText: 'scan-text', wandSparkles: 'wand-sparkles', listChecks: 'list-checks', bug: 'bug', sparkles: 'sparkles', bookOpen: 'book-open', mail: 'mail', code: 'code', lightbulb: 'lightbulb', briefcase: 'briefcase', graduationCap: 'graduation-cap', megaphone: 'megaphone', search: 'search' };
  var COLORS = [0xFF2F7BFA, 0xFF10A37F, 0xFFE0569B, 0xFFE2572B, 0xFF6B5BFF, 0xFFD97757, 0xFF0EA5E9, 0xFF475569];
  function colorCss(n) { return '#' + ((n >>> 0) & 0xFFFFFF).toString(16).padStart(6, '0'); }

  function P_(key, label, type, o) { o = o || {}; return { key: key, label: label, type: type, options: o.options || [], def: o.def || '', hint: o.hint || '' }; }

  /** BUILTIN：内置预设助手，与手机端的内容保持一致 */
  var BUILTIN = [
    { id: 'translate', name: '翻译', desc: '文字、文件、图片里的文字都能翻，保留原有排版', icon: 'languages', color: 0xFF2F7BFA, builtIn: true,
      prompt: '你是专业翻译。把用户发来的内容翻译成{{target}}。\n- 内容来源：用户直接输入的文字；若带有文件或图片附件，先读取其中的文字再翻译。\n- 风格：{{style}}。\n- 保留原文的段落、列表、表格、代码块与链接格式：{{keep}}。代码块里的代码不翻译，只翻译注释。\n- 专有名词、人名、品牌名保持原文，必要时在括号里附原文；用户给出的术语表优先：{{glossary}}。\n- 原文已经是{{target}}时，改为润色成更通顺的表达，并说明这一点。\n- 只输出译文，不加解释、不加前后缀；遇到有歧义的地方，在译文末尾另起一行用「注：」简短说明。',
      params: [P_('target', '目标语言', 'choice', { options: ['中文', '英文', '日文', '韩文', '法文', '德文', '西班牙文', '俄文'], def: '英文' }), P_('style', '翻译风格', 'choice', { options: ['自然流畅', '准确直译', '正式书面', '口语化', '文学优美'], def: '自然流畅' }), P_('keep', '保留原有格式', 'toggle', { def: '是' }), P_('glossary', '术语表', 'text', { hint: '例如：token=词元；agent=智能体' })] },
    { id: 'ocr', name: 'OCR 识别', desc: '把图片、截图、扫描件里的文字原样识别出来', icon: 'scanText', color: 0xFF10A37F, builtIn: true,
      prompt: '你是 OCR 文字识别助手。用户会发来图片、截图或扫描 PDF（以附件文件的形式给出，请直接打开文件查看内容）。\n- 逐字识别其中的全部文字，识别语言：{{lang}}。不要概括、不要改写、不要漏行，看不清的字用「□」占位并在末尾说明位置。\n- 输出格式：{{format}}。表格按 Markdown 表格输出，公式按 LaTeX 输出，手写体尽量识别并标注「（手写）」。\n- 保留阅读顺序与段落层次：{{layout}}；多栏版面按栏依次输出。\n- 识别完成后，如需要翻译成：{{translate}}，在识别结果下方另起一节给出译文；选「不翻译」则不输出译文。\n- 只输出识别结果本身，不加「以下是识别结果」之类的前缀。没有收到图片或文件时，直接提示用户先发送图片。',
      params: [P_('lang', '识别语言', 'choice', { options: ['自动判断', '中文', '英文', '中英混合', '日文', '韩文'], def: '自动判断' }), P_('format', '输出格式', 'choice', { options: ['纯文本', 'Markdown', '保留表格（Markdown 表格）', 'JSON 结构化（按块列出文字与位置）'], def: '纯文本' }), P_('layout', '保留排版', 'toggle', { def: '是' }), P_('translate', '同时翻译成', 'choice', { options: ['不翻译', '中文', '英文', '日文'], def: '不翻译' })] },
    { id: 'polish', name: '润色改写', desc: '改得更通顺、更得体，原意不变', icon: 'wandSparkles', color: 0xFFE0569B, builtIn: true,
      prompt: '你是文字编辑。对用户发来的文字做润色改写。\n- 目标风格：{{tone}}；篇幅：{{length}}。\n- 保持原意与事实不变，不增加原文没有的信息；修正错别字、病句与标点。\n- 先给出改写后的全文，再用最多三条要点说明主要改动：{{notes}}。\n- 用户另有具体要求时，以用户要求为准。',
      params: [P_('tone', '目标风格', 'choice', { options: ['简洁专业', '正式得体', '亲切自然', '有说服力', '幽默轻松'], def: '简洁专业' }), P_('length', '篇幅', 'choice', { options: ['与原文相当', '更精简', '适当扩写'], def: '与原文相当' }), P_('notes', '附改动说明', 'toggle', { def: '是' })] },
    { id: 'summary', name: '总结提炼', desc: '长文、会议记录、文档快速提炼要点', icon: 'listChecks', color: 0xFFE2572B, builtIn: true,
      prompt: '你是信息提炼助手。对用户发来的内容（文字或附件文档）做总结。\n- 输出形式：{{form}}；详细程度：{{depth}}。\n- 只依据原文，不编造；数字、日期、人名、结论保持准确。\n- 最后用一行列出「待办/风险/疑点」：{{todo}}，没有则省略这一行。\n- 内容过长无法完整阅读时，先说明读到了哪里，再给出已读部分的总结。',
      params: [P_('form', '输出形式', 'choice', { options: ['要点列表', '一段话摘要', '分级大纲', '问答对'], def: '要点列表' }), P_('depth', '详细程度', 'choice', { options: ['极简（3 条以内）', '适中', '详细'], def: '适中' }), P_('todo', '提取待办与风险', 'toggle', { def: '是' })] },
    { id: 'review', name: '代码审查', desc: '读代码找问题，按严重程度排序给建议', icon: 'bug', color: 0xFF6B5BFF, builtIn: true,
      prompt: '你是资深代码审查员。审查用户给出的代码、diff 或文件路径（可在当前工作目录里读取文件）。\n- 重点关注：{{focus}}；严格程度：{{strict}}。\n- 按「严重 / 一般 / 建议」分组列出问题，每条写清：位置、问题、为什么是问题、怎么改（给出改后的代码片段）。\n- 不要修改文件，除非用户明确要求；没有发现问题时直接说明，不要为了凑数而挑刺。\n- 最后给出一句总体结论。',
      params: [P_('focus', '关注点', 'choice', { options: ['缺陷与边界情况', '安全漏洞', '性能', '可读性与结构', '全面检查'], def: '全面检查' }), P_('strict', '严格程度', 'choice', { options: ['宽松（只报明显问题）', '标准', '严格（连风格也挑）'], def: '标准' })] },
    { id: 'prompt', name: '提示词优化', desc: '把一句想法改写成清晰、可直接使用的提示词', icon: 'sparkles', color: 0xFFD97757, builtIn: true,
      prompt: '你是提示词工程师。把用户的需求改写成一条结构清晰、可直接复制使用的提示词。\n- 目标模型：{{model}}；输出语言：{{lang}}。\n- 结构：角色、任务、背景信息、输出格式、约束与示例（信息不足的部分用【待补充】标出，不要编造）。\n- 先输出优化后的提示词（放在一个代码块里便于复制），再用两三条要点说明改了什么、还缺什么信息。',
      params: [P_('model', '目标模型', 'choice', { options: ['通用', 'Claude', 'GPT / Codex', 'DeepSeek', '图像生成'], def: '通用' }), P_('lang', '输出语言', 'choice', { options: ['中文', '英文'], def: '中文' })] }
  ];

  function defaults(t) {
    var o = {};
    (t.params || []).forEach(function (p) { o[p.key] = p.def || (p.options && p.options.length ? p.options[0] : ''); });
    return o;
  }

  /** renderPrompt：把参数值填进系统提示词；没引用到的参数追加在末尾 */
  function renderPrompt(t, values) {
    var v = Object.assign(defaults(t), values || {});
    var out = t.prompt, used = {};
    (t.params || []).forEach(function (p) {
      var token = '{{' + p.key + '}}';
      if (out.indexOf(token) >= 0) {
        used[p.key] = true;
        out = out.split(token).join(String(v[p.key] || '').trim() || '未指定');
      }
    });
    var rest = (t.params || []).filter(function (p) { return !used[p.key] && String(v[p.key] || '').trim(); }).map(function (p) { return '- ' + p.label + '：' + String(v[p.key]).trim(); });
    if (rest.length) { out += '\n\n补充要求：\n' + rest.join('\n'); }
    return out;
  }

  function presetRef(t, values) {
    return JSON.stringify({ id: t.id, name: t.name, icon: t.icon, color: t.color, params: Object.assign(defaults(t), values || {}) });
  }

  function parsePreset(raw) {
    if (!raw) { return null; }
    try { var j = JSON.parse(raw); return j && typeof j === 'object' ? j : null; } catch (e) { return null; }
  }

  /* ---------- 资料库 ---------- */

  var lib = { clip: null, fav: null, prompt: null, preset: null };
  var libErr = '';
  var query = { fav: '', prompt: '' };

  function fetchKind(kind) {
    return c.api('GET', P + '/api/library?kind=' + kind).then(function (list) {
      lib[kind] = list || [];
      libErr = '';
      c.redrawMain();
    }).catch(function (e) { if (lib[kind] === null) { lib[kind] = []; } libErr = e.message; c.redrawMain(); });
  }

  /** ensure：打开页面时读取需要的资料 */
  X.ensure = function (r) {
    if (r.page === 'tools') { var k = r.sub || 'clip'; if (lib[k] === null) { fetchKind(k); } }
    if (r.page === 'contacts' && lib.preset === null) { fetchKind('preset'); }
  };

  /** onLibraryChanged：电脑端或手机端改动了资料，重新读取那一类 */
  X.onLibraryChanged = function (d) {
    var k = d && d.kind;
    if (k && lib[k] !== undefined && lib[k] !== null) { fetchKind(k); }
  };

  function item(kind, id) { return (lib[kind] || []).filter(function (x) { return x.id === id; })[0]; }
  function storedPresets() {
    return (lib.preset || []).map(function (x) {
      try { var j = JSON.parse(x.body); j.builtIn = false; j.libraryId = x.id; return j; } catch (e) { return null; }
    }).filter(function (x) { return x && x.name; });
  }
  function builtinOf(id) { return BUILTIN.filter(function (b) { return b.id === id; })[0]; }
  /** allPresets：资料库里与内置模板同编号的一条是对内置模板的修改，替换出厂版本；其余是自定义模板 */
  function allPresets() {
    var stored = storedPresets(), byId = {};
    stored.forEach(function (t) { byId[t.id] = t; });
    return BUILTIN.map(function (b) { var o = byId[b.id]; return o ? Object.assign({}, o, { builtIn: true, overridden: true }) : b; })
      .concat(stored.filter(function (t) { return !builtinOf(t.id); }));
  }
  function findPreset(id) { return allPresets().filter(function (t) { return t.id === id; })[0]; }

  function addText(kind, body, title, meta) {
    return c.api('POST', P + '/api/library', { kind: kind, title: title || '', body: body, mime: 'text/plain', meta: meta || '' });
  }

  function addBlob(kind, file, extra) {
    if (file.size > 25 * 1024 * 1024) { c.toast((file.name || '文件') + ' 超过 25 MB，请改用手机传输'); return Promise.resolve(); }
    var q = 'kind=' + kind + '&mime=' + encodeURIComponent(file.type || 'application/octet-stream') + '&name=' + encodeURIComponent(encodeURIComponent(file.name || '')) + (extra ? '&meta=' + encodeURIComponent(extra) : '');
    return fetch(P + '/api/library/blob?' + q, { method: 'POST', body: file, credentials: 'same-origin' }).then(function (res) {
      return res.json().catch(function () { return null; }).then(function (d) { if (!res.ok) { throw new Error((d && d.message) || '放入失败'); } return d; });
    });
  }

  /** addFiles：把图片或文件放进剪切板 */
  X.addFiles = function (files) {
    var list = Array.prototype.slice.call(files || []);
    if (!list.length) { return; }
    Promise.all(list.map(function (f) { return addBlob('clip', f); })).then(function () { c.toast('已放进剪切板'); }).catch(function (e) { c.toast(e.message); });
  };

  /** dropTarget：当前页面是否接收粘贴与拖入的文件 */
  X.dropTarget = function (r) { return r.page === 'tools' && (r.sub || 'clip') === 'clip'; };

  /** favoriteText：把一段文字收藏起来 */
  X.favoriteText = function (text, source) {
    if (!String(text || '').trim()) { return; }
    addText('fav', text, '', source || '').then(function () { c.toast('已收藏'); }).catch(function (e) { c.toast(e.message); });
  };

  function blobUrl(id) { return P + '/api/library/' + encodeURIComponent(id) + '/blob'; }

  /** copyImage：把图片放到系统剪贴板 */
  function copyImage(x) {
    fetch(blobUrl(x.id), { credentials: 'same-origin' }).then(function (r) { return r.blob(); }).then(function (b) {
      if (!navigator.clipboard || !window.ClipboardItem) { throw new Error('当前环境不支持复制图片，请用「下载」'); }
      return toPng(b).then(function (png) { return navigator.clipboard.write([new window.ClipboardItem({ 'image/png': png })]); });
    }).then(function () { c.toast('已复制图片'); }).catch(function (e) { c.toast(e.message || '复制失败'); });
  }

  function toPng(blob) {
    if (blob.type === 'image/png') { return Promise.resolve(blob); }
    return new Promise(function (resolve, reject) {
      var img = new Image(), url = URL.createObjectURL(blob);
      img.onload = function () {
        var cv = document.createElement('canvas');
        cv.width = img.naturalWidth; cv.height = img.naturalHeight;
        cv.getContext('2d').drawImage(img, 0, 0);
        URL.revokeObjectURL(url);
        cv.toBlob(function (b) { b ? resolve(b) : reject(new Error('转换图片失败')); }, 'image/png');
      };
      img.onerror = function () { URL.revokeObjectURL(url); reject(new Error('读取图片失败')); };
      img.src = url;
    });
  }

  function download(x) {
    var a = document.createElement('a');
    a.href = blobUrl(x.id);
    a.download = x.name || (x.mime && x.mime.indexOf('image/') === 0 ? '图片.' + x.mime.split('/')[1] : '文件');
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  function isText(x) { return !x.size; }
  function isImg(x) { return x.size > 0 && String(x.mime || '').indexOf('image/') === 0; }

  /* ---------- 通讯录 ---------- */

  var pv = { id: '', agent: '', values: {}, dir: null, show: false };

  function installedKinds() {
    var h = c.host();
    var list = (h && h.agents || []).filter(function (a) { return a.installed; }).map(function (a) { return a.kind; });
    return list.length ? list : AGENTS.map(function (a) { return a[0]; });
  }
  function agentName(k) { var a = AGENTS.filter(function (x) { return x[0] === k; })[0]; return a ? a[1] : k; }

  function contactsList(r) {
    var q = (query.contact || '').trim().toLowerCase();
    var friends = AGENTS.filter(function (a) { return !q || a[1].toLowerCase().indexOf(q) >= 0; });
    var presets = allPresets().filter(function (t) { return !q || (t.name + t.desc).toLowerCase().indexOf(q) >= 0; });
    var h = c.host(), cur = r.id || '';
    var row = function (go, av, name, sub, tag) {
      return '<button class="pd-row' + (cur === go ? ' active' : '') + '" data-go="contacts/' + esc(go) + '">' + av + '<div class="pd-row-main"><div class="pd-row-line"><span class="pd-row-title">' + esc(name) + '</span>' + (tag ? '<span class="pd-tag-auto">' + tag + '</span>' : '') + '</div><div class="pd-row-sub">' + esc(sub) + '</div></div></button>';
    };
    return '<div class="pd-list-top"><label class="pd-search">' + icon('search', 14) + '<input id="contact-search" placeholder="搜索" value="' + esc(query.contact || '') + '"></label>' +
      '<button class="pd-plus" data-act="preset-new" title="新建预设助手" aria-label="新建预设助手">' + icon('user-round-plus', 16) + '</button></div><div class="pd-list-body">' +
      (friends.length ? '<div class="pd-list-sec">AI 好友</div>' + friends.map(function (a) {
        var info = (h && h.agents || []).filter(function (x) { return x.kind === a[0]; })[0];
        return row('agent:' + a[0], X.avatarHtml(a[0]) || '', a[1], info ? (info.installed ? (info.version || '已安装') : '未安装') : '', '');
      }).join('') : '') +
      (presets.length ? '<div class="pd-list-sec">预设助手</div>' + presets.map(function (t) {
        return row('preset:' + t.id, '<div class="pd-avatar" style="background:' + colorCss(t.color) + '">' + icon(ICONS[t.icon] || 'sparkles', 20) + '</div>', t.name, t.desc, t.builtIn ? (t.overridden ? '已修改' : '') : '自定义');
      }).join('') : '') + '</div>';
  }

  function contactsMain(r) {
    var id = r.id || '';
    if (id.indexOf('agent:') === 0) { return agentMain(id.slice(6)); }
    if (id.indexOf('preset:') === 0) { return presetMain(id.slice(7)); }
    return '<div class="pd-empty-main">' + icon('users-round', 88) + '</div>';
  }

  function head(titleText, acts) {
    return '<header class="pd-head"><div class="pd-head-main"><div class="pd-head-title">' + esc(titleText) + '</div></div>' + (acts ? '<div class="pd-head-acts">' + acts + '</div>' : '') + '</header>';
  }

  function agentMain(kind) {
    var h = c.host(), info = (h && h.agents || []).filter(function (x) { return x.kind === kind; })[0];
    var installed = !info || info.installed;
    var ss = c.sessions().filter(function (s) { return s.kind === kind && !s.preset; }).sort(function (a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0); });
    var auto = kind === 'claude' || kind === 'codex';
    return head(agentName(kind), '') + '<div class="pd-page"><div class="pd-page-inner">' +
      '<div class="pd-hero"><button class="pd-avatar-btn pd-avatar-big" data-act="av-open" data-key="' + kind + '" data-title="设置' + esc(agentName(kind)) + ' 的头像" aria-label="更换头像">' + (X.avatarHtml(kind) || '') + '</button>' +
      '<div><div class="pd-hero-name">' + esc(agentName(kind)) + '</div><div class="pd-hero-state" style="' + (installed ? '' : 'color:var(--pd-text-3)') + '"><i style="' + (installed ? '' : 'background:var(--pd-text-4)') + '"></i>' + (installed ? esc((info && info.version) || '电脑上已安装') : '电脑上未安装') + '</div></div></div>' +
      '<div class="pd-h2">发起会话</div><div class="pd-card">' +
      '<div class="pd-setting">' + c.tile('message-square-plus', 'var(--pd-tile-green)') + '<div class="pd-setting-text"><div>新建会话</div><div class="pd-setting-desc">选择工作目录后开始</div></div><button class="pd-btn pd-btn-primary" data-act="contact-new" data-kind="' + kind + '"' + (installed ? '' : ' disabled') + '>新建</button></div>' +
      (auto ? '<div class="pd-setting">' + c.tile('zap', 'var(--pd-tile-amber)') + '<div class="pd-setting-text"><div>免审批会话</div><div class="pd-setting-desc">所有操作自动放行</div></div><button class="pd-btn" data-act="contact-new" data-kind="' + kind + '" data-auto="1"' + (installed ? '' : ' disabled') + '>新建</button></div>' : '') + '</div>' +
      (ss.length ? '<div class="pd-h2">最近的会话</div><div class="pd-card">' + ss.slice(0, 6).map(function (s) {
        return '<button class="pd-setting pd-setting-btn" data-go="chat/' + encodeURIComponent(s.id) + '">' + c.tile('message-circle', 'var(--pd-tile-blue)') + '<div class="pd-setting-text"><div>' + esc(c.title(s)) + '</div><div class="pd-setting-desc">' + esc(c.oneLine(s.preview || '', 60)) + '</div></div><span class="pd-muted">' + icon('chevron-right', 16) + '</span></button>';
      }).join('') + '</div>' : '') + '</div></div>';
  }

  function presetFormHtml(t) {
    var v = Object.assign(defaults(t), pv.values);
    return (t.params || []).map(function (p) {
      var id = 'pp-' + p.key;
      if (p.type === 'choice') {
        return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><select class="pd-input" id="' + id + '" data-pkey="' + p.key + '">' + p.options.map(function (o) { return '<option' + (o === v[p.key] ? ' selected' : '') + '>' + esc(o) + '</option>'; }).join('') + '</select></div>';
      }
      if (p.type === 'toggle') {
        return '<div class="pd-field"><label class="pd-toggle-line"><input type="checkbox" id="' + id + '" data-pkey="' + p.key + '"' + (v[p.key] === '是' ? ' checked' : '') + '>' + esc(p.label) + '</label></div>';
      }
      return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><input class="pd-input" id="' + id + '" data-pkey="' + p.key + '" value="' + esc(v[p.key] || '') + '" placeholder="' + esc(p.hint || '') + '"></div>';
    }).join('');
  }

  function presetMain(id) {
    var t = findPreset(id);
    if (!t) { return head('预设助手', '') + '<div class="pd-page"><div class="pd-empty">找不到这个预设助手</div></div>'; }
    if (pv.id !== id) {
      var kinds = installedKinds();
      pv = { id: id, agent: kinds[0] || 'claude', values: defaults(t), dir: null, show: false };
      try { var saved = c.load('pd.preset.' + id, null); if (saved) { pv.values = Object.assign(defaults(t), saved.values || {}); if (kinds.indexOf(saved.agent) >= 0) { pv.agent = saved.agent; } } } catch (e) { /* 读取失败用默认值 */ }
    }
    var kinds2 = installedKinds();
    var acts = t.builtIn ? '<button class="pd-btn" data-act="preset-edit" data-id="' + esc(id) + '">' + icon('pencil', 16) + '修改提示词与参数</button>' +
      (t.overridden ? '<button class="pd-btn" data-act="preset-reset" data-id="' + esc(id) + '">' + icon('rotate-ccw', 16) + '恢复默认</button>' : '') +
      '<button class="pd-btn" data-act="preset-copy" data-id="' + esc(id) + '">' + icon('copy', 16) + '复制为自定义</button>' :
      '<button class="pd-btn" data-act="preset-edit" data-id="' + esc(id) + '">' + icon('pencil', 16) + '编辑</button><button class="pd-btn pd-btn-danger" data-act="preset-del" data-id="' + esc(id) + '">' + icon('trash', 16) + '删除</button>';
    return head(t.name, acts) + '<div class="pd-page"><div class="pd-page-inner">' +
      '<div class="pd-hero"><div class="pd-hero-icon" style="background:' + colorCss(t.color) + '">' + icon(ICONS[t.icon] || 'sparkles', 26) + '</div><div><div class="pd-hero-name">' + esc(t.name) + (t.overridden ? ' <span class="pd-tag pd-tag-ok">已修改</span>' : '') + '</div><div class="pd-muted" style="font-size:13px;margin-top:2px">' + esc(t.desc) + '</div></div></div>' +
      '<div class="pd-h2">交给谁处理</div><div class="pd-agents">' + kinds2.map(function (k) {
        return '<button class="pd-agent' + (pv.agent === k ? ' pd-agent-on' : '') + '" data-act="preset-agent" data-kind="' + k + '">' + (X.avatarHtml(k) || '') + '<div style="flex:1;min-width:0">' + esc(agentName(k)) + '</div>' + (pv.agent === k ? '<span style="color:var(--pd-accent)">' + icon('check', 16) + '</span>' : '') + '</button>';
      }).join('') + '</div>' +
      (t.params && t.params.length ? '<div class="pd-h2">参数</div><div class="pd-card"><div class="pd-form-grid">' + presetFormHtml(t) + '</div></div>' : '') +
      '<div class="pd-h2">工作目录</div><div class="pd-card"><div class="pd-setting"><div class="pd-setting-text"><div>' + (pv.dir ? esc(pv.dir.label) : '默认工作目录') + '</div></div><button class="pd-btn" data-act="preset-dir">' + icon('folder-open', 16) + '更换…</button></div></div>' +
      '<div class="pd-h2">系统提示词</div><div class="pd-card"><div class="pd-setting"><div class="pd-setting-text pd-setting-desc">每一轮对话，电脑端会把它放在你的输入前面一起交给 Agent</div><button class="pd-link" data-act="preset-show">' + (pv.show ? '收起' : '查看') + '</button><button class="pd-link" data-act="preset-edit" data-id="' + esc(id) + '">修改</button></div>' +
      (pv.show ? '<pre class="pd-prompt-pre" id="pp-prompt">' + esc(renderPrompt(t, pv.values)) + '</pre>' : '') + '</div>' +
      '<div class="pd-savebar"><button class="pd-btn pd-btn-primary" data-act="preset-start" data-id="' + esc(id) + '">' + icon('message-circle', 16) + '开始对话</button></div></div></div>';
  }

  /* ---------- 工具箱 ---------- */

  var TOOLS = [['clip', '剪切板', '文字、图片、文件在手机和电脑之间中转', 'clipboard-paste', 'var(--pd-tile-indigo)'], ['fav', '收藏夹', '聊天里存下来的内容', 'star', 'var(--pd-tile-amber)'], ['prompt', '提示词', '常用提示词，聊天时一点即用', 'message-square-text', 'var(--pd-tile-blue)'], ['files', '工作区', '浏览和管理工作区、手机上的文件', 'folder', 'var(--pd-tile-teal)']];

  function toolsList(r) {
    var cur = r.sub || 'clip';
    return '<div class="pd-list-top"><div class="pd-list-title">工具箱</div></div><div class="pd-list-body">' + TOOLS.map(function (t) {
      return '<button class="pd-row' + (cur === t[0] ? ' active' : '') + '" style="height:56px" data-go="' + (t[0] === 'files' ? 'phone' : 'tools/' + t[0]) + '"><span class="pd-tile" style="background:' + t[4] + '">' + icon(t[3], 16) + '</span><div class="pd-row-main"><div class="pd-row-title">' + t[1] + '</div></div></button>';
    }).join('') + '</div>';
  }

  function when(ms) { return c.listTime(ms); }

  function emptyOrErr(list, empty) {
    if (list === null) { return '<div class="pd-empty">正在读取…</div>'; }
    if (libErr && !list.length) { return '<div class="pd-empty">' + esc(libErr) + '</div>'; }
    return list.length ? '' : '<div class="pd-empty">' + empty + '</div>';
  }

  function clipMain() {
    var list = lib.clip;
    var cards = (list || []).map(function (x) {
      var body;
      if (isImg(x)) { body = '<button class="pd-img" data-act="clip-view" data-id="' + x.id + '"><img alt="' + esc(x.name || '图片') + '" src="' + blobUrl(x.id) + '" loading="lazy"></button>'; }
      else if (x.size) { body = '<div class="pd-clip-file">' + icon('file', 22) + '<div><div>' + esc(x.name || '文件') + '</div><div class="pd-muted" style="font-size:12px">' + c.fmtSize(x.size) + '</div></div></div>'; }
      else { body = '<pre class="pd-clip-text">' + esc(x.body) + '</pre>'; }
      var acts = (isText(x) ? '<button class="pd-btn" data-act="clip-copy" data-id="' + x.id + '">' + icon('copy', 14) + '复制</button>' : (isImg(x) ? '<button class="pd-btn" data-act="clip-copy-img" data-id="' + x.id + '">' + icon('copy', 14) + '复制图片</button>' : '')) +
        (x.size ? '<button class="pd-btn" data-act="clip-download" data-id="' + x.id + '">' + icon('download', 14) + '下载</button>' : '') +
        '<button class="pd-btn" data-act="clip-fav" data-id="' + x.id + '">' + icon('star', 14) + '收藏</button>' +
        '<button class="pd-icon-btn" data-act="clip-pin" data-id="' + x.id + '" title="' + (x.pinned ? '取消置顶' : '置顶') + '" aria-label="' + (x.pinned ? '取消置顶' : '置顶') + '">' + icon('pin', 16) + '</button>' +
        '<button class="pd-icon-btn" data-act="clip-del" data-id="' + x.id + '" title="删除" aria-label="删除">' + icon('trash', 16) + '</button>';
      return '<div class="pd-clip' + (x.pinned ? ' pinned' : '') + '"><div class="pd-clip-meta">' + icon(isImg(x) ? 'image' : (x.size ? 'file' : 'message-square-text'), 14) + '<span>' + when(x.updatedAt) + '</span>' + (x.pinned ? '<span style="color:var(--pd-accent)">' + icon('pin', 14) + '</span>' : '') + '</div>' + body + '<div class="pd-actions">' + acts + '</div></div>';
    }).join('');
    return head('剪切板', '<button class="pd-btn pd-btn-danger" data-act="clip-clear">' + icon('trash', 16) + '清空</button>') + '<div class="pd-page pd-drop"><div class="pd-page-inner">' +
      '<div class="pd-card pd-clip-compose"><textarea id="clip-text" placeholder="输入或粘贴文字，也可以直接粘贴图片、拖入文件，手机上的「剪切板」会同步看到"></textarea><div class="pd-actions" style="padding:0 12px 12px"><span class="pd-hint">Ctrl / ⌘ + Enter 放进去</span><span style="flex:1"></span>' +
      '<button class="pd-btn" data-act="clip-file">' + icon('upload', 16) + '选择文件…</button><button class="pd-btn" data-act="clip-paste">' + icon('clipboard-paste', 16) + '粘贴剪贴板</button><button class="pd-btn pd-btn-primary" data-act="clip-add">放进剪切板</button></div>' +
      '<input type="file" id="clip-file" class="pd-file-input" multiple tabindex="-1" aria-hidden="true"></div>' +
      emptyOrErr(list, '还没有内容') + '<div class="pd-clip-list">' + cards + '</div></div></div>';
  }

  function favMain() {
    var q = (query.fav || '').trim().toLowerCase();
    var list = (lib.fav || []).filter(function (x) { return !q || (x.title + x.body + x.name + x.meta).toLowerCase().indexOf(q) >= 0; });
    var cards = list.map(function (x) {
      var titleText = x.title || (x.size ? (x.name || '文件') : String(x.body || '').trim().split('\n')[0]);
      var body = isImg(x) ? '<button class="pd-img" data-act="fav-view" data-id="' + x.id + '"><img alt="" src="' + blobUrl(x.id) + '" loading="lazy"></button>' : (x.size ? '' : '<pre class="pd-clip-text">' + esc(x.body) + '</pre>');
      return '<div class="pd-clip' + (x.pinned ? ' pinned' : '') + '"><div class="pd-clip-meta"><b style="color:var(--pd-text)">' + esc(titleText) + '</b><span style="flex:1"></span><span>' + (x.meta ? esc(x.meta) + ' · ' : '') + when(x.updatedAt) + '</span></div>' + body +
        '<div class="pd-actions">' + (x.size ? '<button class="pd-btn" data-act="fav-download" data-id="' + x.id + '">' + icon('download', 14) + '下载</button>' : '<button class="pd-btn" data-act="fav-copy" data-id="' + x.id + '">' + icon('copy', 14) + '复制</button>') +
        '<button class="pd-btn" data-act="fav-rename" data-id="' + x.id + '">' + icon('pencil', 14) + '重命名</button>' +
        '<button class="pd-icon-btn" data-act="fav-pin" data-id="' + x.id + '" title="' + (x.pinned ? '取消置顶' : '置顶') + '" aria-label="' + (x.pinned ? '取消置顶' : '置顶') + '">' + icon('pin', 16) + '</button>' +
        '<button class="pd-icon-btn" data-act="fav-del" data-id="' + x.id + '" title="取消收藏" aria-label="取消收藏">' + icon('trash', 16) + '</button></div></div>';
    }).join('');
    return head('收藏夹', '<button class="pd-btn pd-btn-primary" data-act="fav-add">' + icon('plus', 16) + '新建</button>') + '<div class="pd-page"><div class="pd-page-inner">' +
      '<label class="pd-search pd-search-wide">' + icon('search', 14) + '<input id="fav-search" placeholder="搜索收藏" value="' + esc(query.fav || '') + '"></label>' +
      emptyOrErr(list, q ? '没有找到相关收藏' : '还没有收藏，在聊天里右键一条消息选「收藏」') + '<div class="pd-clip-list">' + cards + '</div></div></div>';
  }

  function promptMain() {
    var q = (query.prompt || '').trim().toLowerCase();
    var list = (lib.prompt || []).filter(function (x) { return !q || (x.title + x.body + x.meta).toLowerCase().indexOf(q) >= 0; });
    var cards = list.map(function (x) {
      return '<div class="pd-clip' + (x.pinned ? ' pinned' : '') + '"><div class="pd-clip-meta"><b style="color:var(--pd-text)">' + esc(x.title || String(x.body || '').trim().split('\n')[0]) + '</b>' + (x.meta ? '<span class="pd-tag pd-tag-ok">' + esc(x.meta) + '</span>' : '') + '<span style="flex:1"></span><span>' + when(x.updatedAt) + '</span></div>' +
        '<pre class="pd-clip-text">' + esc(x.body) + '</pre><div class="pd-actions"><button class="pd-btn" data-act="prompt-copy" data-id="' + x.id + '">' + icon('copy', 14) + '复制</button>' +
        '<button class="pd-btn" data-act="prompt-edit" data-id="' + x.id + '">' + icon('pencil', 14) + '编辑</button>' +
        '<button class="pd-icon-btn" data-act="prompt-pin" data-id="' + x.id + '" title="' + (x.pinned ? '取消置顶' : '置顶') + '" aria-label="' + (x.pinned ? '取消置顶' : '置顶') + '">' + icon('pin', 16) + '</button>' +
        '<button class="pd-icon-btn" data-act="prompt-del" data-id="' + x.id + '" title="删除" aria-label="删除">' + icon('trash', 16) + '</button></div></div>';
    }).join('');
    return head('提示词', '<button class="pd-btn pd-btn-primary" data-act="prompt-add">' + icon('plus', 16) + '新建</button>') + '<div class="pd-page"><div class="pd-page-inner">' +
      '<label class="pd-search pd-search-wide">' + icon('search', 14) + '<input id="prompt-search" placeholder="搜索提示词" value="' + esc(query.prompt || '') + '"></label>' +
      emptyOrErr(list, q ? '没有找到相关提示词' : '还没有提示词，点右上角「新建」写一条') + '<div class="pd-clip-list">' + cards + '</div></div></div>';
  }

  function toolsMain(r) {
    var k = r.sub || 'clip';
    return k === 'fav' ? favMain() : (k === 'prompt' ? promptMain() : clipMain());
  }

  /** listHtml、mainHtml：通讯录与工具箱页面的左侧列表和右侧内容 */
  X.listHtml = function (r) { return r.page === 'contacts' ? contactsList(r) : toolsList(r); };
  X.mainHtml = function (r) { return r.page === 'contacts' ? contactsMain(r) : toolsMain(r); };

  /* ---------- 提示词选择、编辑 ---------- */

  function promptEditor(x) {
    c.modal(x ? '编辑提示词' : '新建提示词',
      '<div class="pd-field"><label for="pe-title">标题</label><input class="pd-input" id="pe-title" value="' + esc(x ? x.title : '') + '"></div>' +
      '<div class="pd-field"><label for="pe-meta">分类</label><input class="pd-input" id="pe-meta" placeholder="如 写作、代码" value="' + esc(x ? x.meta : '') + '"></div>' +
      '<div class="pd-field"><label for="pe-body">内容</label><textarea class="pd-input" id="pe-body" style="height:200px;padding:8px 10px;resize:vertical">' + esc(x ? x.body : '') + '</textarea></div>',
      '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="prompt-save" data-id="' + (x ? x.id : '') + '">保存</button>');
  }

  /** promptPicker：在聊天里挑一条提示词放进输入框 */
  function promptPicker() {
    var go = function () {
      var list = lib.prompt || [];
      c.modal('选择提示词', list.length ? '<div class="pd-pick-list">' + list.map(function (x) {
        return '<button class="pd-pick-row" data-act="prompt-use" data-id="' + x.id + '"><span style="flex:1;min-width:0"><div>' + esc(x.title || String(x.body).split('\n')[0]) + '</div><div class="pd-path" style="font-family:inherit">' + esc(c.oneLine(x.body, 80)) + '</div></span></button>';
      }).join('') + '</div>' : '<div class="pd-empty">还没有提示词，先到「工具箱 → 提示词」新建</div>', '<button class="pd-btn" data-act="modal-close">关闭</button>');
    };
    if (lib.prompt === null) { c.api('GET', P + '/api/library?kind=prompt').then(function (l) { lib.prompt = l || []; go(); }).catch(function (e) { c.toast(e.message); }); } else { go(); }
  }
  X.promptPicker = promptPicker;

  /* ---------- 预设助手编辑 ---------- */

  function presetEditor(t, asCopy) {
    var cur = t || { name: '', desc: '', icon: 'sparkles', color: COLORS[0], prompt: '', params: [] };
    pe = { id: asCopy || !t ? '' : t.id, libraryId: asCopy || !t ? '' : (t.libraryId || ''), builtIn: !!(t && t.builtIn && !asCopy), icon: cur.icon, color: cur.color, params: (cur.params || []).map(function (p) { return Object.assign({}, p); }) };
    c.modal(t && !asCopy ? (t.builtIn ? '修改「' + t.name + '」' : '编辑预设助手') : '新建预设助手', presetEditorBody(cur, asCopy), '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="preset-save">保存</button>');
  }
  var pe = null;

  function presetEditorBody(cur, asCopy) {
    return '<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap" id="pe-icons">' + Object.keys(ICONS).map(function (k) {
      return '<button class="pd-icon-btn' + (pe.icon === k ? ' pd-icon-on' : '') + '" data-act="pe-icon" data-icon="' + k + '" aria-label="' + k + '">' + icon(ICONS[k], 18) + '</button>';
    }).join('') + '</div><div style="display:flex;gap:8px" id="pe-colors">' + COLORS.map(function (n) {
      return '<button class="pd-color' + (pe.color === n ? ' on' : '') + '" data-act="pe-color" data-color="' + n + '" style="background:' + colorCss(n) + '" aria-label="颜色"></button>';
    }).join('') + '</div>' +
      '<div class="pd-field"><label for="pe-name">名称</label><input class="pd-input" id="pe-name" value="' + esc(cur.name + (asCopy ? '（自定义）' : '')) + '"></div>' +
      '<div class="pd-field"><label for="pe-desc">一句话说明</label><input class="pd-input" id="pe-desc" value="' + esc(cur.desc) + '"></div>' +
      '<div class="pd-field"><label for="pe-prompt">系统提示词（用 {{参数键}} 引用下面的参数，键显示在每个参数的左上角）</label><textarea class="pd-input" id="pe-prompt" style="height:160px;padding:8px 10px;resize:vertical">' + esc(cur.prompt) + '</textarea></div>' +
      '<div class="pd-h2" style="margin:0;display:flex;align-items:center"><span style="flex:1">参数</span><button class="pd-link" data-act="pe-add-param">+ 添加参数</button></div><div id="pe-params">' + presetParamsEditor() + '</div>';
  }

  function presetParamsEditor() {
    return pe.params.map(function (p, i) {
      return '<div class="pd-pe-param" data-i="' + i + '"><div style="display:flex;gap:8px;align-items:center"><span class="pd-mono" style="color:var(--pd-accent);font-size:12px">' + (p.key ? '{{' + p.key + '}}' : '新参数') + '</span><span style="flex:1"></span>' +
        '<select class="pd-input" data-pef="type" style="height:28px"><option value="choice"' + (p.type === 'choice' ? ' selected' : '') + '>单选</option><option value="text"' + (p.type === 'text' ? ' selected' : '') + '>填写</option><option value="toggle"' + (p.type === 'toggle' ? ' selected' : '') + '>开关</option></select>' +
        '<button class="pd-icon-btn" data-act="pe-del-param" data-i="' + i + '" aria-label="删除参数">' + icon('trash', 16) + '</button></div>' +
        '<input class="pd-input" data-pef="label" placeholder="参数名称" value="' + esc(p.label || '') + '">' +
        (p.type === 'choice' ? '<input class="pd-input" data-pef="options" placeholder="选项，用逗号分隔" value="' + esc((p.options || []).join('，')) + '">' : '') +
        '<input class="pd-input" data-pef="def" placeholder="默认值" value="' + esc(p.def || '') + '"></div>';
    }).join('');
  }

  function readPresetEditor() {
    var rows = document.querySelectorAll('#pe-params .pd-pe-param');
    Array.prototype.forEach.call(rows, function (row, i) {
      var p = pe.params[i];
      if (!p) { return; }
      var f = function (n) { var el = row.querySelector('[data-pef="' + n + '"]'); return el ? el.value : ''; };
      p.type = f('type') || 'text';
      p.label = f('label');
      p.def = f('def');
      p.options = p.type === 'choice' ? f('options').split(/[,，、\n]/).map(function (s) { return s.trim(); }).filter(Boolean) : [];
    });
  }

  function savePreset() {
    readPresetEditor();
    var name = document.getElementById('pe-name').value.trim(), prompt = document.getElementById('pe-prompt').value.trim();
    if (!name || !prompt) { c.toast('名称和系统提示词不能为空'); return; }
    // 原有参数沿用原来的键，提示词里的 {{键}} 不会失效；新参数用不重复的 p 序号
    var used = {}, seq = 0;
    pe.params.forEach(function (p) { if (p.key) { used[p.key] = true; } });
    var fresh = function () { var k; do { k = 'p' + (++seq); } while (used[k]); used[k] = true; return k; };
    var params = pe.params.filter(function (p) { return p.label.trim(); }).map(function (p) {
      return { key: p.key || fresh(), label: p.label.trim(), type: p.type, options: p.options, def: String(p.def || '').trim(), hint: p.hint || '' };
    });
    var t = { id: pe.id || 'custom-' + Date.now(), name: name, desc: document.getElementById('pe-desc').value.trim(), icon: pe.icon, color: pe.color, prompt: prompt, params: params };
    if (pe.builtIn) { t.override = true; }
    var req = pe.libraryId ? c.api('PATCH', P + '/api/library/' + encodeURIComponent(pe.libraryId), { title: name, body: JSON.stringify(t) }) :
      c.api('POST', P + '/api/library', { kind: 'preset', title: name, body: JSON.stringify(t), mime: 'application/json' });
    req.then(function () { c.closeModal(); c.toast('已保存'); pv.id = ''; return fetchKind('preset'); }).catch(function (e) { c.toast(e.message); });
  }

  /* ---------- 新建会话 ---------- */

  function relOf(ws, abs) {
    var win = ws.rootPath.indexOf('\\') >= 0, sep = win ? '\\' : '/';
    var root = ws.rootPath.slice(-1) === sep ? ws.rootPath : ws.rootPath + sep;
    if (abs.indexOf(root) !== 0) { return null; }
    var rel = abs.slice(root.length);
    return win ? rel.split(sep).join('/') : rel;
  }

  var ns = null;

  /**
   * newSession：新建会话对话框
   *
   * 选好工作目录（默认工作目录、已添加的工作区，或电脑上任意文件夹）后创建；
   * 预设助手另有「交给谁处理」与参数，创建时一并带上系统提示词。
   */
  X.newSession = function (o) {
    var h = c.host();
    if (o.kind === 'terminal' && h && h.config && h.config.features && !h.config.features.terminal) { c.toast('终端功能未开启，请在「设置 → 安全」里开启'); return; }
    c.api('GET', P + '/api/ws').then(function (list) {
      list = list || [];
      var spaces = list.filter(function (w) { return !w.system; });
      var system = list.filter(function (w) { return w.system; })[0] || null;
      var t = o.tpl || null;
      ns = { kind: o.kind || '', auto: !!o.auto, tpl: t, spaces: spaces, system: system, pick: spaces.length ? spaces[0].id : '', custom: null, values: t ? Object.assign(defaults(t), o.values || {}) : {} };
      if (t && !ns.kind) { ns.kind = o.agent || installedKinds()[0] || 'claude'; }
      if (!spaces.length && !system && !o.dir) { c.toast('请先在「设置 → 权限」里添加工作区'); ns = null; return; }
      nsRender();
    }).catch(function (e) { c.toast(e.message); });
  };

  function nsRender() {
    var t = ns.tpl;
    var kinds = installedKinds();
    var rows = ns.spaces.map(function (w) {
      return '<button class="pd-pick-row' + (ns.pick === w.id ? ' active' : '') + '" data-act="ns-pick" data-id="' + esc(w.id) + '">' + icon(w.isDefault ? 'folder-open' : 'folder', 16) +
        '<span style="flex:1;min-width:0"><div>' + esc(w.name) + (w.isDefault ? ' <span class="pd-muted" style="font-size:12px">默认</span>' : '') + '</div><div class="pd-path">' + esc(w.rootPath) + '</div></span></button>';
    }).join('');
    if (ns.custom) { rows += '<button class="pd-pick-row' + (ns.pick === '@custom' ? ' active' : '') + '" data-act="ns-pick" data-id="@custom">' + icon('folder-search', 16) + '<span style="flex:1;min-width:0"><div>' + esc(ns.custom.name) + '</div><div class="pd-path">' + esc(ns.custom.path) + '</div></span></button>'; }
    var title = t ? '用「' + t.name + '」新建会话' : (ns.kind === 'terminal' ? '新建终端' : '新建 ' + agentName(ns.kind) + (ns.auto ? ' 免审批' : '') + ' 会话');
    var body = (t ? '<div class="pd-field"><label>交给谁处理</label><div class="pd-seg">' + kinds.map(function (k) { return '<button class="' + (ns.kind === k ? 'active' : '') + '" data-act="ns-agent" data-kind="' + k + '">' + esc(agentName(k)) + '</button>'; }).join('') + '</div></div>' +
      (t.params && t.params.length ? '<div class="pd-form-grid" style="padding:0;border:0" id="ns-form">' + nsForm(t) + '</div>' : '') : '') +
      '<div class="pd-muted" style="font-size:12px">选择工作目录</div><div class="pd-pick-list">' + rows + '</div>' +
      '<button class="pd-btn" data-act="ns-folder" style="align-self:flex-start">' + icon('folder-search', 16) + '选择其他文件夹…</button>';
    c.modal(title, body, '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="ns-create">新建</button>');
  }

  function nsForm(t) {
    var v = ns.values;
    return (t.params || []).map(function (p) {
      var id = 'np-' + p.key;
      if (p.type === 'choice') { return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><select class="pd-input" id="' + id + '" data-nkey="' + p.key + '">' + p.options.map(function (o) { return '<option' + (o === v[p.key] ? ' selected' : '') + '>' + esc(o) + '</option>'; }).join('') + '</select></div>'; }
      if (p.type === 'toggle') { return '<div class="pd-field"><label class="pd-toggle-line"><input type="checkbox" id="' + id + '" data-nkey="' + p.key + '"' + (v[p.key] === '是' ? ' checked' : '') + '>' + esc(p.label) + '</label></div>'; }
      return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><input class="pd-input" id="' + id + '" data-nkey="' + p.key + '" value="' + esc(v[p.key] || '') + '" placeholder="' + esc(p.hint || '') + '"></div>';
    }).join('');
  }

  function pickFolder(then) {
    c.api('POST', '/admin/api/pick-folder', { prompt: '选择工作目录' }).then(function (r) {
      if (!r.path) { return; }
      c.api('GET', P + '/api/ws').then(function (list) {
        list = list || [];
        // 优先放进已有的工作区，其次放进「此电脑」
        var hit = null;
        list.filter(function (w) { return !w.system; }).forEach(function (w) { var rel = relOf(w, r.path); if (rel !== null && (!hit || w.rootPath.length > hit.ws.rootPath.length)) { hit = { ws: w, rel: rel }; } });
        if (!hit) { var sys = list.filter(function (w) { return w.system; })[0]; if (sys) { var rel2 = relOf(sys, r.path); if (rel2 !== null) { hit = { ws: sys, rel: rel2 }; } } }
        if (!hit) { c.toast('这个文件夹不在可用的工作区里，请先在「设置 → 权限」里添加工作区'); return; }
        then({ ws: hit.ws.id, cwd: hit.rel === '' ? '.' : hit.rel, path: r.path, name: r.name || r.path.split(/[\\/]/).pop() });
      });
    }).catch(function (e) { c.toast(e.message); });
  }

  /** createSession：按所选 Agent、目录创建会话（模板会话带上标题、系统提示词与参数），成功后进入 */
  function createSession(kind, wsId, cwd, auto, t, values) {
    var body = { kind: kind, workspaceId: wsId, cwd: cwd || '.', autoApprove: !!auto };
    if (kind === 'terminal') { body.cols = 100; body.rows = 30; delete body.autoApprove; }
    if (t) {
      body.title = t.name + ' · ' + agentName(kind);
      body.instruction = renderPrompt(t, values);
      body.preset = presetRef(t, values);
    }
    return c.api('POST', P + '/api/sessions', body).then(function (s) {
      if (t) { c.save('pd.preset.' + t.id, { agent: kind, values: values }); }
      c.closeModal();
      c.onCreated(s);
    }).catch(function (e) { c.toast(e.message); });
  }

  function nsCreate() {
    if (!ns) { return; }
    var wsId, cwd = '.';
    if (ns.pick === '@custom' && ns.custom) { wsId = ns.custom.ws; cwd = ns.custom.cwd; } else { wsId = ns.pick; }
    if (!wsId) { c.toast('请选择工作目录'); return; }
    createSession(ns.kind, wsId, cwd, ns.auto, ns.tpl, ns.values);
  }

  /** startPreset：预设助手页上直接开始对话，目录用页面上选的，没选时用默认工作目录 */
  function startPreset(tpl) {
    c.api('GET', P + '/api/ws').then(function (list) {
      var spaces = (list || []).filter(function (w) { return !w.system; });
      var def = spaces.filter(function (w) { return w.isDefault; })[0] || spaces[0];
      if (pv.dir) { return createSession(pv.agent, pv.dir.ws, pv.dir.cwd, false, tpl, pv.values); }
      if (!def) { c.toast('请先在「设置 → 权限」里添加工作区'); return null; }
      return createSession(pv.agent, def.id, '.', false, tpl, pv.values);
    }).catch(function (e) { c.toast(e.message); });
  }

  /** newMenu：「+」菜单——各 Agent、免审批、预设助手、接着电脑上的会话、文件传输助手、配对 */
  X.newMenu = function (x, y) {
    var kinds = installedKinds();
    var items = [['assistant', '新建文件传输助手', false, 'send'], ['resume', '接着电脑上的会话', false, 'history'], '-', '#新建会话'];
    kinds.forEach(function (k) { items.push(['new:' + k, '新建 ' + agentName(k) + ' 会话', false, 'message-square-plus']); });
    kinds.filter(function (k) { return k === 'claude' || k === 'codex'; }).forEach(function (k) { items.push(['auto:' + k, agentName(k) + ' 免审批', false, 'zap']); });
    var subs = allPresets().map(function (t) { return ['preset:' + t.id, t.name, false, ICONS[t.icon] || 'sparkles']; });
    subs.push(['presets', '全部预设助手…', false, 'users-round']);
    items.push(['terminal', '新建终端', false, 'terminal'], ['sub', '预设助手', false, 'users-round', subs], '-', ['screenshot', '截取电脑屏幕发到手机', false, 'monitor'], ['pair', '配对新手机', false, 'qr-code']);
    return c.popMenu(x, y, items).then(function (k) {
      if (!k) { return null; }
      if (k === 'presets') { c.go('contacts'); return null; }
      if (k === 'terminal') { X.newSession({ kind: 'terminal' }); return null; }
      if (k === 'screenshot') { c.api('POST', P + '/api/screenshot').then(function () { c.toast('已截屏，截图会发到手机的文件传输助手'); }).catch(function (e) { c.toast(e.message); }); return null; }
      var p = k.split(':');
      if (p[0] === 'new' || p[0] === 'auto') { X.newSession({ kind: p[1], auto: p[0] === 'auto' }); return null; }
      if (p[0] === 'preset') { var t = findPreset(p[1]); if (t) { var saved = c.load('pd.preset.' + t.id, null) || {}; X.newSession({ tpl: t, values: saved.values, agent: saved.agent }); } return null; }
      return k;
    });
  };

  /* ---------- 聊天里的模板会话 ---------- */

  /** presetHeadHtml：模板会话顶栏上的参数按钮 */
  X.presetHeadHtml = function (s) {
    return s && s.preset ? '<button class="pd-icon-btn" data-act="sess-preset" title="模板参数与换 Agent" aria-label="模板参数与换 Agent">' + icon('sliders-horizontal', 18) + '</button>' : '';
  };

  var sp = null;

  function sessionPresetDialog(s) {
    var ref = parsePreset(s.preset);
    if (!ref) { return; }
    var t = findPreset(ref.id);
    sp = { sid: s.id, t: t, values: Object.assign({}, ref.params || {}) };
    var others = installedKinds().filter(function (k) { return k !== s.kind; });
    var body = '<div style="display:flex;gap:12px;align-items:center"><div class="pd-avatar" style="background:' + colorCss(ref.color) + '">' + icon(ICONS[ref.icon] || 'sparkles', 20) + '</div><div><div style="font-weight:500">' + esc(ref.name) + '</div><div class="pd-muted" style="font-size:12px">由 ' + esc(agentName(s.kind)) + ' 处理</div></div></div>' +
      (t ? '<div class="pd-form-grid" style="padding:0;border:0" id="sp-form">' + (t.params || []).map(function (p) {
        var id = 'sp-' + p.key, v = sp.values;
        if (p.type === 'choice') { return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><select class="pd-input" id="' + id + '" data-skey="' + p.key + '">' + p.options.map(function (o) { return '<option' + (o === v[p.key] ? ' selected' : '') + '>' + esc(o) + '</option>'; }).join('') + '</select></div>'; }
        if (p.type === 'toggle') { return '<div class="pd-field"><label class="pd-toggle-line"><input type="checkbox" id="' + id + '" data-skey="' + p.key + '"' + (v[p.key] === '是' ? ' checked' : '') + '>' + esc(p.label) + '</label></div>'; }
        return '<div class="pd-field"><label for="' + id + '">' + esc(p.label) + '</label><input class="pd-input" id="' + id + '" data-skey="' + p.key + '" value="' + esc(v[p.key] || '') + '"></div>';
      }).join('') + '</div>' : '<div class="pd-muted">找不到这个模板，可能已被删除，参数无法修改。</div>') +
      (t && others.length ? '<div class="pd-field"><label>换 Agent 处理（用同样的模板和参数新开一个会话）</label><div class="pd-seg">' + others.map(function (k) { return '<button data-act="sp-switch" data-kind="' + k + '">' + esc(agentName(k)) + '</button>'; }).join('') + '</div></div>' : '');
    c.modal('模板参数', body, '<button class="pd-btn" data-act="modal-close">关闭</button>' + (t ? '<button class="pd-btn pd-btn-primary" data-act="sp-apply">应用参数</button>' : ''));
  }

  /* ---------- 终端 ---------- */

  var term = null;

  /** detachTerminal：离开终端页时断开连接、释放终端 */
  X.detachTerminal = function () {
    if (!term) { return; }
    clearInterval(term.timer);
    if (term.ro) { term.ro.disconnect(); }
    term.ws.onclose = null;
    try { term.ws.close(); } catch (e) { /* 已关闭 */ }
    term.t.dispose();
    term = null;
  };

  /** terminalHtml：终端页（顶栏与终端区域） */
  X.terminalHtml = function (s) {
    return '<header class="pd-head"><div class="pd-head-main"><div class="pd-head-title">' + esc(c.title(s)) + '</div><div class="pd-head-sub">' + esc(s.cwd && s.cwd !== '.' ? s.cwd : '工作区根目录') + '</div></div>' +
      '<div class="pd-head-acts"><button class="pd-btn pd-btn-danger" data-act="term-close">' + icon('x', 16) + '结束终端</button></div></header><div class="pd-term" id="term"></div>';
  };

  /**
   * attachTerminal：连上电脑上的终端
   *
   * 输出以二进制推过来直接写进终端；按键以二进制发回；窗口大小变化时发送 resize；每 25 秒发一次心跳。
   */
  X.attachTerminal = function (s) {
    X.detachTerminal();
    var box = document.getElementById('term');
    if (!box || !window.Terminal) { return; }
    var t = new window.Terminal({ fontFamily: '"SF Mono", Menlo, Consolas, monospace', fontSize: 13, lineHeight: 1.15, cursorBlink: true, scrollback: 5000, theme: { background: '#1E1E1E', foreground: '#D8D8D8' } });
    var fit = window.FitAddon ? new window.FitAddon.FitAddon() : null;
    if (fit) { t.loadAddon(fit); }
    t.open(box);
    if (fit) { try { fit.fit(); } catch (e) { /* 尺寸为零时忽略 */ } }
    var ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + P + '/term/' + encodeURIComponent(s.id));
    ws.binaryType = 'arraybuffer';
    var enc = new TextEncoder();
    var send = function (m) { if (ws.readyState === 1) { ws.send(m); } };
    ws.onopen = function () { send(JSON.stringify({ type: 'resize', cols: t.cols, rows: t.rows })); };
    ws.onmessage = function (ev) {
      if (typeof ev.data !== 'string') { t.write(new Uint8Array(ev.data)); return; }
      var m;
      try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.type === 'exit') { t.write('\r\n\x1b[90m[终端已结束]\x1b[0m\r\n'); }
    };
    ws.onclose = function () { if (term && term.ws === ws) { t.write('\r\n\x1b[90m[连接已断开，重新打开这个会话可以接着用]\x1b[0m\r\n'); } };
    t.onData(function (d) { send(enc.encode(d)); });
    t.onResize(function (sz) { send(JSON.stringify({ type: 'resize', cols: sz.cols, rows: sz.rows })); });
    var ro = window.ResizeObserver && fit ? new ResizeObserver(function () { try { fit.fit(); } catch (e) { /* 忽略 */ } }) : null;
    if (ro) { ro.observe(box); }
    term = { t: t, ws: ws, ro: ro, timer: setInterval(function () { send(JSON.stringify({ type: 'ping' })); }, 25000) };
    t.focus();
  };

  /* ---------- 看图窗口 ---------- */

  var vz = null;

  function vzApply() {
    var img = document.getElementById('vimg');
    if (!img || !vz) { return; }
    img.style.transform = 'translate(' + vz.x + 'px,' + vz.y + 'px) scale(' + vz.s + ')';
    var pct = document.getElementById('vz-pct');
    if (pct) { pct.textContent = Math.round(vz.s * 100) + '%'; }
    var st = document.getElementById('vstage');
    if (st) { st.classList.toggle('zoomed', vz.s > 1.02); }
  }

  /** vzClamp：放大后图片不能被拖出视野 */
  function vzClamp() {
    var st = document.getElementById('vstage'), img = document.getElementById('vimg');
    if (!st || !img || !vz) { return; }
    var w = img.offsetWidth * vz.s, h = img.offsetHeight * vz.s;
    var mx = Math.max(0, (w - st.clientWidth) / 2), my = Math.max(0, (h - st.clientHeight) / 2);
    vz.x = Math.max(-mx, Math.min(mx, vz.x));
    vz.y = Math.max(-my, Math.min(my, vz.y));
  }

  /** vzZoom：以舞台中的某一点为中心缩放（不给点时用中心） */
  function vzZoom(factor, px, py) {
    var st = document.getElementById('vstage');
    if (!st || !vz) { return; }
    var next = Math.max(0.1, Math.min(8, vz.s * factor)), k = next / vz.s;
    var r = st.getBoundingClientRect();
    var cx = (px === undefined ? r.left + r.width / 2 : px) - (r.left + r.width / 2);
    var cy = (py === undefined ? r.top + r.height / 2 : py) - (r.top + r.height / 2);
    vz.x = cx - (cx - vz.x) * k;
    vz.y = cy - (cy - vz.y) * k;
    vz.s = next;
    if (next <= 1) { vz.x = vz.y = 0; }
    vzClamp();
    vzApply();
  }

  /**
   * viewer：看图窗口，关闭与操作按钮在右上角，底部有放大、缩小、还原按钮（10% 到 800%），
   * 也能用滚轮、双击、双指捏合缩放，放大后拖动平移
   */
  X.viewer = function (name, src, actions, seq) {
    vz = { s: 1, x: 0, y: 0, pts: {}, pinch: 0 };
    c.modalRoot.innerHTML = '<div class="pd-viewer" role="dialog" aria-modal="true" aria-label="' + esc(name) + '">' +
      '<div class="pd-viewer-top"><div class="pd-viewer-title">' + esc(name) + '</div><div class="pd-actions">' + (actions || '') +
      '<button class="pd-viewer-btn" data-act="modal-close" title="关闭" aria-label="关闭">' + icon('x', 20) + '</button></div></div>' +
      '<div class="pd-viewer-stage" id="vstage"><img id="vimg" alt="' + esc(name) + '"' + (seq ? ' data-seq="' + seq + '"' : '') + ' src="' + src + '" draggable="false"></div>' +
      '<div class="pd-viewer-zoom"><button data-act="vz-out" title="缩小" aria-label="缩小">' + icon('minus', 18) + '</button><button data-act="vz-reset" id="vz-pct" title="还原">100%</button><button data-act="vz-in" title="放大" aria-label="放大">' + icon('plus', 18) + '</button></div></div>';
  };

  document.addEventListener('wheel', function (e) {
    var st = e.target.closest && e.target.closest('#vstage');
    if (!st || !vz) { return; }
    e.preventDefault();
    vzZoom(e.deltaY < 0 ? 1.15 : 1 / 1.15, e.clientX, e.clientY);
  }, { passive: false });
  document.addEventListener('dblclick', function (e) {
    if (!vz || !e.target.closest || !e.target.closest('#vstage')) { return; }
    if (Math.abs(vz.s - 1) > 0.02) { vz.s = 1; vz.x = vz.y = 0; vzApply(); } else { vzZoom(2.5, e.clientX, e.clientY); }
  });
  document.addEventListener('pointerdown', function (e) {
    if (!vz || !e.target.closest || !e.target.closest('#vstage')) { return; }
    vz.pts[e.pointerId] = { x: e.clientX, y: e.clientY };
    vz.drag = false;
    var ids = Object.keys(vz.pts);
    if (ids.length === 2) { vz.pinch = Math.hypot(vz.pts[ids[0]].x - vz.pts[ids[1]].x, vz.pts[ids[0]].y - vz.pts[ids[1]].y); }
  });
  document.addEventListener('pointermove', function (e) {
    if (!vz || !vz.pts[e.pointerId]) { return; }
    var prev = vz.pts[e.pointerId];
    vz.pts[e.pointerId] = { x: e.clientX, y: e.clientY };
    var ids = Object.keys(vz.pts);
    if (ids.length === 2) {
      var d = Math.hypot(vz.pts[ids[0]].x - vz.pts[ids[1]].x, vz.pts[ids[0]].y - vz.pts[ids[1]].y);
      if (vz.pinch > 0 && d > 0) { vzZoom(d / vz.pinch, (vz.pts[ids[0]].x + vz.pts[ids[1]].x) / 2, (vz.pts[ids[0]].y + vz.pts[ids[1]].y) / 2); }
      vz.pinch = d;
    } else if (ids.length === 1 && vz.s > 1.02) {
      vz.x += e.clientX - prev.x;
      vz.y += e.clientY - prev.y;
      vz.drag = true;
      vzClamp();
      vzApply();
    }
  });
  function pointerEnd(e) { if (vz && vz.pts[e.pointerId]) { delete vz.pts[e.pointerId]; vz.pinch = 0; } }
  document.addEventListener('pointerup', pointerEnd);
  document.addEventListener('pointercancel', pointerEnd);
  document.addEventListener('keydown', function (e) {
    if (!vz || !document.getElementById('vstage')) { return; }
    if (e.key === '+' || e.key === '=') { vzZoom(1.25); } else if (e.key === '-') { vzZoom(0.8); } else if (e.key === '0') { vz.s = 1; vz.x = vz.y = 0; vzApply(); }
  });

  /* ---------- 点击与输入 ---------- */

  function val(id) { var el = document.getElementById(id); return el ? el.value : ''; }

  /** act：处理本模块的操作，已处理返回 true */
  X.act = function (act, t, e) {
    var id = t.dataset.id;
    switch (act) {
      // 风格与头像
      case 'style-set': c.save('pd.style', id); X.applyStyle(); c.redrawAll(); return true;
      case 'av-open': pickAvatar(t.dataset.key, t.dataset.title || '设置头像'); return true;
      case 'av-set': setAvatar(t.dataset.key, t.dataset.spec); return true;
      case 'av-default': setAvatar(t.dataset.key, ''); return true;
      case 'av-upload': { var f = document.getElementById('av-file'); if (f) { f.click(); } return true; }
      // 剪切板
      case 'clip-add': {
        var text = val('clip-text');
        if (!text.trim()) { c.toast('先输入内容'); return true; }
        addText('clip', text).then(function () { var el = document.getElementById('clip-text'); if (el) { el.value = ''; } c.toast('已放进剪切板'); }).catch(function (er) { c.toast(er.message); });
        return true;
      }
      case 'clip-paste':
        if (navigator.clipboard && navigator.clipboard.read) {
          navigator.clipboard.read().then(function (items) {
            var jobs = [];
            items.forEach(function (it) {
              var img = it.types.filter(function (ty) { return ty.indexOf('image/') === 0; })[0];
              if (img) { jobs.push(it.getType(img).then(function (b) { return addBlob('clip', new File([b], '粘贴图片.' + img.split('/')[1], { type: img })); })); }
              else if (it.types.indexOf('text/plain') >= 0) { jobs.push(it.getType('text/plain').then(function (b) { return b.text(); }).then(function (tx) { return tx.trim() ? addText('clip', tx) : null; })); }
            });
            return Promise.all(jobs);
          }).then(function () { c.toast('已放进剪切板'); }).catch(function () {
            if (navigator.clipboard.readText) { navigator.clipboard.readText().then(function (tx) { if (tx.trim()) { return addText('clip', tx).then(function () { c.toast('已放进剪切板'); }); } c.toast('剪贴板里没有内容'); }).catch(function () { c.toast('无法读取剪贴板，请在输入框里按粘贴键'); }); }
          });
        } else { c.toast('当前环境不能直接读取剪贴板，请在输入框里按粘贴键'); }
        return true;
      case 'clip-file': { var cf = document.getElementById('clip-file'); if (cf) { cf.click(); } return true; }
      case 'clip-copy': c.copyText((item('clip', id) || {}).body || ''); return true;
      case 'clip-copy-img': copyImage(item('clip', id)); return true;
      case 'clip-download': download(item('clip', id)); return true;
      case 'clip-fav': {
        var x = item('clip', id);
        if (!x) { return true; }
        if (x.size) {
          fetch(blobUrl(x.id), { credentials: 'same-origin' }).then(function (r) { return r.blob(); }).then(function (b) { return addBlob('fav', new File([b], x.name || '文件', { type: x.mime }), '来自剪切板'); }).then(function () { c.toast('已收藏'); }).catch(function (er) { c.toast(er.message); });
        } else { X.favoriteText(x.body, '来自剪切板'); }
        return true;
      }
      case 'clip-pin': case 'fav-pin': case 'prompt-pin': {
        var k = act.split('-')[0], y = item(k, id);
        if (y) { c.api('PATCH', P + '/api/library/' + encodeURIComponent(id), { pinned: !y.pinned }).catch(function (er) { c.toast(er.message); }); }
        return true;
      }
      case 'clip-del': case 'fav-del': case 'prompt-del': {
        var what = { clip: ['删除这条内容', '手机上的剪切板也会同时删除。', '删除'], fav: ['取消收藏', '手机上的收藏夹也会同时删除。', '取消收藏'], prompt: ['删除这条提示词', '手机上的提示词也会同时删除。', '删除'] }[act.split('-')[0]];
        c.confirmBox(what[0], what[1], what[2], function () {
          c.api('DELETE', P + '/api/library/' + encodeURIComponent(id)).then(function () { c.toast('已删除'); }).catch(function (er) { c.toast(er.message); });
        });
        return true;
      }
      case 'clip-clear': c.confirmBox('清空剪切板', '置顶的内容会保留，其余全部删除。', '清空', function () { c.api('DELETE', P + '/api/library?kind=clip').then(function () { c.toast('已清空'); }).catch(function (er) { c.toast(er.message); }); }); return true;
      case 'clip-view': case 'fav-view': {
        var z = item(act === 'clip-view' ? 'clip' : 'fav', id);
        if (z) { X.viewer(z.name || '图片', blobUrl(z.id), '<button class="pd-btn" data-act="clip-download" data-id="' + z.id + '">' + icon('download', 16) + '下载</button>'); }
        return true;
      }
      // 收藏
      case 'fav-add': {
        c.modal('新建收藏', '<div class="pd-field"><label for="fa-title">标题</label><input class="pd-input" id="fa-title"></div><div class="pd-field"><label for="fa-body">内容</label><textarea class="pd-input" id="fa-body" style="height:180px;padding:8px 10px;resize:vertical"></textarea></div>',
          '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="fav-save">保存</button>');
        return true;
      }
      case 'fav-save': {
        var fb = val('fa-body');
        if (!fb.trim() && !val('fa-title').trim()) { c.toast('内容不能为空'); return true; }
        addText('fav', fb, val('fa-title').trim()).then(function () { c.closeModal(); c.toast('已收藏'); }).catch(function (er) { c.toast(er.message); });
        return true;
      }
      case 'fav-copy': c.copyText((item('fav', id) || {}).body || ''); return true;
      case 'fav-download': download(item('fav', id)); return true;
      case 'fav-rename': {
        var fr = item('fav', id);
        c.modal('重命名', '<div class="pd-field"><label for="fr-title">标题</label><input class="pd-input" id="fr-title" value="' + esc(fr ? fr.title : '') + '"></div>', '<button class="pd-btn" data-act="modal-close">取消</button><button class="pd-btn pd-btn-primary" data-act="fav-rename-ok" data-id="' + esc(id) + '">确定</button>');
        return true;
      }
      case 'fav-rename-ok': c.api('PATCH', P + '/api/library/' + encodeURIComponent(id), { title: val('fr-title').trim() }).then(function () { c.closeModal(); }).catch(function (er) { c.toast(er.message); }); return true;
      // 提示词
      case 'prompt-add': promptEditor(null); return true;
      case 'prompt-edit': promptEditor(item('prompt', id)); return true;
      case 'prompt-save': {
        var pb = val('pe-body');
        if (!pb.trim() && !val('pe-title').trim()) { c.toast('内容不能为空'); return true; }
        var req = id ? c.api('PATCH', P + '/api/library/' + encodeURIComponent(id), { title: val('pe-title').trim(), body: pb, meta: val('pe-meta').trim() }) :
          c.api('POST', P + '/api/library', { kind: 'prompt', title: val('pe-title').trim(), body: pb, meta: val('pe-meta').trim(), mime: 'text/plain' });
        req.then(function () { c.closeModal(); c.toast('已保存'); }).catch(function (er) { c.toast(er.message); });
        return true;
      }
      case 'prompt-copy': c.copyText((item('prompt', id) || {}).body || ''); return true;
      case 'prompt-pick': promptPicker(); return true;
      case 'prompt-use': {
        var pu = item('prompt', id), inp = document.getElementById('input');
        c.closeModal();
        if (pu && inp) { inp.value = (inp.value ? inp.value + '\n' : '') + pu.body; inp.dispatchEvent(new Event('input', { bubbles: true })); inp.focus(); }
        return true;
      }
      // 通讯录
      case 'contact-new': X.newSession({ kind: t.dataset.kind, auto: t.dataset.auto === '1' }); return true;
      case 'preset-agent': pv.agent = t.dataset.kind; c.redrawMain(); return true;
      case 'preset-show': pv.show = !pv.show; c.redrawMain(); return true;
      case 'preset-dir': pickFolder(function (d) { pv.dir = { ws: d.ws, cwd: d.cwd, path: d.path, name: d.name, label: d.path }; c.redrawMain(); }); return true;
      case 'preset-start': {
        var tpl = findPreset(id);
        if (!tpl) { return true; }
        startPreset(tpl);
        return true;
      }
      case 'preset-new': presetEditor(null, false); return true;
      case 'preset-edit': presetEditor(findPreset(id), false); return true;
      case 'preset-copy': presetEditor(findPreset(id), true); return true;
      case 'preset-del': {
        var pt = findPreset(id);
        if (pt && pt.libraryId) { c.confirmBox('删除「' + esc(pt.name) + '」', '已经开始的对话不受影响。', '删除', function () { c.api('DELETE', P + '/api/library/' + encodeURIComponent(pt.libraryId)).then(function () { c.go('contacts'); }).catch(function (er) { c.toast(er.message); }); }); }
        return true;
      }
      case 'preset-save': savePreset(); return true;
      case 'preset-reset': {
        var rt = findPreset(id);
        if (rt && rt.libraryId) {
          c.confirmBox('恢复「' + esc(rt.name) + '」的默认设置', '改过的提示词和参数会被丢弃，换回出厂版本。已经开始的对话不受影响。', '恢复默认', function () {
            c.api('DELETE', P + '/api/library/' + encodeURIComponent(rt.libraryId)).then(function () { pv.id = ''; c.toast('已恢复默认'); return fetchKind('preset'); }).catch(function (er) { c.toast(er.message); });
          });
        }
        return true;
      }
      case 'pe-icon': readPresetEditor(); pe.icon = t.dataset.icon; Array.prototype.forEach.call(document.querySelectorAll('#pe-icons .pd-icon-btn'), function (b) { b.classList.toggle('pd-icon-on', b === t); }); return true;
      case 'pe-color': pe.color = +t.dataset.color; Array.prototype.forEach.call(document.querySelectorAll('#pe-colors .pd-color'), function (b) { b.classList.toggle('on', b === t); }); return true;
      case 'pe-add-param': readPresetEditor(); pe.params.push({ key: '', label: '', type: 'choice', options: [], def: '' }); document.getElementById('pe-params').innerHTML = presetParamsEditor(); return true;
      case 'pe-del-param': readPresetEditor(); pe.params.splice(+t.dataset.i, 1); document.getElementById('pe-params').innerHTML = presetParamsEditor(); return true;
      // 新建会话
      case 'ns-pick': ns.pick = id; nsRead(); nsRender(); return true;
      case 'ns-agent': nsRead(); ns.kind = t.dataset.kind; nsRender(); return true;
      case 'ns-folder': nsRead(); pickFolder(function (d) { ns.custom = d; ns.pick = '@custom'; nsRender(); }); return true;
      case 'ns-create': nsRead(); nsCreate(); return true;
      // 模板会话
      case 'sess-preset': { var cs = c.session(c.route().sid); if (cs) { sessionPresetDialog(cs); } return true; }
      case 'sp-apply': spApply(); return true;
      case 'sp-switch': spSwitch(t.dataset.kind); return true;
      // 终端
      case 'term-close': {
        var ts = c.session(c.route().sid);
        if (!ts) { return true; }
        c.confirmBox('结束终端', '结束后终端里正在运行的程序也会停止。', '结束', function () {
          X.detachTerminal();
          c.api('DELETE', P + '/api/sessions/' + encodeURIComponent(ts.id)).then(function () { c.toast('已结束'); c.removeSession(ts.id); }).catch(function (er) { c.toast(er.message); });
        });
        return true;
      }
      // 看图
      case 'vz-in': vzZoom(1.6); return true;
      case 'vz-out': vzZoom(1 / 1.6); return true;
      case 'vz-reset': if (vz) { vz.s = 1; vz.x = vz.y = 0; vzApply(); } return true;
    }
    return false;
  };

  function nsRead() {
    if (!ns || !ns.tpl) { return; }
    Array.prototype.forEach.call(document.querySelectorAll('[data-nkey]'), function (el) {
      ns.values[el.dataset.nkey] = el.type === 'checkbox' ? (el.checked ? '是' : '否') : el.value;
    });
  }

  function spRead() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-skey]'), function (el) {
      sp.values[el.dataset.skey] = el.type === 'checkbox' ? (el.checked ? '是' : '否') : el.value;
    });
  }

  function spApply() {
    if (!sp || !sp.t) { return; }
    spRead();
    c.api('PATCH', P + '/api/sessions/' + encodeURIComponent(sp.sid), { instruction: renderPrompt(sp.t, sp.values), preset: presetRef(sp.t, sp.values) }).then(function (s2) {
      var s = c.session(sp.sid);
      if (s) { Object.assign(s, s2); }
      c.closeModal();
      c.toast('参数已更新，从下一条消息起生效');
    }).catch(function (er) { c.toast(er.message); });
  }

  function spSwitch(kind) {
    if (!sp || !sp.t) { return; }
    spRead();
    var s = c.session(sp.sid), t = sp.t, values = sp.values;
    if (!s) { return; }
    var last = c.lastUserText(sp.sid);
    var go = function (carry) {
      c.closeModal();
      c.api('POST', P + '/api/sessions', { kind: kind, workspaceId: s.workspaceId, cwd: s.cwd || '.', autoApprove: false, title: t.name + ' · ' + agentName(kind), instruction: renderPrompt(t, values), preset: presetRef(t, values) }).then(function (s2) {
        c.onCreated(s2);
        if (carry && last) { c.api('POST', P + '/api/sessions/' + encodeURIComponent(s2.id) + '/messages', { text: last, attachments: [], clientId: 'desk-' + Date.now() }).catch(function () {}); }
      }).catch(function (er) { c.toast(er.message); });
    };
    if (last) { c.confirmBox('换成 ' + agentName(kind) + ' 处理', '把刚才的输入也发过去吗？', '发过去', function () { go(true); }); document.querySelector('#modal-root .pd-dialog-foot').insertAdjacentHTML('afterbegin', '<button class="pd-btn" id="sp-nocarry">不发</button>'); var nb = document.getElementById('sp-nocarry'); if (nb) { nb.onclick = function () { go(false); }; } } else { go(false); }
  }

  /** onChange：本模块的表单变化 */
  X.onChange = function (el) {
    if (el.id === 'av-file' && el.files && el.files[0]) {
      var key = el.dataset.key;
      squareImage(el.files[0], 160, function (url) { setAvatar(key, url); });
      el.value = '';
      return true;
    }
    if (el.id === 'clip-file') { var files = Array.prototype.slice.call(el.files || []); el.value = ''; X.addFiles(files); return true; }
    if (el.dataset && el.dataset.pkey) {
      pv.values[el.dataset.pkey] = el.type === 'checkbox' ? (el.checked ? '是' : '否') : el.value;
      var pre = document.getElementById('pp-prompt');
      var tt = findPreset(pv.id);
      if (pre && tt) { pre.textContent = renderPrompt(tt, pv.values); }
      return true;
    }
    if (el.dataset && el.dataset.pef) {
      readPresetEditor();
      if (el.dataset.pef === 'type') { document.getElementById('pe-params').innerHTML = presetParamsEditor(); }
      return true;
    }
    return false;
  };

  /** onInput：搜索框与剪切板输入框 */
  X.onInput = function (el) {
    if (el.id === 'fav-search') { query.fav = el.value; c.redrawMain(true); return true; }
    if (el.id === 'prompt-search') { query.prompt = el.value; c.redrawMain(true); return true; }
    if (el.id === 'contact-search') { query.contact = el.value; c.redrawList(); return true; }
    if (el.dataset && el.dataset.pkey) { return X.onChange(el); }
    return false;
  };

  document.addEventListener('keydown', function (e) {
    if (e.target && e.target.id === 'clip-text' && e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      var b = document.querySelector('[data-act="clip-add"]');
      if (b) { b.click(); }
    }
  });
})();
