/**
 * 通讯录预设助手：模板详情（选择由哪个 Agent 处理、填写参数、开始对话）、自定义模板编辑、聊天里调整参数与换 Agent 处理。
 */
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../core/library_store.dart';
import '../../core/presets.dart';
import '../../core/settings.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../agents.dart';
import '../styles.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'chat_page.dart';
import 'places.dart';

/** presetIcons：模板可选的图标 */
const presetIcons = <String, IconData>{
  'languages': LucideIcons.languages300,
  'scanText': LucideIcons.scanText300,
  'wandSparkles': LucideIcons.wandSparkles300,
  'listChecks': LucideIcons.listChecks300,
  'bug': LucideIcons.bug300,
  'sparkles': LucideIcons.sparkles300,
  'bookOpen': LucideIcons.bookOpen300,
  'mail': LucideIcons.mail300,
  'code': LucideIcons.code300,
  'lightbulb': LucideIcons.lightbulb300,
  'briefcase': LucideIcons.briefcase300,
  'graduationCap': LucideIcons.graduationCap300,
  'megaphone': LucideIcons.megaphone300,
  'search': LucideIcons.search300,
};

/** presetColors：模板头像可选底色 */
const presetColors = [0xFF2F7BFA, 0xFF10A37F, 0xFFE0569B, 0xFFE2572B, 0xFF6B5BFF, 0xFFD97757, 0xFF0EA5E9, 0xFF475569];

/** PresetAvatar：模板头像（底色加图标），形状跟随风格 */
class PresetAvatar extends StatelessWidget {
  const PresetAvatar({super.key, required this.icon, required this.color, this.size = PdSize.avatar});

  final String icon;
  final int color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Color(color), borderRadius: BorderRadius.circular(context.style.avatarRadiusFor(size))),
        child: Icon(presetIcons[icon] ?? LucideIcons.sparkles300, color: Colors.white, size: size * 0.5),
      );
}

/** presetAvatarFor：模板会话的头像（底色加图标），普通会话返回空 */
Widget? presetAvatarFor(SessionInfo s, {double size = PdSize.avatar}) {
  final ref = PresetRef.parse(s.preset);
  return ref == null ? null : PresetAvatar(icon: ref.icon, color: ref.color, size: size);
}

/** allPresets：全部预设助手（内置的按改过的版本），资料库没读到时只有内置的 */
List<PresetTemplate> allPresets(LibraryStore? lib) => mergePresets([
      if (lib != null)
        for (final x in lib.items(LibraryKind.presets)) ?PresetTemplate.tryParse(x.body, libraryId: x.id),
    ]);

/** findPreset：按会话里记录的编号找到模板（内置或自定义），找不到返回空 */
PresetTemplate? findPreset(LibraryStore? lib, String id) => allPresets(lib).where((t) => t.id == id).firstOrNull;

/** installedAgentKinds：电脑上已安装的 Agent（离线或未读到时列出全部） */
List<String> installedAgentKinds(HostScope? scope) {
  final status = scope?.conn.status;
  if (status == null) return agentKinds;
  final list = [for (final k in agentKinds) if (status.agents.any((a) => a.kind == k && a.installed)) k];
  return list;
}

/**
 * PresetParamsForm：按模板的参数定义显示可填写的表单
 */
class PresetParamsForm extends StatefulWidget {
  const PresetParamsForm({super.key, required this.template, required this.values, required this.onChanged});

  final PresetTemplate template;
  final Map<String, String> values;
  final void Function(Map<String, String> values) onChanged;

  @override
  State<PresetParamsForm> createState() => _PresetParamsFormState();
}

class _PresetParamsFormState extends State<PresetParamsForm> {
  late Map<String, String> _v = {...widget.template.defaults, ...widget.values};
  final Map<String, TextEditingController> _text = {};

