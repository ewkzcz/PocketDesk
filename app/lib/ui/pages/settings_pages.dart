/**
 * 设置页：传输设置（含文件保存位置）、安全设置、已配对电脑管理、关于。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../core/connection.dart';
import '../../core/phone_space.dart';
import '../../core/settings.dart';
import '../../net/api.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'pair_page.dart';
import 'places.dart';

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
          footer: '关闭后，电脑发来的文件留在文件传输助手里，点一下再接收。',
          children: [
            PdCell(title: '自动接收电脑发来的文件', trailing: Switch(value: s.autoReceive, onChanged: (v) => s.autoReceive = v)),
          ],
        ),
        const _SaveLocations(),
      ]),
    );
  }
}

/**
 * _SaveLocations：文件保存位置——电脑收件目录（可用文件夹选择器更换，立即生效）与手机工作空间
 */
class _SaveLocations extends StatefulWidget {
  const _SaveLocations();

  @override
  State<_SaveLocations> createState() => _SaveLocationsState();
}

class _SaveLocationsState extends State<_SaveLocations> {
  ({String inbox, String defaultWorkspace})? _dirs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().scope?.conn.api.dirs();
      if (mounted && d != null) setState(() => _dirs = d);
    } on ApiException {
      // 电脑不在线时只显示手机上的位置
    }
  }

  /** _change：用文件夹选择器更换电脑收件目录 */
  Future<void> _change() async {
    final p = await pickComputerFolder(context, title: '电脑收件目录', action: '使用这个文件夹');
    if (p == null || !mounted) return;
    try {
      await context.read<AppState>().scope!.conn.api.setDirs(inbox: p);
      if (mounted) toast(context, '已更换');
      await _load();
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _dirs;
    final phone = context.watch<AppState>().phone;
    return PdGroup(
      header: '文件保存位置',
      footer: '两边互传的文件分别存到电脑收件目录和手机工作空间下的日期文件夹。',
      children: [
        PdCell(icon: LucideIcons.monitorDown300, title: '电脑收件目录', subtitle: d?.inbox ?? '电脑不在线', onTap: d == null ? null : _change),
        PdCell(icon: LucideIcons.smartphone300, title: '手机工作空间', subtitle: phone.root, onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneSpacePage()))),
      ],
    );
  }
}

/**
 * PhoneSpacePage：手机工作空间——授权、查看与更换目录；电脑桌面端的「手机文件」管理的就是这个文件夹
 */
class PhoneSpacePage extends StatefulWidget {
  const PhoneSpacePage({super.key});

  @override
  State<PhoneSpacePage> createState() => _PhoneSpacePageState();
}

