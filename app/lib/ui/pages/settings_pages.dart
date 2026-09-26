/**
 * 设置页：传输设置、安全设置、已配对电脑管理、关于。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../core/connection.dart';
import '../../core/settings.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'pair_page.dart';

/**
 * TransferSettingsPage：传输设置
 */
class TransferSettingsPage extends StatelessWidget {
  const TransferSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final app = context.read<AppState>();
    final c = context.pd;
    void changed() => app.settingsChanged();
    return Scaffold(
      appBar: const PdBar(title: '传输设置'),
      body: ListView(padding: const EdgeInsets.only(top: 16), children: [
        PdGroup(
          footer: '移动网络或省电模式下，单个文件自动降为单路传输。',
          children: [
            PdCell(title: '仅在 Wi-Fi 下传输', trailing: Switch(value: s.wifiOnly, onChanged: (v) {
              s.wifiOnly = v;
              changed();
            })),
            PdCell(title: '低电量时暂停', subtitle: '电量低于 15% 且未充电时暂停', trailing: Switch(value: s.pauseOnLowBattery, onChanged: (v) {
              s.pauseOnLowBattery = v;
              changed();
            })),
          ],
        ),
        PdGroup(
          footer: '小于 8MB 的文件走快速通道，不会排在大文件后面。',
          children: [
            PdCell(
              title: '同时传输的文件数',
              arrow: false,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                PdIconButton(icon: LucideIcons.minus300, tooltip: '减少', size: 18, onTap: s.concurrency > 1 ? () {
                  s.concurrency = s.concurrency - 1;
                  changed();
                } : null),
                SizedBox(width: 24, child: Text('${s.concurrency}', textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.item, color: c.text))),
                PdIconButton(icon: LucideIcons.plus300, tooltip: '增加', size: 18, onTap: s.concurrency < 6 ? () {
                  s.concurrency = s.concurrency + 1;
                  changed();
                } : null),
              ]),
            ),
          ],
        ),
        PdGroup(
          footer: '关闭后，电脑发来的文件会留在「传输 → 收件箱」，点下载后再接收。',
          children: [
            PdCell(title: '自动接收电脑发来的文件', trailing: Switch(value: s.autoReceive, onChanged: (v) => s.autoReceive = v)),
          ],
        ),
      ]),
    );
  }
}

/**
 * SecuritySettingsPage：安全设置
 */
class SecuritySettingsPage extends StatelessWidget {
  const SecuritySettingsPage({super.key});

  static const _graces = [(0, '每次都验证'), (1, '1 分钟'), (5, '5 分钟'), (15, '15 分钟')];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final gate = context.read<AuthGate>();
    final label = _graces.firstWhere((g) => g.$1 == s.graceMinutes, orElse: () => (s.graceMinutes, '${s.graceMinutes} 分钟')).$2;
    return Scaffold(
      appBar: const PdBar(title: '安全设置'),
      body: ListView(padding: const EdgeInsets.only(top: 16), children: [
        PdGroup(
          footer: '打开 App、进入 Agent 会话或终端时需要指纹、面容或锁屏密码验证。',
          children: [
            PdCell(
              title: '身份验证',
              trailing: Switch(
                value: s.biometric,
                onChanged: (v) async {
                  // 关闭前先验证，防止他人关闭
                  if (!v) {
                    gate.lock();
                    if (!await gate.ensure('验证身份以关闭身份验证')) return;
                  }
                  s.biometric = v;
                },
              ),
            ),
            if (s.biometric)
              PdCell(
                title: '免验证时间',
                value: label,
                onTap: () async {
                  final i = await actionSheet(context, [for (final g in _graces) SheetAction(g.$2, icon: g.$1 == s.graceMinutes ? LucideIcons.check300 : null)], title: '验证后多久内不再询问');
                  if (i != null) s.graceMinutes = _graces[i].$1;
                },
              ),
          ],
        ),
        if (s.biometric)
          PdGroup(children: [
            PdCell(title: '立即锁定', icon: LucideIcons.lock300, onTap: () {
              gate.lock();
              toast(context, '已锁定，下次进入会话或终端时需要验证');
            }),
          ]),
      ]),
    );
  }
}

/**
 * ComputersPage：已配对的电脑
 */