  @override
  void dispose() {
    for (final t in _text.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _set(String key, String v) {
    setState(() => _v = {..._v, key: v});
    widget.onChanged(_v);
  }

  Future<void> _choose(PresetParam p) async {
    final i = await actionSheet(context, [for (final o in p.options) SheetAction(o, icon: o == _v[p.key] ? LucideIcons.check300 : null)], title: p.label);
    if (i != null) _set(p.key, p.options[i]);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final params = widget.template.params;
    if (params.isEmpty) return Padding(padding: const EdgeInsets.all(PdSize.gutter), child: Text('这个助手没有可调整的参数', style: TextStyle(fontSize: PdFont.summary, color: c.text3)));
    return PdGroup(children: [
      for (final p in params)
        switch (p.type) {
          PresetParamType.choice => PdCell(title: p.label, value: _v[p.key] ?? '', onTap: () => _choose(p)),
          PresetParamType.toggle => PdCell(
              title: p.label,
              arrow: false,
              trailing: Switch(value: _v[p.key] == presetYes, onChanged: (on) => _set(p.key, on ? presetYes : presetNo)),
            ),
          PresetParamType.text => Padding(
              padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 8),
              child: TextField(
                controller: _text.putIfAbsent(p.key, () => TextEditingController(text: _v[p.key] ?? '')),
                decoration: InputDecoration(labelText: p.label, hintText: p.hint, fillColor: c.page),
                minLines: 1,
                maxLines: 3,
                onChanged: (t) {
                  _v = {..._v, p.key: t};
                  widget.onChanged(_v);
                },
              ),
            ),
        },
    ]);
  }
}

/** _paramsOf：读出上次保存的参数 */
Map<String, String> _savedParams(AppSettings s, PresetTemplate t) {
  final raw = s.presetParams(t.id);
  if (raw.isEmpty) return t.defaults;
  try {
    final j = jsonDecode(raw);
    if (j is Map) return {...t.defaults, for (final e in j.entries) '${e.key}': '${e.value}'};
  } on FormatException {
    return t.defaults;
  }
  return t.defaults;
}

/**
 * startPreset：用选定的 Agent 和参数新建模板会话并进入
 *
 * 工作目录用默认工作目录；dir 不为空时用指定的。
 */
Future<void> startPreset(BuildContext context, PresetTemplate t, String kind, Map<String, String> values, {WorkDir? dir, bool replace = false}) async {
  final app = context.read<AppState>();
  final scope = app.scope;
  if (scope == null) {
    toast(context, '请先配对电脑');
    return;
  }
  if (!await context.read<AuthGate>().ensure('验证身份以新建会话') || !context.mounted) return;
  try {
    final d = dir ?? await defaultWorkDir(context);
    if (d == null || !context.mounted) return;
    final s = await scope.conn.api.createSession(kind, d.ws.id, d.cwd, title: '${t.name} · ${agentFor(kind).label}', instruction: t.render(values), preset: t.ref(values));
    scope.sessions.upsert(s);
    final settings = app.settings;
    settings.setPresetAgent(t.id, kind);
    settings.setPresetParams(t.id, jsonEncode(values));
    if (!context.mounted) return;
    final page = MaterialPageRoute<void>(builder: (_) => ChatPage(sessionId: s.id));
    if (replace) {
      await Navigator.of(context).pushReplacement(page);
    } else {
      await Navigator.of(context).push(page);
    }
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.offline ? '电脑不在线，稍后再试' : e.message);
  }
}

/**
 * PresetPage：预设助手详情
 *
 * 处理流程：
 * 1、选择由哪个 Agent 处理（只列电脑上已安装的）
 * 2、填写参数，可展开查看最终的系统提示词
 * 3、开始对话：电脑端把系统提示词放在每一轮用户输入前面
 */
class PresetPage extends StatefulWidget {
  const PresetPage({super.key, required this.template});

  final PresetTemplate template;

  @override
  State<PresetPage> createState() => _PresetPageState();
}

class _PresetPageState extends State<PresetPage> {
  late Map<String, String> _values;
  late String _kind;
  WorkDir? _dir;
  bool _showPrompt = false;

  /** t：当前模板（改过或恢复默认后取最新版本） */
  PresetTemplate get t => findPreset(context.read<AppState>().scope?.library, widget.template.id) ?? widget.template;

  @override
  void initState() {
    super.initState();
    final app = context.read<AppState>();
    _values = _savedParams(app.settings, t);
    final kinds = installedAgentKinds(app.scope);
    final last = app.settings.presetAgent(t.id);
    _kind = kinds.contains(last) ? last : (kinds.firstOrNull ?? agentKinds.first);
  }

