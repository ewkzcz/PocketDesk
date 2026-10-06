/**
 * 头像：内置的 AI 标志与形象头像、从相册选的自定义图片；我和每个 AI 都能单独设置，形状跟随当前风格。
 */
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/settings.dart';
import 'styles.dart';
import 'tokens.dart';
import 'widgets.dart';

/** AvatarPreset：一个内置头像 */
class AvatarPreset {
  const AvatarPreset(this.id, this.label, this.asset);

  final String id;
  final String label;
  final String asset;
}

/** avatarPresets：内置头像（前六个是 AI 标志，后面是形象头像与默认头像） */
const avatarPresets = [
  AvatarPreset('claude', 'Claude', 'assets/avatars/logo-claude.svg'),
  AvatarPreset('codex', 'Codex', 'assets/avatars/logo-codex.svg'),
  AvatarPreset('openai', 'OpenAI', 'assets/avatars/logo-openai.svg'),
  AvatarPreset('gemini', 'Gemini', 'assets/avatars/logo-gemini.svg'),
  AvatarPreset('deepseek', 'DeepSeek', 'assets/avatars/logo-deepseek.svg'),
  AvatarPreset('pi', 'Pi', 'assets/avatars/logo-pi.svg'),
  AvatarPreset('me', '默认', 'assets/avatars/me.svg'),
  AvatarPreset('portrait-claude', '形象 橙', 'assets/avatars/claude.svg'),
  AvatarPreset('portrait-codex', '形象 绿', 'assets/avatars/codex.svg'),
  AvatarPreset('portrait-pi', '形象 紫', 'assets/avatars/pi.svg'),
  AvatarPreset('portrait-dsh', '形象 蓝', 'assets/avatars/dsh.svg'),
];

/** presetById：按编号取内置头像 */
AvatarPreset? presetById(String id) => avatarPresets.where((a) => a.id == id).firstOrNull;

/** defaultAvatarSpec：没设置过时各会话类型的默认头像 */
String defaultAvatarSpec(String key) => switch (key) {
      'me' => 'preset:me',
      'claude' => 'preset:claude',
      'codex' => 'preset:codex',
      'pi' => 'preset:pi',
      'dsh' => 'preset:deepseek',
      _ => '',
    };

/**
 * PdAvatar：按头像设置显示图片，形状（方、圆角、圆）跟随风格
 *
 * spec 为 preset:编号 或 file:路径；取不到图片时退回 fallback。
 */
class PdAvatar extends StatelessWidget {
  const PdAvatar({super.key, required this.spec, required this.size, required this.fallback, this.label = ''});

  final String spec;
  final double size;
  final Widget fallback;
  final String label;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(context.style.avatarRadiusFor(size));
    Widget? img;
    if (spec.startsWith('preset:')) {
      final a = presetById(spec.substring(7));
      if (a != null) img = SvgPicture.asset(a.asset, width: size, height: size, fit: BoxFit.cover, semanticsLabel: label.isEmpty ? a.label : label);
    } else if (spec.startsWith('file:')) {
      final f = File(spec.substring(5));
      img = Image.file(f, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 3).round(), semanticLabel: label, errorBuilder: (_, _, _) => fallback);
    }
    return SizedBox(width: size, height: size, child: ClipRRect(borderRadius: r, child: img ?? fallback));
  }
}

/** MyAvatar：我的头像 */
class MyAvatar extends StatelessWidget {
  const MyAvatar({super.key, this.size = PdSize.avatar});

  final double size;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final spec = s.avatarSpec('me');
    return PdAvatar(
      spec: spec.isEmpty ? defaultAvatarSpec('me') : spec,
      size: size,
      label: '我',
      fallback: Container(color: context.pd.accent, alignment: Alignment.center, child: Icon(LucideIcons.user300, color: Colors.white, size: size * 0.5)),
    );
  }
}

/** pickAvatar：弹出头像选择（内置头像、相册、恢复默认），选好后保存到 key 对应的设置 */
Future<void> pickAvatar(BuildContext context, {required String key, required String title}) async {
  final settings = context.read<AppSettings>();
  final r = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _AvatarSheet(title: title, current: settings.avatarSpec(key)),
  );
  if (r == null || !context.mounted) return;
  if (r == '@album') {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 90);
    if (x == null) return;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'avatars'));
    await dir.create(recursive: true);
    final dest = File(p.join(dir.path, '$key-${DateTime.now().millisecondsSinceEpoch}${p.extension(x.path).isEmpty ? '.jpg' : p.extension(x.path)}'));
    await File(x.path).copy(dest.path);
    final old = settings.avatarSpec(key);
    settings.setAvatarSpec(key, 'file:${dest.path}');
    if (old.startsWith('file:')) {
      try {
        await File(old.substring(5)).delete();
      } catch (_) {}
    }
    return;
  }
  settings.setAvatarSpec(key, r == '@default' ? '' : r);
}

/** _AvatarSheet：头像选择面板 */
class _AvatarSheet extends StatelessWidget {
  const _AvatarSheet({required this.title, required this.current});

  final String title;
  final String current;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(PdSize.gutter, 16, PdSize.gutter, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(fontSize: PdFont.body, fontWeight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 14),
          Wrap(spacing: 14, runSpacing: 14, children: [
            for (final a in avatarPresets)
              GestureDetector(
                onTap: () => Navigator.pop(context, 'preset:${a.id}'),
                child: SizedBox(
                  width: 56,
                  child: Column(children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(context.style.avatarRadiusFor(52) + 3),
                        border: Border.all(color: current == 'preset:${a.id}' ? c.accent : Colors.transparent, width: 2),
                      ),
                      child: Padding(padding: const EdgeInsets.all(2), child: PdAvatar(spec: 'preset:${a.id}', size: 48, fallback: const SizedBox())),
                    ),
                    const SizedBox(height: 4),
                    Text(a.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.tiny, color: c.text3)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, '@album'), icon: const Icon(LucideIcons.image300, size: 18), label: const Text('从相册选择'))),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(onPressed: () => Navigator.pop(context, '@default'), icon: const Icon(LucideIcons.rotateCcw300, size: 18), label: const Text('恢复默认'))),
          ]),
        ]),
      ),
    );
  }
}

/** AvatarCell：设置页里的头像行，点一下换头像 */
class AvatarCell extends StatelessWidget {
  const AvatarCell({super.key, required this.keyName, required this.title, required this.avatar});

  final String keyName;
  final String title;
  final Widget avatar;

  @override
  Widget build(BuildContext context) => PdCell(title: title, trailing: avatar, onTap: () => pickAvatar(context, key: keyName, title: '设置$title'));
}