class ComputersPage extends StatelessWidget {
  const ComputersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final c = context.pd;
    final current = app.host;
    final status = app.scope?.conn.status;
    return Scaffold(
      appBar: const PdBar(title: '已配对的电脑'),
      body: ListView(padding: const EdgeInsets.only(top: 16), children: [
        if (app.hosts.isEmpty) const SizedBox(height: 240, child: EmptyHint(icon: LucideIcons.laptop300, text: '还没有配对电脑')),
        if (app.hosts.isNotEmpty)
          PdGroup(
            header: '点击切换当前电脑',
            children: [
              for (final h in app.hosts)
                PdCell(
                  icon: LucideIcons.laptop300,
                  title: h.name,
                  subtitle: '${h.addresses.length} 个连接地址',
                  arrow: false,
                  trailing: h.id == current?.id ? Icon(LucideIcons.check300, color: c.accent, size: 20) : null,
                  onTap: () => app.switchHost(h.id),
                ),
            ],
          ),
        if (current != null)
          PdGroup(
            header: '连接地址（按局域网优先、延迟最低自动选择）',
            footer: '不在同一网络时：电脑和手机都安装并登录同一个 Tailscale 账号，连接后会自动记住电脑的 Tailscale 地址；也可以手动添加 Tailscale 名称或自建隧道的地址。',
            children: [
              for (final a in app.scope?.conn.host.addresses ?? current.addresses)
                PdCell(
                  title: a,
                  value: [
                    if (app.scope?.conn.online == true && app.scope?.conn.address == a) '正在使用',
                    isTailscale(a) ? 'Tailscale' : '局域网',
                  ].join(' · '),
                  arrow: false,
                  onTap: () async {
                    final i = await actionSheet(context, const [SheetAction('删除这个地址', danger: true)], title: a);
                    if (i == 0 && !await app.removeAddress(a) && context.mounted) toast(context, '至少需要保留一个地址');
                  },
                ),
              PdCell(
                icon: LucideIcons.plus300,
                title: '添加连接地址',
                onTap: () async {
                  final v = await inputDialog(context, title: '添加连接地址', hint: '例如 100.101.102.103 或 my-pc.tail1234.ts.net');
                  if (v == null || v.trim().isEmpty) return;
                  final ok = await app.addAddress(v.trim());
                  if (context.mounted) toast(context, ok ? '已添加，正在尝试连接' : '这个地址已经存在');
                },
              ),
            ],
          ),
        if (current != null)
          PdGroup(
            header: '当前电脑',
            children: [
              PdCell(title: '证书指纹', value: current.fingerprint.length > 16 ? '${current.fingerprint.substring(0, 16)}…' : current.fingerprint, arrow: false),
              if (status != null) PdCell(title: '电脑端版本', value: status.version, arrow: false),
              if (status != null) PdCell(title: '系统', value: status.os, arrow: false),
              PdCell(
                title: '解除配对',
                danger: true,
                arrow: false,
                onTap: () async {
                  final ok = await confirm(context,
                      title: '解除与「${current.name}」的配对',
                      message: '将删除手机上与这台电脑相关的聊天缓存和传输记录。电脑上的会话和文件不受影响。',
                      ok: '解除配对',
                      danger: true);
                  if (ok) await app.removeHost(current.id);
                },
              ),
            ],
          ),
        PdGroup(children: [
          PdCell(icon: LucideIcons.scanLine300, title: '配对新电脑', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage()))),
        ]),
      ]),
    );
  }
}

/**
 * AboutPage：关于
 */
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Scaffold(
      appBar: const PdBar(title: '关于'),
      body: ListView(children: [
        const SizedBox(height: 40),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(16)),
            child: const Icon(LucideIcons.monitorSmartphone300, color: Colors.white, size: 36),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text('PocketDesk', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text))),
        const SizedBox(height: 4),
        Center(child: Text('版本 $appVersion', style: TextStyle(fontSize: PdFont.summary, color: c.text3))),
        const SizedBox(height: 32),
        PdGroup(children: [
          PdCell(title: '开源许可', onTap: () => showLicensePage(context: context, applicationName: 'PocketDesk', applicationVersion: appVersion)),
        ]),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text('在手机上与电脑上的 AI 编程工具对话、浏览工作区文件、双向传输文件。\n所有数据只在你的手机与电脑之间传输。',
              textAlign: TextAlign.center, style: TextStyle(fontSize: PdFont.time, color: c.text3, height: 1.6)),
        ),
      ]),
    );
  }
}
