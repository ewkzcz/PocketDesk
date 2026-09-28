/**
 * 我：当前电脑卡片（在线状态、连接方式、延迟）、配对新电脑、工作空间、异地连接、手机工作空间、传输设置、安全设置、外观、日志导出、关于。
 */
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_log.dart';
import '../../core/app_state.dart';
import '../../core/settings.dart';
import '../../net/api.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'pair_page.dart';
import 'places.dart';
import 'settings_pages.dart';

/**
 * MePage：我
 */
class MePage extends StatelessWidget {
  const MePage({super.key});

  /** _theme：选择外观 */
  Future<void> _theme(BuildContext context) async {
    final s = context.read<AppSettings>();
    const modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];
    const labels = ['跟随系统', '浅色', '深色'];
    final i = await actionSheet(context, [for (var j = 0; j < 3; j++) SheetAction(labels[j], icon: s.themeMode == modes[j] ? LucideIcons.check300 : null)], title: '外观');
    if (i != null) s.themeMode = modes[i];
  }

  /**
   * _exportLogs：导出日志
   *
   * 处理流程：
   * 1、选择导出手机日志或电脑日志
   * 2、生成文件后通过系统分享发出
   */
  Future<void> _exportLogs(BuildContext context) async {
    final app = context.read<AppState>();
    // 1、选择
    final i = await actionSheet(context, [
      const SheetAction('导出手机日志', icon: LucideIcons.smartphone300),
      if (app.scope != null) const SheetAction('导出电脑日志', icon: LucideIcons.laptop300),
    ], title: '日志已去除令牌等敏感信息');
    if (i == null || !context.mounted) return;
    // 2、生成并分享
    try {
      await app.paths.temp.create(recursive: true);
      if (i == 0) {
        final log = AppLog.instance;
        if (log == null) return;
        final f = await log.export(app.paths.temp, header: 'PocketDesk $appVersion · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
        await shareFile(f.path, title: '手机日志');
      } else {
        if (context.mounted) toast(context, '正在打包电脑日志…');
        final bytes = await app.scope!.conn.api.exportLogs();
        final f = File('${app.paths.temp.path}${Platform.pathSeparator}pocketdesk-desktop-logs.zip');
        await f.writeAsBytes(bytes);
        await shareFile(f.path, title: '电脑日志');
      }
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    } catch (e) {
      if (context.mounted) toast(context, '导出失败');
      AppLog.e('logs', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: const PdBar(title: '我'),
      body: ListView(padding: const EdgeInsets.only(top: 12), children: [
        _HostCard(scope: app.scope),
        PdGroup(children: [
          PdCell(icon: LucideIcons.scanLine300, title: '配对新电脑', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage()))),
        ]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.folderTree300, title: '工作空间', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WorkspacesPage()))),
          PdCell(icon: LucideIcons.globe300, title: '异地连接', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RemotePage()))),
          PdCell(icon: LucideIcons.smartphone300, title: '手机工作空间', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PhoneSpacePage()))),
          PdCell(icon: LucideIcons.arrowUpDown300, title: '传输设置', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TransferSettingsPage()))),
          PdCell(icon: LucideIcons.shieldCheck300, title: '安全设置', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SecuritySettingsPage()))),
          PdCell(icon: LucideIcons.palette300, title: '外观', value: settings.themeLabel, onTap: () => _theme(context)),
        ]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.fileText300, title: '日志导出', onTap: () => _exportLogs(context)),
          PdCell(icon: LucideIcons.info300, title: '关于', value: 'v$appVersion', onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutPage()))),
        ]),
      ]),
    );
  }
}

/**
 * _HostCard：当前电脑卡片
 */
class _HostCard extends StatelessWidget {
  const _HostCard({required this.scope});

  final HostScope? scope;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final s = scope;
    void open() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ComputersPage()));
    Widget card(String name, Widget status) => Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Material(
            color: c.card,
            borderRadius: BorderRadius.circular(PdSize.cardRadius),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: open,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: c.page, borderRadius: BorderRadius.circular(10)),
                    child: Icon(LucideIcons.laptop300, size: 26, color: c.text2),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.listTitle, color: c.text, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 4),
                      status,
                    ]),
                  ),
                  Icon(LucideIcons.chevronRight300, size: 18, color: c.text4),
                ]),
              ),
            ),
          ),
        );
    if (s == null) return card('未连接电脑', Text('点击管理已配对的电脑', style: TextStyle(fontSize: PdFont.time, color: c.text3)));
    return ListenableBuilder(
      listenable: s.conn,
      builder: (context, _) {
        final conn = s.conn;
        final online = conn.online;
        final text = online ? '在线 · ${conn.kindLabel} · ${conn.latency.inMilliseconds}ms' : (conn.probing ? '连接中…' : '离线');
        final color = online ? c.accent : c.text3;
        return card(
          conn.status?.name.isNotEmpty == true ? conn.status!.name : s.host.name,
          Row(children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: color))),
          ]),
        );
      },
    );
  }
}
