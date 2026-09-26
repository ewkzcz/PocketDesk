/**
 * 看图：双指缩放，左右滑动切换同一目录的图片；可下载到手机或分享。
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

/**
 * ImageViewerPage：看图
 */
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.ws, required this.images, required this.index});

  final Workspace ws;
  final List<FileEntry> images;
  final int index;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _i = widget.index;
  final Map<int, Future<File>> _files = {};

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /** _file：下载第 i 张到缓存（同一张只下载一次） */
  Future<File> _file(int i) => _files[i] ??= () async {
        final app = context.read<AppState>();
        final e = widget.images[i];
        final dest = cacheFileFor(app, widget.ws.id, e.path);
        if (await dest.exists() && await dest.length() == e.size) return dest;
        return (await fetchToFile(app.scope!, app.scope!.conn.api.fileUrl(widget.ws.id, e.path), dest)).file;
      }();

  @override
  Widget build(BuildContext context) {
    final e = widget.images[_i];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: PdBar(
        title: e.name,
        subtitle: '${_i + 1} / ${widget.images.length}',
        dark: true,
        actions: [
          PdIconButton(icon: LucideIcons.share2300, tooltip: '分享', color: Colors.white, onTap: () async {
            try {
              await shareFile((await _file(_i)).path);
            } on ApiException catch (err) {
              if (context.mounted) toast(context, err.message);
            }
          }),
          PdIconButton(icon: LucideIcons.download300, tooltip: '下载到手机', color: Colors.white, onTap: () async {
            await context.read<AppState>().scope!.transfers.download('ws:${widget.ws.id}:${e.path}', e.name, e.size);
            if (context.mounted) toast(context, '已加入传输队列');
          }),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _i = i),
        itemBuilder: (_, i) => FutureBuilder<File>(
          future: _file(i),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(child: Text(snap.error is ApiException ? (snap.error! as ApiException).message : '图片加载失败', style: const TextStyle(color: PdDarkUi.overlayText)));
            }
            if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: PdDarkUi.overlaySpinner, strokeWidth: 2));
            return InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: Image.file(
                  snap.data!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Text('无法显示这张图片', style: TextStyle(color: PdDarkUi.overlayText)),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
