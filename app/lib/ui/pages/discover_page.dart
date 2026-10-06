/**
 * 发现：文件、传输、剪切板、收藏夹、提示词、截取电脑屏幕的入口。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/auth_gate.dart';
import '../../net/api.dart';
import '../../transfer/task.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'files_page.dart';
import 'library_pages.dart';
import 'transfer_page.dart';

/**
 * DiscoverPage：发现
 */
class DiscoverPage extends StatelessWidget {
  const DiscoverPage({super.key});

  void _open(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  /** _screenshot：验证身份后让电脑截屏，截图稍后在文件传输助手里收到 */
  Future<void> _screenshot(BuildContext context) async {
    final scope = context.read<AppState>().scope;
    if (scope == null) {
      toast(context, '请先配对电脑');
      return;
    }
    if (!await context.read<AuthGate>().ensure('验证身份以截取电脑屏幕') || !context.mounted) return;
    try {
      await scope.conn.api.screenshot();
      if (context.mounted) toast(context, '已截屏，截图会发到文件传输助手');
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.offline ? '电脑不在线，稍后再试' : e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = context.watch<AppState>().scope;
    return Scaffold(
      appBar: const PdBar(title: '发现'),
      body: ListView(padding: const EdgeInsets.only(top: 12), children: [
        PdGroup(children: [
          PdCell(icon: LucideIcons.folderOpen300, tint: PdTint.files, title: '文件', subtitle: '浏览电脑上的工作区', onTap: () => _open(context, const FilesPage())),
          if (scope == null)
            PdCell(icon: LucideIcons.arrowUpDown300, tint: PdTint.transfer, title: '传输', subtitle: '手机与电脑互传文件', onTap: () => _open(context, const TransferPage()))
          else
            ListenableBuilder(
              listenable: scope.transfers,
              builder: (context, _) {
                final running = scope.transfers.tasks.where((t) => t.status == TaskStatus.running || t.status == TaskStatus.queued).length;
                return PdCell(
                  icon: LucideIcons.arrowUpDown300,
                  tint: PdTint.transfer,
                  title: '传输',
                  subtitle: running > 0 ? '$running 个任务进行中' : '手机与电脑互传文件',
                  trailing: running > 0 ? const DotBadge() : null,
                  onTap: () => _open(context, const TransferPage()),
                );
              },
            ),
        ]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.clipboardPaste300, tint: PdTint.clipboard, title: '剪切板', subtitle: '文字、图片、文件在手机和电脑之间中转', onTap: () => _open(context, const ClipboardPage())),
          PdCell(icon: LucideIcons.star300, tint: PdTint.favorites, title: '收藏夹', subtitle: '聊天里存下来的内容', onTap: () => _open(context, const FavoritesPage())),
          PdCell(icon: LucideIcons.messageSquareText300, tint: PdTint.prompts, title: '提示词', subtitle: '常用提示词，聊天时一点即用', onTap: () => _open(context, const PromptsPage())),
        ]),
        PdGroup(children: [
          PdCell(icon: LucideIcons.monitor300, tint: PdTint.screen, title: '截取电脑屏幕', subtitle: '截图发到文件传输助手', onTap: () => _screenshot(context)),
        ]),
      ]),
    );
  }
}
