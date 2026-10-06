/**
 * 通讯录预设模板：翻译、OCR 识别等带系统提示词与参数的助手。每个模板可以交给任意一个 Agent 处理，
 * 开始对话时把参数填进提示词，之后每一轮都由电脑端把这段提示词放在用户输入前面。
 */
library;

import 'dart:convert';

/** PresetParamType：参数的填写方式 */
enum PresetParamType { choice, text, toggle }

/** PresetParam：模板的一个参数 */
class PresetParam {
  const PresetParam(this.key, this.label, this.type, {this.options = const [], this.def = '', this.hint = ''});

  final String key;
  final String label;
  final PresetParamType type;

  /** 单选项（type 为 choice 时） */
  final List<String> options;

  /** 默认值；开关用「是」「否」 */
  final String def;
  final String hint;

  Map<String, dynamic> toJson() => {'key': key, 'label': label, 'type': type.name, if (options.isNotEmpty) 'options': options, if (def.isNotEmpty) 'def': def, if (hint.isNotEmpty) 'hint': hint};

  factory PresetParam.fromJson(Map<String, dynamic> j) => PresetParam(
        '${j['key'] ?? ''}',
        '${j['label'] ?? ''}',
        PresetParamType.values.firstWhere((t) => t.name == j['type'], orElse: () => PresetParamType.text),
        options: [for (final o in (j['options'] as List? ?? const [])) '$o'],
        def: '${j['def'] ?? ''}',
        hint: '${j['hint'] ?? ''}',
      );
}

/** PresetTemplate：一个预设助手 */
class PresetTemplate {
  const PresetTemplate({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.color,
    required this.prompt,
    this.params = const [],
    this.builtIn = true,
    this.libraryId = '',
    this.overridden = false,
  });

  final String id;
  final String name;
  final String desc;

  /** 图标键，对应界面里的图标表 */
  final String icon;

  /** 头像底色（ARGB 整数） */
  final int color;

  /** 系统提示词，参数写成 {{参数键}} */
  final String prompt;
  final List<PresetParam> params;
  final bool builtIn;

  /** 自定义模板或改过的内置模板在资料库中的编号（没改过的内置模板为空） */
  final String libraryId;

  /** 内置模板被改过（提示词或参数），可以恢复默认 */
  final bool overridden;

  /** asOverride：把资料库里保存的改动当作同编号内置模板的新版本 */
  PresetTemplate asOverride() => PresetTemplate(id: id, name: name, desc: desc, icon: icon, color: color, prompt: prompt, params: params, builtIn: true, libraryId: libraryId, overridden: true);

  /** defaults：全部参数的默认值 */
  Map<String, String> get defaults => {for (final p in params) p.key: p.def.isNotEmpty ? p.def : (p.options.isNotEmpty ? p.options.first : '')};

  /**
   * render：把参数值填进系统提示词
   *
   * 提示词里没引用到的参数不会丢，统一追加在末尾；空值的参数写「未指定」。
   */
  String render(Map<String, String> values) {
    final v = {...defaults, ...values};
    var out = prompt;
    final used = <String>{};
    for (final p in params) {
      final token = '{{${p.key}}}';
      if (out.contains(token)) {
        used.add(p.key);
        out = out.replaceAll(token, (v[p.key] ?? '').trim().isEmpty ? '未指定' : v[p.key]!.trim());
      }
    }
    final rest = [for (final p in params) if (!used.contains(p.key) && (v[p.key] ?? '').trim().isNotEmpty) '${p.label}：${v[p.key]!.trim()}'];
    if (rest.isNotEmpty) out = '$out\n\n补充要求：\n${rest.map((e) => '- $e').join('\n')}';
    return out;
  }

  /** ref：写进会话的模板标识与参数（JSON），界面据此显示头像与参数 */
  String ref(Map<String, String> values) => jsonEncode({'id': id, 'name': name, 'icon': icon, 'color': color, 'params': {...defaults, ...values}});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'desc': desc, 'icon': icon, 'color': color, 'prompt': prompt, 'params': [for (final p in params) p.toJson()], if (builtIn) 'override': true};

  factory PresetTemplate.fromJson(Map<String, dynamic> j, {String libraryId = ''}) => PresetTemplate(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        desc: '${j['desc'] ?? ''}',
        icon: '${j['icon'] ?? 'sparkles'}',
        color: (j['color'] as num?)?.toInt() ?? 0xFF6B5BFF,
        prompt: '${j['prompt'] ?? ''}',
        params: [for (final p in (j['params'] as List? ?? const [])) if (p is Map) PresetParam.fromJson(Map<String, dynamic>.from(p))],
        builtIn: false,
        libraryId: libraryId,
      );

  /** tryParse：从资料库里的文字读出模板，格式不对时返回空 */
  static PresetTemplate? tryParse(String body, {String libraryId = ''}) {
    try {
      final j = jsonDecode(body);
      if (j is Map && '${j['name'] ?? ''}'.isNotEmpty) return PresetTemplate.fromJson(Map<String, dynamic>.from(j), libraryId: libraryId);
    } on FormatException {
      return null;
    }
    return null;
  }
}

