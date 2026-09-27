/**
 * 主框架：底部四个 Tab（消息、文件、传输、我），打开 App 与回到前台时的身份验证，接收系统分享。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../core/auth_gate.dart';
import '../core/settings.dart';
import '../transfer/task.dart';
import 'pages/files_page.dart';
import 'pages/me_page.dart';
import 'pages/sessions_page.dart';
import 'pages/transfer_page.dart';
import 'tokens.dart';

/** ShareSource：系统分享来源，测试时为空 */
typedef ShareSource = ({Future<List<({String path, String mime, bool text})>> Function() initial, Stream<List<({String path, String mime, bool text})>> stream});

/**
 * HomeShell：主框架
 */
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.share});

  final ShareSource? share;

  @override
  State<HomeShell> createState() => HomeShellState();
}

/** HomeShellState：记录当前 Tab，其他页面可切换 */
class HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int tab = 0;
  bool locked = true;
  bool _authing = false;
  StreamSubscription<dynamic>? _shareSub;

  /** of：取得主框架（用于从其他页面切换 Tab） */
  static HomeShellState? of(BuildContext context) => context.findAncestorStateOfType<HomeShellState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
    final share = widget.share;
    if (share != null) {
      unawaited(share.initial().then(_onShared).catchError((Object _) {}));
      _shareSub = share.stream.listen(_onShared, onError: (_) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final gate = context.read<AuthGate>();
    if (state == AppLifecycleState.paused) {
      gate.touch();
      context.read<AppState>().foreground = false;
    } else if (state == AppLifecycleState.resumed) {
      context.read<AppState>().onResume();
      if (!gate.fresh && gate.enabled()) {
        setState(() => locked = true);
        _unlock();
      }
    }
  }

  /** _unlock：验证身份后显示内容 */
  Future<void> _unlock() async {
    if (_authing) return;
    _authing = true;
    final ok = await context.read<AuthGate>().ensure('验证身份以打开 PocketDesk');
    _authing = false;
    if (mounted && ok) {
      setState(() => locked = false);
      unawaited(_backgroundHint());
    }
  }

  /** _backgroundHint：Android 首次配对后提示允许后台运行，避免传输被系统中断（只提示一次） */
  Future<void> _backgroundHint() async {
    final settings = context.read<AppSettings>();
    if (!Platform.isAndroid || settings.backgroundHintShown || context.read<AppState>().scope == null) return;
    settings.backgroundHintShown = true;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('允许后台运行'),
        content: const Text('部分手机会限制应用在后台运行，导致传输中断。建议在系统设置中把 PocketDesk 加入「允许后台运行」和「自启动」。'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
      ),
    );
  }

  /** _onShared：系统分享进来的文件或文字发到文件传输助手 */
  Future<void> _onShared(List<({String path, String mime, bool text})> items) async {
    if (items.isEmpty || !mounted) return;
    final app = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    if (app.scope == null) {
      messenger.showSnackBar(const SnackBar(content: Text('请先配对电脑再分享')));
      return;
    }
    final files = [for (final i in items.where((i) => !i.text)) (path: i.path, mime: i.mime)];
    final text = items.where((i) => i.text).map((i) => i.path).join('\n');
    final n = await app.shareFiles(files, text: text);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(n > 0 ? '已发送到文件传输助手' : '没有可发送的内容')));
    if (files.isNotEmpty) select(2);
  }

  /** select：切换 Tab */
  void select(int i) => setState(() => tab = i);

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    if (locked) return LockView(onUnlock: _unlock);
    final app = context.watch<AppState>();
    final scope = app.scope;
    return Scaffold(
      body: IndexedStack(index: tab, children: const [SessionsPage(), FilesPage(), TransferPage(), MePage()]),
      bottomNavigationBar: ListenableBuilder(
        listenable: Listenable.merge([scope?.sessions, scope?.transfers]),
        builder: (context, _) {
          final unread = scope?.sessions.totalUnread ?? 0;
          final running = scope?.transfers.tasks.where((t) => t.status == TaskStatus.running || t.status == TaskStatus.queued).length ?? 0;
          return Container(
            decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: PdSize.tabBar,
                child: Row(children: [
                  _TabItem(icon: LucideIcons.messageCircle300, label: '消息', active: tab == 0, badge: unread, onTap: () => select(0)),
                  _TabItem(icon: LucideIcons.folder300, label: '文件', active: tab == 1, onTap: () => select(1)),
                  _TabItem(icon: LucideIcons.arrowUpDown300, label: '传输', active: tab == 2, dot: running > 0, onTap: () => select(2)),
                  _TabItem(icon: LucideIcons.user300, label: '我', active: tab == 3, dot: app.scope == null && app.ready, onTap: () => select(3)),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }
}

/** _TabItem：底部 Tab 按钮 */
class _TabItem extends StatelessWidget {
  const _TabItem({required this.icon, required this.label, required this.active, required this.onTap, this.badge = 0, this.dot = false});

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badge;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final color = active ? c.accent : c.text3;
    return Expanded(
      child: Semantics(
        selected: active,
        button: true,
        label: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(icon, size: 24, color: color),
              if (badge > 0)
                Positioned(
                  left: 14,
                  top: -5,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    height: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.danger, borderRadius: BorderRadius.circular(8)),
                    child: Text(badge > 99 ? '99+' : '$badge', style: const TextStyle(color: Colors.white, fontSize: 10, height: 1.1)),
                  ),
                )
              else if (dot)
                Positioned(right: -3, top: -1, child: Container(width: 8, height: 8, decoration: BoxDecoration(color: c.danger, shape: BoxShape.circle))),
            ]),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: PdFont.tab, color: color, height: 1.2)),
          ]),
        ),
      ),
    );
  }
}

/** LockView：等待身份验证 */
class LockView extends StatelessWidget {
  const LockView({super.key, required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Scaffold(
      backgroundColor: c.page,
      body: SafeArea(
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(16)),
              child: const Icon(LucideIcons.monitorSmartphone300, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 16),
            Text('PocketDesk', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: c.text)),
            const SizedBox(height: 32),
            TextButton.icon(onPressed: onUnlock, icon: const Icon(LucideIcons.fingerprint300), label: const Text('点击验证身份')),
          ]),
        ),
      ),
    );
  }
}
