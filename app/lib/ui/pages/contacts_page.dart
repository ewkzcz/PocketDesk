/**
 * 通讯录：好友是电脑上的 AI 编程工具，下面是预设助手（翻译、OCR 识别等，可以交给任意一个 Agent 处理）。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/library_store.dart';
import '../agents.dart';
import '../avatars.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'preset_pages.dart';
import 'session_actions.dart';

/**
 * ContactsPage：通讯录
 */
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    context.read<AppState>().scope?.library.refresh(LibraryKind.presets);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final scope = context.watch<AppState>().scope;
    final lib = scope?.library;
    final status = scope?.conn.status;
    return Scaffold(
      appBar: PdBar(title: '通讯录', actions: [PdIconButton(icon: LucideIcons.userRoundPlus300, tooltip: '新建预设助手', onTap: () => _open(const PresetEditorPage()))]),
      body: ListenableBuilder(
        listenable: Listenable.merge([?lib, ?scope?.conn, _search]),
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          final friends = [for (final k in agentKinds) if (q.isEmpty || agentFor(k).label.toLowerCase().contains(q)) k];
          final presets = allPresets(lib).where((t) => q.isEmpty || t.name.toLowerCase().contains(q) || t.desc.toLowerCase().contains(q)).toList();
          return ListView(padding: const EdgeInsets.only(top: 8, bottom: 24), children: [
            Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: SearchField(controller: _search, hint: '搜索好友、预设助手')),
            if (friends.isNotEmpty)
              PdGroup(header: 'AI 好友', indent: 68, children: [
                for (final k in friends)
                  () {
                    final info = status?.agents.where((a) => a.kind == k).firstOrNull;
                    final sub = scope == null ? '未连接电脑' : (info == null ? '电脑上未检测到' : (info.installed ? (info.version.isEmpty ? '已安装' : '已安装 · ${info.version}') : '电脑上未安装'));
                    return PdCell(
                      title: agentFor(k).label,
                      subtitle: sub,
                      leadingAvatar: AgentAvatar(k, size: 40),
                      onTap: () => _open(ContactPage(kind: k)),
                    );
                  }(),
              ]),
            if (presets.isNotEmpty)
              PdGroup(header: '预设助手', indent: 68, footer: '预设助手带着写好的系统提示词，可以交给任意一个 Agent 处理。', children: [
                for (final t in presets)
                  PdCell(
                    title: t.name,
                    subtitle: t.desc,
                    leadingAvatar: PresetAvatar(icon: t.icon, color: t.color, size: 40),
                    value: t.builtIn ? (t.overridden ? '已修改' : '') : '自定义',
                    onTap: () => _open(PresetPage(template: t)),
                  ),
              ]),
            if (friends.isEmpty && presets.isEmpty) Padding(padding: const EdgeInsets.only(top: 60), child: Center(child: Text('没有找到相关联系人', style: TextStyle(color: c.text3, fontSize: PdFont.summary)))),
          ]);
        },
      ),
    );
  }
}

/**
 * ContactPage：一个 AI 好友的资料页，可以发消息、新建会话、更换头像
 */
class ContactPage extends StatelessWidget {
  const ContactPage({super.key, required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final app = context.watch<AppState>();
    final scope = app.scope;
    final a = agentFor(kind);
    final info = scope?.conn.status?.agents.where((x) => x.kind == kind).firstOrNull;
    final supportsAuto = kind == 'claude' || kind == 'codex';
    final recent = scope?.sessions.sessions.where((s) => s.kind == kind && !s.isPreset).firstOrNull;
    final installed = info?.installed ?? true;
    return Scaffold(
      appBar: PdBar(title: a.label),
      body: ListView(padding: const EdgeInsets.only(top: 20, bottom: 24), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(PdSize.gutter, 0, PdSize.gutter, 24),
          child: Row(children: [
            GestureDetector(onTap: () => pickAvatar(context, key: kind, title: '设置 ${a.label} 的头像'), child: AgentAvatar(kind, size: 76)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: c.text)),
                const SizedBox(height: 4),
                Text(scope == null ? '未连接电脑' : (installed ? (info == null || info.version.isEmpty ? '电脑上已安装' : '电脑上已安装 · ${info.version}') : '电脑上未安装'), style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
              ]),
            ),
          ]),
        ),
        PdGroup(children: [
          PdCell(
            icon: LucideIcons.messageCircle300,
            tint: PdTint.transfer,
            title: recent == null ? '发消息' : '继续最近的会话',
            subtitle: recent == null ? '新建一个会话' : sessionTitle(recent),
            onTap: !installed
                ? null
                : () => recent == null ? newAgentSession(context, kind) : openSession(context, recent),
          ),
          PdCell(icon: LucideIcons.messageSquarePlus300, tint: PdTint.files, title: '新建会话', subtitle: '选择工作目录', onTap: installed ? () => newAgentSession(context, kind) : null),
          if (supportsAuto) PdCell(icon: LucideIcons.zap300, tint: PdTint.favorites, title: '免审批会话', subtitle: '所有操作自动放行', onTap: installed ? () => newAgentSession(context, kind, autoApprove: true) : null),
        ]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.image300, tint: PdTint.look, title: '设置头像', onTap: () => pickAvatar(context, key: kind, title: '设置 ${a.label} 的头像')),
        ]),
        if (!installed) Padding(padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter), child: Text('这台电脑上没有检测到 ${a.label}，安装后才能发起会话。', style: TextStyle(fontSize: PdFont.time, color: c.text3, height: 1.6))),
      ]),
    );
  }
}