class _PhoneSpacePageState extends State<PhoneSpacePage> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(context.read<AppState>().phone.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /** 从系统授权页回来时刷新授权状态 */
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(context.read<AppState>().phone.refresh());
  }

  /** _pick：用手机的文件夹选择器更换目录 */
  Future<void> _pick() async {
    final space = context.read<AppState>().phone;
    final p = await FilePicker.getDirectoryPath(dialogTitle: '选择手机工作空间');
    if (p == null || !mounted) return;
    try {
      await space.setRoot(p);
      if (mounted) toast(context, '已更换');
    } on PhoneFsError catch (e) {
      if (mounted) toast(context, e.message);
    } on FileSystemException {
      if (mounted) toast(context, '没有权限使用这个文件夹');
    }
  }

  @override
  Widget build(BuildContext context) {
    final space = context.watch<AppState>().phone;
    return ListenableBuilder(
      listenable: space,
      builder: (context, _) => Scaffold(
        appBar: const PdBar(title: '手机工作空间'),
        body: ListView(padding: const EdgeInsets.only(top: 16), children: [
          PdGroup(
            footer: '电脑发来的文件存到这里的日期文件夹；电脑桌面端的「手机文件」可以浏览、上传、删除、新建文件夹和编辑这里的文件。',
            children: [
              PdCell(icon: LucideIcons.folderOpen300, title: '目录', subtitle: space.root, arrow: false),
              PdCell(
                icon: space.permitted ? LucideIcons.shieldCheck300 : LucideIcons.shieldAlert300,
                title: space.permitted ? '已授权访问手机存储' : '未授权访问手机存储',
                subtitle: space.permitted ? '' : '授权后电脑才能管理这个文件夹',
                trailing: space.permitted ? null : TextButton(onPressed: () => space.device.requestAllFiles(), child: const Text('去授权')),
                arrow: false,
              ),
            ],
          ),
          PdGroup(children: [
            PdCell(icon: LucideIcons.folderCog300, title: '更换目录', onTap: space.permitted ? _pick : null),
            if (space.root != space.defaultRoot)
              PdCell(icon: LucideIcons.rotateCcw300, title: '恢复默认目录', subtitle: space.defaultRoot, onTap: () => space.setRoot(space.defaultRoot)),
          ]),
        ]),
      ),
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
    final conn = app.scope?.conn;
    final status = conn?.status;
    final manual = conn?.manualAddress ?? '';
    return Scaffold(
      appBar: const PdBar(title: '已配对的电脑'),
      body: ListView(padding: const EdgeInsets.only(top: 16), children: [
        if (app.hosts.isEmpty) const SizedBox(height: 240, child: EmptyHint(icon: LucideIcons.laptop300, text: '还没有配对电脑')),
        if (app.hosts.isNotEmpty)
          PdGroup(
            header: '点击切换电脑；点当前电脑重新连接',
            children: [
              for (final h in app.hosts)
                PdCell(
                  icon: LucideIcons.laptop300,
                  title: h.name,
                  subtitle: h.id == current?.id
                      ? (conn?.online == true ? '在线 · ${conn!.kindLabel}' : (conn?.probing == true ? '连接中…' : '离线，点击重新连接'))
                      : '${h.addresses.length} 个连接地址',
                  arrow: false,
                  trailing: h.id == current?.id ? Icon(LucideIcons.check300, color: c.accent, size: 20) : null,
                  onTap: () async {
                    if (h.id != current?.id) {
                      await app.switchHost(h.id);
                      return;
                    }
                    toast(context, '正在连接…');
                    final ok = await app.reconnect();
                    if (context.mounted) toast(context, ok ? '已连接' : (app.scope?.conn.lastError.isNotEmpty == true ? app.scope!.conn.lastError : '连接不上电脑'));
                  },
                ),
            ],
          ),
        if (current != null)
          PdGroup(
            header: '连接地址（默认自动选择，也可以点一个地址指定它）',
            footer: '不在同一网络时：电脑和手机都安装并登录同一个 Tailscale 账号，连接后会自动记住电脑的 Tailscale 地址；也可以手动添加 Tailscale 名称或自建隧道的地址。',
            children: [
              PdCell(
                icon: LucideIcons.route300,
                title: '自动选择',
                subtitle: '局域网优先，延迟最低的地址',
                arrow: false,
                trailing: manual.isEmpty ? Icon(LucideIcons.check300, color: c.accent, size: 20) : null,
                onTap: () async {
                  if (manual.isEmpty) return;
                  final ok = await app.useAddress('');
                  if (context.mounted) toast(context, ok ? '已改为自动选择' : '连接不上电脑');
                },
              ),
              for (final a in conn?.host.addresses ?? current.addresses)
                PdCell(
                  title: a,
                  value: [
                    if (conn?.online == true && conn?.address == a) '正在使用',
                    if (manual == a) '已指定',
                    isTailscale(a) ? 'Tailscale' : '局域网',
                  ].join(' · '),
                  arrow: false,
                  onTap: () async {
                    final i = await actionSheet(context, const [SheetAction('使用这个地址连接'), SheetAction('删除这个地址', danger: true)], title: a);
                    if (!context.mounted) return;
                    if (i == 0) {
                      toast(context, '正在连接…');
                      final ok = await app.useAddress(a);
                      if (context.mounted) toast(context, ok ? '已连接到 $a' : '连不上这个地址');
                    } else if (i == 1 && !await app.removeAddress(a) && context.mounted) {
                      toast(context, '至少需要保留一个地址');
                    }
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

/**
 * RemotePage：异地连接——不在同一个局域网时通过 Tailscale（基于 WireGuard 的加密组网）连接电脑
 */
class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  bool? _phoneReady;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /** 从浏览器或 Tailscale 回来时重新检测 */
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  /** _check：手机上是否已有 Tailscale 地址，并刷新电脑端状态 */
  Future<void> _check() async {
    final conn = context.read<AppState>().scope?.conn;
    var ready = false;
    try {
      for (final nic in await NetworkInterface.list()) {
        if (nic.addresses.any((a) => isTailscale(a.address))) ready = true;
      }
    } catch (_) {
      ready = false;
    }
    if (mounted) setState(() => _phoneReady = ready);
    if (conn != null) unawaited(conn.refreshStatus());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final conn = app.scope?.conn;
    return ListenableBuilder(
      listenable: conn ?? ValueNotifier(0),
      builder: (context, _) {
        final st = conn?.status;
        final pc = switch (st?.remoteState) {
          'ready' => '已连通 · ${st!.remoteAddresses.join('、')}',
          'offline' => '已安装，还没登录',
          'missing' => '还没安装，在电脑端「设置 → 概览」里点「下载 Tailscale」',
          _ => conn?.online == true ? '电脑端版本较旧，无法检测' : '电脑不在线',
        };
        final phone = switch (_phoneReady) { true => '已连通', false => '还没安装或没登录', null => '检测中…' };
        return Scaffold(
          appBar: const PdBar(title: '异地连接'),
          body: ListView(padding: const EdgeInsets.only(top: 16), children: [
            PdGroup(
              footer: '不在同一个局域网时，电脑和手机都装上 Tailscale 并登录同一个账号，就能在外面用流量连接电脑；手机会先试局域网，连不上自动改走 Tailscale。',
              children: [
                PdCell(icon: LucideIcons.monitor300, title: '电脑', subtitle: pc, arrow: false),
                PdCell(icon: LucideIcons.smartphone300, title: '本机', subtitle: phone, arrow: false),
                if (conn?.online == true) PdCell(icon: LucideIcons.route300, title: '当前连接方式', subtitle: conn!.kindLabel, arrow: false),
              ],
            ),
            PdGroup(children: [
              PdCell(icon: LucideIcons.download300, title: '下载 Tailscale', subtitle: '打开 Tailscale 的下载页面', onTap: () => app.phone.device.openTailscaleStore()),
              PdCell(icon: LucideIcons.refreshCw300, title: '重新检测', onTap: _check),
            ]),
          ]),
        );
      },
    );
  }
}

