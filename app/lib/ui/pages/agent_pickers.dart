/**
 * Agent 选项：切换模型与模型供应商（电脑上 CC Switch 的供应商）、查看并选用 skill。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../chat/markdown.dart';
import '../tokens.dart';
import '../widgets.dart';

/** supportsProvider：可以切换供应商与 skill 的 Agent */
bool supportsProvider(SessionInfo s) => s.kind == 'claude' || s.kind == 'codex';

/** _patch：修改会话，成功返回新会话 */
Future<SessionInfo?> _patch(BuildContext context, Future<SessionInfo> Function(PdApi api) f) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return null;
  try {
    final s = await f(scope.conn.api);
    scope.sessions.upsert(s);
    return s;
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return null;
  }
}

/**
 * switchModel：切换模型
 *
 * 处理流程：
 * 1、取可选模型（选了供应商时包含该供应商配置的模型）
 * 2、列表中选一个，也可以恢复默认或手动填写
 */
Future<void> switchModel(BuildContext context, SessionInfo s) async {
  final api = context.read<AppState>().scope?.conn.api;
  if (api == null) return;
  // 1、可选模型
  List<String> models;
  try {
    models = await api.models(s.kind, provider: s.provider);
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  // 2、选择
  final actions = [
    for (final m in models) SheetAction(m, icon: m == s.model ? LucideIcons.check300 : null),
    if (s.model.isNotEmpty) const SheetAction('恢复默认模型', icon: LucideIcons.rotateCcw300),
    const SheetAction('手动填写…', icon: LucideIcons.pencil300),
  ];
  final i = await actionSheet(context, actions, title: '切换模型');
  if (i == null || !context.mounted) return;
  String model;
  if (i < models.length) {
    model = models[i];
  } else if (s.model.isNotEmpty && i == models.length) {
    model = '';
  } else {
    final t = await inputDialog(context, title: '填写模型名称', initial: s.model, hint: '例如 sonnet 或 gpt-5');
    if (t == null || t.trim().isEmpty || !context.mounted) return;
    model = t.trim();
  }
  final n = await _patch(context, (api) => api.patchSession(s.id, model: model));
  if (n != null && context.mounted) toast(context, model.isEmpty ? '已恢复默认模型' : '已切换到 $model');
}

/**
 * switchProvider：切换模型供应商（只对这个会话生效）
 */
Future<void> switchProvider(BuildContext context, SessionInfo s) async {
  final api = context.read<AppState>().scope?.conn.api;
  if (api == null) return;
  if (!supportsProvider(s)) {
    toast(context, '只有 Claude Code 与 Codex 可以切换供应商');
    return;
  }
  ({bool available, List<ProviderInfo> list}) r;
  try {
    r = await api.providers(s.kind);
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.message);
    return;
  }
  if (!context.mounted) return;
  if (!r.available) {
    toast(context, '电脑上没有找到 CC Switch');
    return;
  }
  final cur = r.list.where((p) => p.current).firstOrNull;
  final i = await actionSheet(context, [
    SheetAction('跟随电脑当前设置', icon: s.provider.isEmpty ? LucideIcons.check300 : LucideIcons.monitor300, subtitle: cur == null ? '' : '当前：${cur.name}'),
    for (final p in r.list) SheetAction(p.name, icon: p.id == s.provider ? LucideIcons.check300 : LucideIcons.server300, subtitle: [p.host, if (p.current) '电脑当前'].where((x) => x.isNotEmpty).join(' · ')),
  ], title: '模型供应商（只对这个会话生效）');
  if (i == null || !context.mounted) return;
  final id = i == 0 ? '' : r.list[i - 1].id;
  if (id == s.provider) return;
  final n = await _patch(context, (api) => api.patchSession(s.id, provider: id));
  if (n != null && context.mounted) toast(context, i == 0 ? '已改为跟随电脑当前设置' : '已切换到 ${r.list[i - 1].name}');
}

/** providerName：会话所选供应商的名称，查不到时返回空 */
Future<String> providerName(PdApi api, SessionInfo s) async {
  if (s.provider.isEmpty || !supportsProvider(s)) return '';
  try {
    return (await api.providers(s.kind)).list.where((p) => p.id == s.provider).firstOrNull?.name ?? '';
  } on ApiException {
    return '';
  }
}