  Future<void> _menu() async {
    final lib = context.read<AppState>().scope?.library;
    final items = <(SheetAction, Future<void> Function())>[
      if (t.builtIn) ...[
        (
          const SheetAction('修改提示词与参数', icon: LucideIcons.pencil300),
          () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PresetEditorPage(initial: t)));
            if (mounted) setState(() {});
          }
        ),
        if (t.overridden)
          (
            const SheetAction('恢复默认', icon: LucideIcons.rotateCcw300),
            () async {
              if (lib == null || !await confirm(context, title: '恢复「${t.name}」的默认设置', message: '改过的提示词和参数会被丢弃，换回出厂版本。已经开始的对话不受影响。', ok: '恢复默认', danger: true) || !mounted) return;
              final item = lib.items(LibraryKind.presets).where((x) => x.id == t.libraryId).firstOrNull;
              if (item != null) await lib.remove(item);
              if (mounted) {
                toast(context, '已恢复默认');
                setState(() {});
              }
            }
          ),
        (
          const SheetAction('复制为自定义模板', icon: LucideIcons.copyPlus300),
          () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PresetEditorPage(initial: t, asCopy: true)));
          }
        ),
      ] else ...[
        (
          const SheetAction('编辑', icon: LucideIcons.pencil300),
          () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PresetEditorPage(initial: t)));
            if (mounted) setState(() {});
          }
        ),
        (
          const SheetAction('删除', icon: LucideIcons.trash2300, danger: true),
          () async {
            if (lib == null || !await confirm(context, title: '删除「${t.name}」', message: '已经开始的对话不受影响。', ok: '删除', danger: true) || !mounted) return;
            final item = lib.items(LibraryKind.presets).where((x) => x.id == t.libraryId).firstOrNull;
            if (item != null) await lib.remove(item);
            if (mounted) Navigator.of(context).pop();
          }
        ),
      ],
    ];
    final i = await actionSheet(context, [for (final x in items) x.$1]);
    if (i != null) await items[i].$2();
  }

  Future<void> _pickDir() async {
    final d = await pickWorkDir(context, title: '在哪个目录里处理');
    if (d != null && mounted) setState(() => _dir = d);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = context.watch<AppState>().scope;
    final kinds = installedAgentKinds(scope);
    return Scaffold(
      appBar: PdBar(title: t.name, actions: [PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', onTap: _menu)]),
      body: ListView(padding: const EdgeInsets.only(top: 16, bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PdSize.gutter, 0, PdSize.gutter, 20),
          child: Row(children: [
            PresetAvatar(icon: t.icon, color: t.color, size: 64),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(t.name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text))),
                  if (t.overridden) Padding(padding: const EdgeInsets.only(left: 8), child: Tag('已修改', color: c.accentSoft, textColor: c.accent)),
                ]),
                const SizedBox(height: 4),
                Text(t.desc, style: TextStyle(fontSize: PdFont.summary, color: c.text3, height: 1.5)),
              ]),
            ),
          ]),
        ),
        PdGroup(header: '交给谁处理', footer: kinds.isEmpty ? '电脑上没有检测到可用的 Agent' : '', children: [
          for (final k in kinds)
            PdCell(
              title: agentFor(k).label,
              arrow: false,
              leadingAvatar: AgentAvatar(k, size: 32),
              trailing: Icon(k == _kind ? LucideIcons.circleCheck300 : LucideIcons.circle300, size: 22, color: k == _kind ? c.accent : c.text4),
              onTap: () => setState(() => _kind = k),
            ),
        ]),
        PdGroup(header: '参数', children: [PresetParamsForm(template: t, values: _values, onChanged: (v) => _values = v)]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.folder300, title: '工作目录', value: _dir == null ? '默认工作目录' : (_dir!.cwd == '.' ? _dir!.ws.name : '${_dir!.ws.name}/${_dir!.cwd}'), onTap: _pickDir),
          PdCell(
            icon: LucideIcons.fileText300,
            title: '系统提示词',
            value: _showPrompt ? '收起' : '查看',
            onTap: () => setState(() => _showPrompt = !_showPrompt),
          ),
          if (_showPrompt)
            Padding(
              padding: const EdgeInsets.all(PdSize.gutter),
              child: SelectableText(t.render(_values), style: TextStyle(fontSize: PdFont.summary, color: c.text2, height: 1.6)),
            ),
          PdCell(
            icon: LucideIcons.pencil300,
            title: '修改系统提示词',
            value: t.overridden ? '已修改' : '',
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PresetEditorPage(initial: t)));
              if (mounted) setState(() {});
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter),
          child: FilledButton.icon(
            onPressed: kinds.isEmpty ? null : () => startPreset(context, t, _kind, _values, dir: _dir),
            icon: const Icon(LucideIcons.messageCircle300, size: 20),
            label: const Text('开始对话'),
          ),
        ),
      ]),
    );
  }
}

