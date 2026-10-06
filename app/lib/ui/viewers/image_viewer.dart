/**
 * 看图：右上角放分享、下载与关闭按钮，双指捏合、双击或按钮都能缩放，放大时拖动平移，未放大时左右滑动切换同一目录的图片。
 */
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../share.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'fetch.dart';
import 'zoom_view.dart';

/** GalleryAction：看图页右上角的一个操作按钮 */
class GalleryAction {
  const GalleryAction(this.icon, this.tooltip, this.onTap);

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
}

/**
 * ImageGalleryPage：通用看图页，图片内容与右上角按钮由调用方提供
 */
class ImageGalleryPage extends StatefulWidget {
  const ImageGalleryPage({super.key, required this.count, required this.index, required this.titleOf, required this.loader, this.actionsOf});

  final int count;
  final int index;

  /** 第 i 张的名称 */
  final String Function(int i) titleOf;

  /** 取得第 i 张的图片内容，失败时抛出错误 */
  final Future<ImageProvider> Function(int i) loader;

  /** 第 i 张右上角的操作按钮（关闭按钮始终在最右） */
  final List<GalleryAction> Function(int i)? actionsOf;

  @override
  State<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _i = widget.index;
  final Map<int, ZoomController> _zooms = {};
  final Map<int, Future<ImageProvider>> _loads = {};
  bool _chrome = true;

  ZoomController _zoom(int i) => _zooms.putIfAbsent(i, () => ZoomController()..addListener(_onZoom));

  /** _onZoom：放大后改变翻页方式，刷新倍数显示 */
  void _onZoom() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final z in _zooms.values) {
      z.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = _zoom(_i);
    final actions = widget.actionsOf?.call(_i) ?? const <GalleryAction>[];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView.builder(
          controller: _pages,
          physics: z.zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          itemCount: widget.count,
          onPageChanged: (i) => setState(() => _i = i),
          itemBuilder: (_, i) => FutureBuilder<ImageProvider>(
            future: _loads[i] ??= widget.loader(i),
            builder: (context, snap) {
              if (snap.hasError) {
                final e = snap.error;
                return Center(child: Text(e is ApiException ? e.message : '图片加载失败', style: const TextStyle(color: PdDarkUi.overlayText)));
              }
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: PdDarkUi.overlaySpinner, strokeWidth: 2));
              return ZoomView(
                controller: _zoom(i),
                onTap: () => setState(() => _chrome = !_chrome),
                child: Image(image: snap.data!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Text('无法显示这张图片', style: TextStyle(color: PdDarkUi.overlayText))),
              );
            },
          ),
        ),
        // 顶部：名称与张数在左，操作按钮与关闭在右上角
        AnimatedPositioned(
          duration: PdMotion.fast,
          top: _chrome ? 0 : -120,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC000000), Color(0x00000000)])),
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 56,
                child: Row(children: [
                  const SizedBox(width: PdSize.gutter),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.titleOf(_i), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: PdFont.listTitle, fontWeight: FontWeight.w600)),
                      if (widget.count > 1) Text('${_i + 1} / ${widget.count}', style: const TextStyle(color: PdDarkUi.muted, fontSize: PdFont.tiny)),
                    ]),
                  ),
                  for (final a in actions) PdIconButton(icon: a.icon, tooltip: a.tooltip, color: Colors.white, onTap: a.onTap),
                  PdIconButton(icon: LucideIcons.x300, tooltip: '关闭', color: Colors.white, onTap: () => Navigator.of(context).maybePop()),
                  const SizedBox(width: 4),
                ]),
              ),
            ),
          ),
        ),
        // 底部：缩放按钮
        AnimatedPositioned(
          duration: PdMotion.fast,
          bottom: _chrome ? 0 : -120,
          left: 0,
          right: 0,
          child: SafeArea(top: false, child: Padding(padding: const EdgeInsets.only(bottom: 16), child: Center(child: ZoomBar(controller: z)))),
        ),
      ]),
    );
  }
}

/**
 * ImageViewerPage：看工作区里的图片
 */
class ImageViewerPage extends StatelessWidget {
  const ImageViewerPage({super.key, required this.ws, required this.images, required this.index});

  final Workspace ws;
  final List<FileEntry> images;
  final int index;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final files = <int, Future<File>>{};
    /** 下载第 i 张到缓存（同一张只下载一次） */
    Future<File> file(int i) => files[i] ??= () async {
          final e = images[i];
          final dest = cacheFileFor(app, ws.id, e.path);
          if (await dest.exists() && await dest.length() == e.size) return dest;
          return (await fetchWsFile(app.scope!, ws.id, e.path, dest)).file;
        }();
    return ImageGalleryPage(
      count: images.length,
      index: index,
      titleOf: (i) => images[i].name,
      loader: (i) async => FileImage(await file(i)),
      actionsOf: (i) => [
        GalleryAction(LucideIcons.share2300, '分享', () async {
          try {
            await shareFile((await file(i)).path);
          } on ApiException catch (err) {
            if (context.mounted) toast(context, err.message);
          }
        }),
        GalleryAction(LucideIcons.download300, '下载到手机', () async {
          final e = images[i];
          await app.scope!.transfers.download('ws:${ws.id}:${e.path}', e.name, e.size);
          if (context.mounted) toast(context, '已加入传输队列');
        }),
      ],
    );
  }
}