/**
 * SkillsPage：skill 列表，右侧开关启用或停用，勾选的随下一条消息使用，点开查看说明；返回勾选结果
 */
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, required this.session, this.picked = const []});

  final SessionInfo session;
  final List<SkillInfo> picked;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<SkillInfo>? _list;
  String _error = '';
  late final Set<String> _picked = {for (final k in widget.picked) k.path};
  final Set<String> _busy = {};

  PdApi get _api => context.read<AppState>().scope!.conn.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /** _load：读取 skill 列表 */
  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final list = await _api.skills(widget.session.kind, widget.session.id);
      if (mounted) setState(() => _list = list);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /** _toggle：启用或停用 */
  Future<void> _toggle(SkillInfo k, bool on) async {
    setState(() => _busy.add(k.path));
    try {
      await _api.setSkill(widget.session.kind, widget.session.id, k.path, on);
      if (!mounted) return;
      setState(() {
        _list = [for (final x in _list!) x.path == k.path ? x.copyWith(enabled: on) : x];
        if (!on) _picked.remove(k.path);
      });
      toast(context, on ? '已启用，新的一轮生效' : '已停用');
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(k.path));
    }
  }

  /** _done：返回勾选的 skill */
  void _done() => Navigator.of(context).pop([for (final k in _list ?? const <SkillInfo>[]) if (_picked.contains(k.path)) k]);

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final list = _list;
    const scope = {'project': '项目', 'user': '本机', 'system': '自带', 'admin': '管理员'};
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) {
        if (!did) _done();
      },
      child: Scaffold(
        appBar: PdBar(title: _picked.isEmpty ? 'Skills' : 'Skills（已选 ${_picked.length}）', actions: [
          PdIconButton(icon: LucideIcons.check300, tooltip: '完成', color: c.accent, onTap: _done),
        ]),
        body: list == null
            ? (_error.isNotEmpty ? EmptyHint(icon: LucideIcons.sparkles300, text: _error, action: '重试', onAction: _load) : Center(child: CircularProgressIndicator(color: c.accent)))
            : list.isEmpty
                ? const EmptyHint(icon: LucideIcons.sparkles300, text: '电脑上没有找到已安装的 skill')
                : ListView(padding: const EdgeInsets.only(top: 12, bottom: 24), children: [
                    PdGroup(
                      footer: '勾选的 skill 会随下一条消息使用；右侧开关控制 Agent 是否加载它。',
                      children: [
                        for (final k in list)
                          Material(
                            color: c.card,
                            child: InkWell(
                              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _SkillDetail(session: widget.session, skill: k))),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(4, 6, PdSize.gutter, 6),
                                child: Row(children: [
                                  Checkbox(
                                    value: _picked.contains(k.path),
                                    activeColor: c.accent,
                                    onChanged: !k.enabled
                                        ? null
                                        : (v) => setState(() {
                                              if (v == true && _picked.length >= 8) {
                                                toast(context, '一次最多选 8 个');
                                                return;
                                              }
                                              v == true ? _picked.add(k.path) : _picked.remove(k.path);
                                            }),
                                  ),
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Row(children: [
                                        Flexible(child: Text(k.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: k.enabled ? c.text : c.text3))),
                                        const SizedBox(width: 6),
                                        Tag(scope[k.scope] ?? k.scope, color: c.page, textColor: c.text3),
                                      ]),
                                      if (k.description.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 2),
                                          child: Text(k.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3, height: 1.35)),
                                        ),
                                    ]),
                                  ),
                                  const SizedBox(width: 8),
                                  _busy.contains(k.path)
                                      ? SizedBox(width: 48, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent))))
                                      : Switch(value: k.enabled, onChanged: (v) => _toggle(k, v)),
                                ]),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ]),
      ),
    );
  }
}

/** _SkillDetail：skill 说明全文 */
class _SkillDetail extends StatefulWidget {
  const _SkillDetail({required this.session, required this.skill});

  final SessionInfo session;
  final SkillInfo skill;

  @override
  State<_SkillDetail> createState() => _SkillDetailState();
}

class _SkillDetailState extends State<_SkillDetail> {
  String? _text;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await context.read<AppState>().scope!.conn.api.skillText(widget.session.kind, widget.session.id, widget.skill.path);
      // 去掉开头的属性块，只显示正文
      final body = t.replaceFirst(RegExp(r'^---\n[\s\S]*?\n---\n'), '');
      if (mounted) setState(() => _text = body);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final text = _text;
    return Scaffold(
      appBar: PdBar(title: widget.skill.name, subtitle: widget.skill.path),
      backgroundColor: c.card,
      body: text == null
          ? (_error.isNotEmpty ? EmptyHint(icon: LucideIcons.fileX300, text: _error) : Center(child: CircularProgressIndicator(color: c.accent)))
          : ListView(padding: const EdgeInsets.all(PdSize.gutter), children: [
              if (widget.skill.description.isNotEmpty)
                Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(widget.skill.description, style: TextStyle(fontSize: PdFont.summary, color: c.text2, height: 1.5))),
              MdText(text),
            ]),
    );
  }
}