/**
 * PresetEditorPage：新建或编辑自定义预设助手
 */
class PresetEditorPage extends StatefulWidget {
  const PresetEditorPage({super.key, this.initial, this.asCopy = false});

  final PresetTemplate? initial;

  /** 以现有模板为底稿另存为新模板 */
  final bool asCopy;

  @override
  State<PresetEditorPage> createState() => _PresetEditorPageState();
}

class _EditParam {
  _EditParam(PresetParam p)
      : label = TextEditingController(text: p.label),
        options = TextEditingController(text: p.options.join('，')),
        def = TextEditingController(text: p.def),
        type = p.type,
        key = p.key;

  final TextEditingController label;
  final TextEditingController options;
  final TextEditingController def;
  PresetParamType type;
  final String key;

  void dispose() {
    label.dispose();
    options.dispose();
    def.dispose();
  }
}

class _PresetEditorPageState extends State<PresetEditorPage> {
  late final _name = TextEditingController(text: widget.initial == null ? '' : (widget.asCopy ? '${widget.initial!.name}（自定义）' : widget.initial!.name));
  late final _desc = TextEditingController(text: widget.initial?.desc ?? '');
  late final _prompt = TextEditingController(text: widget.initial?.prompt ?? '');
  late String _icon = widget.initial?.icon ?? 'sparkles';
  late int _color = widget.initial?.color ?? presetColors.first;
  late final List<_EditParam> _params = [for (final p in widget.initial?.params ?? const <PresetParam>[]) _EditParam(p)];

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _prompt.dispose();
    for (final p in _params) {
      p.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _prompt.text.trim().isEmpty) {
      toast(context, '名称和系统提示词不能为空');
      return;
    }
    final lib = context.read<AppState>().scope?.library;
    if (lib == null) {
      toast(context, '请先配对电脑');
      return;
    }
    // 编辑已有模板（自定义或内置）时沿用原编号；复制或新建时生成新编号
    final existing = widget.initial != null && !widget.asCopy ? widget.initial : null;
    final builtIn = existing?.builtIn ?? false;
    // 原有参数沿用原来的键，提示词里的 {{键}} 不会失效；新加的参数用不重复的 p 序号
    final used = {for (final p in _params) if (p.key.isNotEmpty) p.key};
    var seq = 0;
    String fresh() {
      String k;
      do {
        k = 'p${++seq}';
      } while (used.contains(k));
      used.add(k);
      return k;
    }