/** PresetRef：会话里记录的模板标识与参数 */
class PresetRef {
  const PresetRef({required this.id, required this.name, required this.icon, required this.color, required this.params});

  final String id;
  final String name;
  final String icon;
  final int color;
  final Map<String, String> params;

  /** parse：读取会话的 preset 字段，不是模板会话时返回空 */
  static PresetRef? parse(String raw) {
    if (raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return PresetRef(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        icon: '${j['icon'] ?? 'sparkles'}',
        color: (j['color'] as num?)?.toInt() ?? 0xFF6B5BFF,
        params: {for (final e in ((j['params'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
      );
    } on FormatException {
      return null;
    }
  }
}

const _yes = '是';
const _no = '否';

/** builtinPresets：内置预设助手 */
const builtinPresets = <PresetTemplate>[
  PresetTemplate(
    id: 'translate',
    name: '翻译',
    desc: '文字、文件、图片里的文字都能翻，保留原有排版',
    icon: 'languages',
    color: 0xFF2F7BFA,
    prompt: '你是专业翻译。把用户发来的内容翻译成{{target}}。\n'
        '- 内容来源：用户直接输入的文字；若带有文件或图片附件，先读取其中的文字再翻译。\n'
        '- 风格：{{style}}。\n'
        '- 保留原文的段落、列表、表格、代码块与链接格式：{{keep}}。代码块里的代码不翻译，只翻译注释。\n'
        '- 专有名词、人名、品牌名保持原文，必要时在括号里附原文；用户给出的术语表优先：{{glossary}}。\n'
        '- 原文已经是{{target}}时，改为润色成更通顺的表达，并说明这一点。\n'
        '- 只输出译文，不加解释、不加前后缀；遇到有歧义的地方，在译文末尾另起一行用「注：」简短说明。',
    params: [
      PresetParam('target', '目标语言', PresetParamType.choice, options: ['中文', '英文', '日文', '韩文', '法文', '德文', '西班牙文', '俄文'], def: '英文'),
      PresetParam('style', '翻译风格', PresetParamType.choice, options: ['自然流畅', '准确直译', '正式书面', '口语化', '文学优美'], def: '自然流畅'),
      PresetParam('keep', '保留原有格式', PresetParamType.toggle, def: _yes),
      PresetParam('glossary', '术语表', PresetParamType.text, hint: '例如：token=词元；agent=智能体'),
    ],
  ),
  PresetTemplate(
    id: 'ocr',
    name: 'OCR 识别',
    desc: '把图片、截图、扫描件里的文字原样识别出来',
    icon: 'scanText',
    color: 0xFF10A37F,
    prompt: '你是 OCR 文字识别助手。用户会发来图片、截图或扫描 PDF（以附件文件的形式给出，请直接打开文件查看内容）。\n'
        '- 逐字识别其中的全部文字，识别语言：{{lang}}。不要概括、不要改写、不要漏行，看不清的字用「□」占位并在末尾说明位置。\n'
        '- 输出格式：{{format}}。表格按 Markdown 表格输出，公式按 LaTeX 输出，手写体尽量识别并标注「（手写）」。\n'
        '- 保留阅读顺序与段落层次：{{layout}}；多栏版面按栏依次输出。\n'
        '- 识别完成后，如需要翻译成：{{translate}}，在识别结果下方另起一节给出译文；选「不翻译」则不输出译文。\n'
        '- 只输出识别结果本身，不加「以下是识别结果」之类的前缀。没有收到图片或文件时，直接提示用户先发送图片。',
    params: [
      PresetParam('lang', '识别语言', PresetParamType.choice, options: ['自动判断', '中文', '英文', '中英混合', '日文', '韩文'], def: '自动判断'),
      PresetParam('format', '输出格式', PresetParamType.choice, options: ['纯文本', 'Markdown', '保留表格（Markdown 表格）', 'JSON 结构化（按块列出文字与位置）'], def: '纯文本'),
      PresetParam('layout', '保留排版', PresetParamType.toggle, def: _yes),
      PresetParam('translate', '同时翻译成', PresetParamType.choice, options: ['不翻译', '中文', '英文', '日文'], def: '不翻译'),
    ],
  ),
  PresetTemplate(
    id: 'polish',
    name: '润色改写',
    desc: '改得更通顺、更得体，原意不变',
    icon: 'wandSparkles',
    color: 0xFFE0569B,
    prompt: '你是文字编辑。对用户发来的文字做润色改写。\n'
        '- 目标风格：{{tone}}；篇幅：{{length}}。\n'
        '- 保持原意与事实不变，不增加原文没有的信息；修正错别字、病句与标点。\n'
        '- 先给出改写后的全文，再用最多三条要点说明主要改动：{{notes}}。\n'
        '- 用户另有具体要求时，以用户要求为准。',
    params: [
      PresetParam('tone', '目标风格', PresetParamType.choice, options: ['简洁专业', '正式得体', '亲切自然', '有说服力', '幽默轻松'], def: '简洁专业'),
      PresetParam('length', '篇幅', PresetParamType.choice, options: ['与原文相当', '更精简', '适当扩写'], def: '与原文相当'),
      PresetParam('notes', '附改动说明', PresetParamType.toggle, def: _yes),
    ],
  ),
  PresetTemplate(
    id: 'summary',
    name: '总结提炼',
    desc: '长文、会议记录、文档快速提炼要点',
    icon: 'listChecks',
    color: 0xFFE2572B,
    prompt: '你是信息提炼助手。对用户发来的内容（文字或附件文档）做总结。\n'
        '- 输出形式：{{form}}；详细程度：{{depth}}。\n'
        '- 只依据原文，不编造；数字、日期、人名、结论保持准确。\n'
        '- 最后用一行列出「待办/风险/疑点」：{{todo}}，没有则省略这一行。\n'
        '- 内容过长无法完整阅读时，先说明读到了哪里，再给出已读部分的总结。',
    params: [
      PresetParam('form', '输出形式', PresetParamType.choice, options: ['要点列表', '一段话摘要', '分级大纲', '问答对'], def: '要点列表'),
      PresetParam('depth', '详细程度', PresetParamType.choice, options: ['极简（3 条以内）', '适中', '详细'], def: '适中'),
      PresetParam('todo', '提取待办与风险', PresetParamType.toggle, def: _yes),
    ],
  ),
  PresetTemplate(
    id: 'review',
    name: '代码审查',
    desc: '读代码找问题，按严重程度排序给建议',
    icon: 'bug',
    color: 0xFF6B5BFF,
    prompt: '你是资深代码审查员。审查用户给出的代码、diff 或文件路径（可在当前工作目录里读取文件）。\n'
        '- 重点关注：{{focus}}；严格程度：{{strict}}。\n'
        '- 按「严重 / 一般 / 建议」分组列出问题，每条写清：位置、问题、为什么是问题、怎么改（给出改后的代码片段）。\n'
        '- 不要修改文件，除非用户明确要求；没有发现问题时直接说明，不要为了凑数而挑刺。\n'
        '- 最后给出一句总体结论。',
    params: [
      PresetParam('focus', '关注点', PresetParamType.choice, options: ['缺陷与边界情况', '安全漏洞', '性能', '可读性与结构', '全面检查'], def: '全面检查'),
      PresetParam('strict', '严格程度', PresetParamType.choice, options: ['宽松（只报明显问题）', '标准', '严格（连风格也挑）'], def: '标准'),
    ],
  ),
  PresetTemplate(
    id: 'prompt',
    name: '提示词优化',
    desc: '把一句想法改写成清晰、可直接使用的提示词',
    icon: 'sparkles',
    color: 0xFFD97757,
    prompt: '你是提示词工程师。把用户的需求改写成一条结构清晰、可直接复制使用的提示词。\n'
        '- 目标模型：{{model}}；输出语言：{{lang}}。\n'
        '- 结构：角色、任务、背景信息、输出格式、约束与示例（信息不足的部分用【待补充】标出，不要编造）。\n'
        '- 先输出优化后的提示词（放在一个代码块里便于复制），再用两三条要点说明改了什么、还缺什么信息。',
    params: [
      PresetParam('model', '目标模型', PresetParamType.choice, options: ['通用', 'Claude', 'GPT / Codex', 'DeepSeek', '图像生成'], def: '通用'),
      PresetParam('lang', '输出语言', PresetParamType.choice, options: ['中文', '英文'], def: '中文'),
    ],
  ),
];

/** presetById：按编号找内置模板（出厂版本） */
PresetTemplate? builtinPreset(String id) => builtinPresets.where((p) => p.id == id).firstOrNull;

/**
 * mergePresets：内置模板与资料库里的模板合在一起
 *
 * 资料库里与内置模板同编号的一条是对内置模板的修改，用它替换出厂版本；其余是自定义模板，排在后面。
 */
List<PresetTemplate> mergePresets(List<PresetTemplate> stored) {
  final byId = {for (final t in stored) t.id: t};
  return [
    for (final b in builtinPresets) byId[b.id]?.asOverride() ?? b,
    for (final t in stored) if (builtinPreset(t.id) == null) t,
  ];
}

/** yes、no：开关参数的取值 */
const presetYes = _yes;
const presetNo = _no;
