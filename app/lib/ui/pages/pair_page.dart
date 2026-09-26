/**
 * 配对页：扫描电脑上的二维码配对；也可以手动输入配对码，连接局域网内发现的电脑。配对期间等待电脑端点「允许」。
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/discovery.dart';
import '../../core/pairing.dart';
import '../../core/pairing_service.dart';
import '../../data/models.dart';
import '../tokens.dart';
import '../widgets.dart';

/** runPairing：显示等待框执行配对，成功后切换到新电脑并返回首页 */
Future<void> runPairing(BuildContext context, Future<PairedHost> Function() job) async {
  final nav = Navigator.of(context);
  final app = context.read<AppState>();
  final c = context.pd;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
          const SizedBox(width: 16),
          const Expanded(child: Text('正在配对，请在电脑上点「允许」')),
        ]),
      ),
    ),
  ));
  try {
    final host = await job();
    await app.addHost(host);
    nav.pop();
    nav.popUntil((r) => r.isFirst);
    if (context.mounted) toast(context, '已连接 ${host.name}');
  } catch (e) {
    nav.pop();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('配对没有成功'),
          content: Text(e is PairError ? e.message : '$e'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了'))],
        ),
      );
    }
  }
}

/**
 * PairPage：扫码配对
 */
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> with SingleTickerProviderStateMixin {
  final _scanner = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  late final AnimationController _line = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat();
  bool _busy = false;
  String _hint = '';

  @override
  void dispose() {
    _line.dispose();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  /** _onDetect：识别到二维码 */
  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final raw = cap.barcodes.map((b) => b.rawValue ?? '').firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    final t = PairTicket.parse(raw);
    if (t == null) {
      setState(() => _hint = '这不是 PocketDesk 的配对二维码');
      return;
    }
    _busy = true;
    unawaited(HapticFeedback.mediumImpact());
    await _scanner.stop();
    if (!mounted) return;
    await runPairing(context, () => context.read<PairingService>().pairTicket(t));
    _busy = false;
    if (mounted) await _scanner.start();
  }

  @override
  Widget build(BuildContext context) {
    const box = 240.0;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0B),
      body: Stack(children: [
        Positioned.fill(
          child: MobileScanner(
            controller: _scanner,
            onDetect: _onDetect,
            errorBuilder: (context, err) => Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Text('无法使用相机，请在系统设置中允许 PocketDesk 使用相机，或改用手动输入配对码',
                    textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFD8D8D8), fontSize: 14, height: 1.6)),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(children: [
            SizedBox(
              height: PdSize.chatBar,
              child: Row(children: [
                PdIconButton(icon: LucideIcons.chevronLeft300, color: Colors.white, tooltip: '返回', onTap: () => Navigator.maybePop(context)),
                const Expanded(child: Text('扫描电脑上的二维码', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
                const SizedBox(width: PdSize.touch),
              ]),
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: box,
                  height: box,
                  child: AnimatedBuilder(
                    animation: _line,
                    builder: (context, _) => CustomPaint(painter: _FramePainter(_line.value, context.pd.accent)),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(_hint.isNotEmpty ? _hint : '将取景框对准电脑「配对新手机」\n页面上显示的二维码',
                  textAlign: TextAlign.center, style: TextStyle(color: _hint.isNotEmpty ? const Color(0xFFF2C94C) : const Color(0xFFD8D8D8), fontSize: 14, height: 1.6)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 20, 0, 32),
              child: Column(children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ManualPairPage())),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFB2B2B2)),
                  icon: const Icon(LucideIcons.keyboard300, size: 18),
                  label: const Text('手动输入配对码', style: TextStyle(fontSize: 14)),
                ),
                const SizedBox(height: 12),
                Semantics(
                  label: '手电筒',
                  button: true,
                  child: GestureDetector(
                    onTap: () => _scanner.toggleTorch(),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                      child: const Icon(LucideIcons.flashlight300, size: 22, color: Color(0xFF1A1A1A)),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/** _FramePainter：取景框四角与扫描线 */
class _FramePainter extends CustomPainter {
  _FramePainter(this.t, this.accent);

  final double t;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    const len = 26.0;
    final p = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    for (final (o, dx, dy) in [(Offset.zero, 1.0, 1.0), (Offset(w, 0), -1.0, 1.0), (Offset(0, h), 1.0, -1.0), (Offset(w, h), -1.0, -1.0)]) {
      canvas.drawLine(o, o + Offset(len * dx, 0), p);
      canvas.drawLine(o, o + Offset(0, len * dy), p);
    }
    final y = 10 + (h - 20) * t;
    final line = Paint()
      ..color = accent
      ..strokeWidth = 2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    canvas.drawLine(Offset(10, y), Offset(w - 10, y), line);
  }

  @override
  bool shouldRepaint(_FramePainter old) => old.t != t;
}

/**
 * ManualPairPage：手动输入配对码，选择局域网内发现的电脑
 */
class ManualPairPage extends StatefulWidget {
  const ManualPairPage({super.key, this.discovery});

  final Discovery? discovery;

  @override
  State<ManualPairPage> createState() => _ManualPairPageState();
}

class _ManualPairPageState extends State<ManualPairPage> {
  late final Discovery _disc = widget.discovery ?? Discovery();
  final _found = <String, Found>{};
  final _code = TextEditingController();
  StreamSubscription<Found>? _sub;
  String? _picked;

  @override
  void initState() {
    super.initState();
    _sub = _disc.found.listen((f) => setState(() {
          _found[f.fpPrefix.isEmpty ? f.ip : f.fpPrefix] = f;
          _picked ??= _found.keys.first;
        }));
    unawaited(_disc.start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_disc.stop());
    _code.dispose();
    super.dispose();
  }

  bool get _ready => _picked != null && normalizeCode(_code.text).length == 8;

  /** _submit：提交配对 */
  Future<void> _submit() async {
    final f = _found[_picked];
    if (f == null) return;
    final svc = context.read<PairingService>();
    await runPairing(context, () => svc.pairManual(ip: f.ip, port: f.port, fpPrefix: f.fpPrefix, code: _code.text, name: f.name));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Scaffold(
      appBar: const PdBar(title: '手动输入配对码'),
      body: ListView(padding: const EdgeInsets.only(top: 16), children: [
        PdGroup(
          header: '配对码',
          footer: '配对码显示在电脑「配对新手机」页面二维码下方，5 分钟内有效。',
          children: [
            Container(
              color: c.card,
              padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 8),
              child: TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                maxLength: 9,
                autocorrect: false,
                enableSuggestions: false,
                style: TextStyle(fontSize: 22, letterSpacing: 4, color: c.text, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(hintText: 'XXXX-XXXX', counterText: ''),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        PdGroup(
          header: '附近的电脑',
          footer: _found.isEmpty ? '正在查找同一网络下的电脑。找不到时请确认手机和电脑连接同一个 Wi-Fi，或改用扫码配对。' : '',
          children: [
            if (_found.isEmpty)
              Container(
                color: c.card,
                height: PdSize.settingItem,
                alignment: Alignment.center,
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
              ),
            for (final e in _found.entries)
              PdCell(
                icon: LucideIcons.laptop300,
                title: e.value.name,
                subtitle: e.value.ip,
                arrow: false,
                onTap: () => setState(() => _picked = e.key),
                trailing: _picked == e.key ? Icon(LucideIcons.check300, color: c.accent, size: 20) : null,
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(PdSize.gutter),
          child: FilledButton(onPressed: _ready ? _submit : null, child: const Text('配对')),
        ),
      ]),
    );
  }
}