    final params = <PresetParam>[
      for (var i = 0; i < _params.length; i++)
        if (_params[i].label.text.trim().isNotEmpty)
          PresetParam(
            _params[i].key.isNotEmpty ? _params[i].key : fresh(),
            _params[i].label.text.trim(),
            _params[i].type,
            options: [for (final o in _params[i].options.text.split(RegExp('[,，、\n]'))) if (o.trim().isNotEmpty) o.trim()],
            def: _params[i].def.text.trim(),
          ),
    ];
    final id = existing?.id ?? 'custom-${DateTime.now().millisecondsSinceEpoch}';
    final tpl = PresetTemplate(id: id, name: name, desc: _desc.text.trim(), icon: _icon, color: _color, prompt: _prompt.text.trim(), params: params, builtIn: builtIn);
    try {
      final item = existing == null ? null : lib.items(LibraryKind.presets).where((x) => x.id == existing.libraryId).firstOrNull;
      if (item != null) {
        await lib.update(item, title: name, body: jsonEncode(tpl.toJson()));
      } else if (builtIn) {
        // 第一次修改内置模板：存一份同编号的修改版
        await lib.addText(LibraryKind.presets, title: name, body: jsonEncode(tpl.toJson()), mime: 'application/json');
      } else if (existing != null) {
        toast(context, '找不到这个模板，可能已被删除');
        return;
      } else {
        await lib.addText(LibraryKind.presets, title: name, body: jsonEncode(tpl.toJson()), mime: 'application/json');
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.offline ? '电脑不在线，稍后再试' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    InputDecoration deco(String label, {String hint = ''}) => InputDecoration(labelText: label, hintText: hint, fillColor: c.card);
    return Scaffold(
      appBar: PdBar(title: widget.initial == null || widget.asCopy ? '新建预设助手' : (widget.initial!.builtIn ? '修改「${widget.initial!.name}」' : '编辑预设助手'), actions: [PdIconButton(icon: LucideIcons.check300, tooltip: '保存', onTap: _save)]),
      body: ListView(padding: const EdgeInsets.all(PdSize.gutter), children: [
        Center(child: PresetAvatar(icon: _icon, color: _color, size: 64)),
        const SizedBox(height: 14),
        Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
          for (final e in presetIcons.entries)
            GestureDetector(
              onTap: () => setState(() => _icon = e.key),
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: _icon == e.key ? c.accentSoft : c.card, borderRadius: BorderRadius.circular(context.style.smallRadius), border: Border.all(color: _icon == e.key ? c.accent : Colors.transparent)),
                child: Icon(e.value, size: 20, color: _icon == e.key ? c.accent : c.text2),
              ),
            ),
        ]),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.center, spacing: 10, children: [
          for (final col in presetColors)
            GestureDetector(
              onTap: () => setState(() => _color = col),
              child: Container(width: 28, height: 28, decoration: BoxDecoration(color: Color(col), shape: BoxShape.circle, border: Border.all(color: _color == col ? c.text : Colors.transparent, width: 2))),
            ),
        ]),
        const SizedBox(height: 18),
        TextField(controller: _name, decoration: deco('名称')),
        const SizedBox(height: 12),
        TextField(controller: _desc, decoration: deco('一句话说明')),
        const SizedBox(height: 12),
        TextField(controller: _prompt, minLines: 6, maxLines: 16, decoration: deco('系统提示词', hint: '用 {{参数键}} 引用下面的参数，键显示在每个参数的左上角')),
        const SizedBox(height: 18),
        Row(children: [
          Text('参数', style: TextStyle(fontSize: PdFont.summary, color: c.text3, fontWeight: FontWeight.w500)),
          const Spacer(),
          TextButton.icon(onPressed: () => setState(() => _params.add(_EditParam(const PresetParam('', '', PresetParamType.choice)))), icon: const Icon(LucideIcons.plus300, size: 18), label: const Text('添加参数')),
        ]),
        for (var i = 0; i < _params.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: context.style.card(c),
            child: Column(children: [
              Row(children: [
                Text(_params[i].key.isEmpty ? '新参数' : '{{${_params[i].key}}}', style: TextStyle(fontSize: PdFont.time, color: c.accent, fontFamily: PdFont.mono)),
                const Spacer(),
                for (final ty in PresetParamType.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text(switch (ty) { PresetParamType.choice => '单选', PresetParamType.text => '填写', PresetParamType.toggle => '开关' }),
                      selected: _params[i].type == ty,
                      onSelected: (_) => setState(() => _params[i].type = ty),
                    ),
                  ),
                PdIconButton(icon: LucideIcons.trash2300, size: 18, tooltip: '删除参数', onTap: () => setState(() => _params.removeAt(i).dispose())),
              ]),
              TextField(controller: _params[i].label, decoration: deco('参数名称')),
              if (_params[i].type == PresetParamType.choice) ...[const SizedBox(height: 8), TextField(controller: _params[i].options, decoration: deco('选项', hint: '用逗号分隔，如 中文，英文，日文'))],
              const SizedBox(height: 8),
              TextField(controller: _params[i].def, decoration: deco('默认值', hint: _params[i].type == PresetParamType.toggle ? '是 或 否' : '')),
            ]),
          ),
      ]),
    );
  }
}

/**
 * showPresetSession：聊天里调整模板参数与换 Agent 处理
 *
 * 处理流程：
 * 1、上半部分改参数，点「应用」后从下一条消息起生效
 * 2、下半部分选另一个 Agent，用同样的模板和参数新开一个会话，可带上刚才的输入
 */
Future<void> showPresetSheet(BuildContext context, SessionInfo s, {String lastInput = ''}) async {
  final app = context.read<AppState>();
  final scope = app.scope;
  final ref = PresetRef.parse(s.preset);
  if (scope == null || ref == null) return;
  final t = findPreset(scope.library, ref.id);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _PresetSheet(session: s, ref: ref, template: t, lastInput: lastInput),
  );
}

class _PresetSheet extends StatefulWidget {
  const _PresetSheet({required this.session, required this.ref, required this.template, required this.lastInput});

  final SessionInfo session;
  final PresetRef ref;
  final PresetTemplate? template;
  final String lastInput;

  @override
  State<_PresetSheet> createState() => _PresetSheetState();
}

class _PresetSheetState extends State<_PresetSheet> {
  late Map<String, String> _values = {...widget.ref.params};
  bool _busy = false;

  Future<void> _apply() async {
    final t = widget.template;
    final scope = context.read<AppState>().scope;
    if (t == null || scope == null) return;
    setState(() => _busy = true);
    try {
      final s = await scope.conn.api.patchSession(widget.session.id, instruction: t.render(_values), preset: t.ref(_values));
      scope.sessions.upsert(s);
      if (mounted) {
        Navigator.of(context).pop();
        toast(context, '参数已更新，从下一条消息起生效');
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        toast(context, e.message);
      }
    }
  }

  Future<void> _switch(String kind) async {
    final t = widget.template;
    final scope = context.read<AppState>().scope;
    if (t == null || scope == null) return;
    final nav = Navigator.of(context);
    final root = nav.context;
    final carry = widget.lastInput.trim().isNotEmpty && await confirm(context, title: '换成 ${agentFor(kind).label} 处理', message: '把刚才的输入也发过去吗？', ok: '发过去', cancel: '不发');
    if (!mounted) return;
    nav.pop();
    final d = await _sameDir(scope);
    if (!root.mounted) return;
    await startPreset(root, t, kind, _values, dir: d, replace: true);
    if (carry) {
      final sid = scope.sessions.sessions.where((x) => x.isPreset && x.kind == kind && x.id != widget.session.id).firstOrNull?.id;
      if (sid != null) {
        try {
          await scope.conn.api.sendMessage(sid, widget.lastInput);
        } on ApiException {
          // 发送失败时用户在新会话里手动再发
        }
      }
    }
  }

  /** _sameDir：沿用当前会话的工作目录 */
  Future<WorkDir?> _sameDir(HostScope scope) async {
    try {
      final list = await scope.conn.api.workspaces();
      final ws = list.where((w) => w.id == widget.session.workspaceId).firstOrNull;
      return ws == null ? null : (ws: ws, cwd: widget.session.cwd);
    } on ApiException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final t = widget.template;
    final scope = context.watch<AppState>().scope;
    final others = [for (final k in installedAgentKinds(scope)) if (k != widget.session.kind) k];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(vertical: 16), children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter),
            child: Row(children: [
              PresetAvatar(icon: widget.ref.icon, color: widget.ref.color, size: 40),
              const SizedBox(width: 12),
              Expanded(child: Text(widget.ref.name, style: TextStyle(fontSize: PdFont.body, fontWeight: FontWeight.w600, color: c.text))),
              Text('由 ${agentFor(widget.session.kind).label} 处理', style: TextStyle(fontSize: PdFont.time, color: c.text3)),
            ]),
          ),
          const SizedBox(height: 12),
          if (t == null)
            Padding(padding: const EdgeInsets.all(PdSize.gutter), child: Text('找不到这个模板，可能已被删除，参数无法修改。', style: TextStyle(fontSize: PdFont.summary, color: c.text3)))
          else ...[
            PresetParamsForm(template: t, values: _values, onChanged: (v) => _values = v),
            Padding(padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter), child: FilledButton(onPressed: _busy ? null : _apply, child: const Text('应用参数'))),
          ],
          if (t != null && others.isNotEmpty) ...[
            const SizedBox(height: 20),
            PdGroup(header: '换 Agent 处理', children: [
              for (final k in others) PdCell(title: agentFor(k).label, leadingAvatar: AgentAvatar(k, size: 32), onTap: () => _switch(k)),
            ]),
          ],
        ]),
      ),
    );
  }
}
