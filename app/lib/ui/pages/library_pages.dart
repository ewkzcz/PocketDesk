/**
 * 资料页：剪切板（文字、图片、文件在手机和电脑之间中转）、收藏夹、提示词，三者共用电脑上的同一份资料库。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../core/library_store.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../../transfer/naming.dart' as naming;
import '../chat/commands.dart' show QuickChip;
import '../chat/markdown.dart';
import '../format.dart';
import '../pick.dart';
import '../share.dart';
import '../tokens.dart';
import '../styles.dart';
import '../viewers/image_viewer.dart';
import '../widgets.dart';

/** _maxBlob：单个图片或文件的大小上限，与电脑端一致 */
const _maxBlob = 25 << 20;

/** _LibraryState：三个资料页共用的读取与错误处理 */
mixin _LibraryState<T extends StatefulWidget> on State<T> {
  HostScope? scope;

  /** 本页的资料类型 */
  String get kind;

  LibraryStore? get lib => scope?.library;

  @override
  void initState() {
    super.initState();
    scope = context.read<AppState>().scope;
    unawaited(lib?.refresh(kind));
  }

  /** run：执行操作，失败时提示 */
  Future<bool> run(Future<void> Function() f, {String done = ''}) async {
    try {
      await f();
      if (mounted && done.isNotEmpty) toast(context, done);
      return true;
    } on ApiException catch (e) {
      if (mounted) toast(context, e.offline ? '电脑不在线，稍后再试' : e.message);
    } on FileSystemException {
      if (mounted) toast(context, '读取文件失败');
    }
    return false;
  }
}

/** _offlineBody：没配对电脑时的提示 */
Widget _unpaired(String text) => EmptyHint(icon: LucideIcons.monitorSmartphone300, text: text);

/** _typeIcon：资料的类型图标 */
IconData _typeIcon(LibraryItem x) => x.isImage ? LucideIcons.image300 : (x.hasBlob ? LucideIcons.file300 : LucideIcons.textQuote300);

/** _LibraryList：带下拉刷新与空状态的资料列表 */
class _LibraryList extends StatelessWidget {
  const _LibraryList({required this.store, required this.kind, required this.items, required this.empty, required this.itemBuilder, this.header});

  final LibraryStore store;
  final String kind;
  final List<LibraryItem> items;
  final String empty;
  final Widget Function(BuildContext context, LibraryItem item) itemBuilder;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return RefreshIndicator(
      color: c.accent,
      onRefresh: () => store.refresh(kind),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        itemCount: items.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ?header,
              if (store.error.isNotEmpty && !store.loaded(kind)) Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text(store.error, style: TextStyle(color: c.text3, fontSize: PdFont.summary)))),
              if (items.isEmpty && store.loaded(kind)) Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Center(child: Text(empty, textAlign: TextAlign.center, style: TextStyle(color: c.text3, fontSize: PdFont.summary, height: 1.7)))),
              if (items.isEmpty && !store.loaded(kind) && store.error.isEmpty) const SizedBox(height: 60),
            ]);
          }
          return Padding(padding: const EdgeInsets.only(bottom: 10), child: itemBuilder(context, items[i - 1]));
        },
      ),
    );
  }
}

/** _Card：资料卡片外观 */
class _Card extends StatelessWidget {
  const _Card({required this.child, this.onTap, this.onLongPress});

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final st = context.style;
    return Container(
      decoration: st.card(context.pd),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: Padding(padding: const EdgeInsets.all(14), child: child)),
      ),
    );
  }
}

/** _MiniButton：卡片底部的小按钮 */
class _MiniButton extends StatelessWidget {
  const _MiniButton(this.icon, this.label, this.onTap);

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.style.smallRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: c.text2),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: PdFont.time, color: c.text2)),
        ]),
      ),
    );
  }
}

/** TextDetailPage：完整查看一段文字，可复制与分享 */
class TextDetailPage extends StatelessWidget {
  const TextDetailPage({super.key, required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PdBar(title: title.isEmpty ? '详情' : title, actions: [
        PdIconButton(
          icon: LucideIcons.copy300,
          tooltip: '复制',
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) toast(context, '已复制');
          },
        ),
        PdIconButton(icon: LucideIcons.share2300, tooltip: '分享', onTap: () => shareText(text)),
      ]),
      body: SingleChildScrollView(padding: const EdgeInsets.all(PdSize.gutter), child: SelectionArea(child: MdText(text))),
    );
  }
}

/* ======================= 剪切板 ======================= */

/**
 * ClipboardPage：剪切板
 *
 * 手机上粘贴或选取的文字、图片、文件会出现在电脑端的同一页，电脑上放进来的也会出现在这里。
 */
class ClipboardPage extends StatefulWidget {
  const ClipboardPage({super.key});

  @override
  State<ClipboardPage> createState() => _ClipboardPageState();
}

class _ClipboardPageState extends State<ClipboardPage> with _LibraryState<ClipboardPage> {
  @override
  String get kind => LibraryKind.clips;

  /** _pasteText：把手机剪贴板里的文字放进剪切板；没有文字时试图片 */
  Future<void> _paste() async {
    final device = context.read<AppState>().phone.device;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isNotEmpty) {
      await run(() => lib!.addText(kind, body: text), done: '已放进剪切板');
      return;
    }
    String? path;
    try {
      path = await device.clipboardImage();
    } catch (_) {
      path = null;
    }
    if (!mounted) return;
    if (path == null) {
      toast(context, '剪贴板里没有文字或图片');
      return;
    }
    await _addPicked([(path: path, name: path.split('/').last, mime: naming.mimeForName(path))]);
  }

  /** _compose：手动写一条文字 */
  Future<void> _compose() async {
    final t = await inputDialog(context, title: '写一条文字', hint: '内容', ok: '放进去', maxLines: 6);
    if (t == null || t.trim().isEmpty || !mounted) return;
    await run(() => lib!.addText(kind, body: t), done: '已放进剪切板');
  }

  /** _addPicked：把选好的图片或文件放进剪切板（单个不超过 25 MB） */
  Future<void> _addPicked(List<Picked> files) async {
    if (files.isEmpty) return;
    var ok = 0;
    for (final f in files) {
      final file = File(f.path);
      if (await file.length() > _maxBlob) {
        if (mounted) toast(context, '${f.name.isEmpty ? '文件' : f.name} 超过 25 MB，请改用传输功能');
        continue;
      }
      final name = f.name.isEmpty ? f.path.split(Platform.pathSeparator).last : f.name;
      final done = await run(() async => lib!.addBlob(kind, await file.readAsBytes(), mime: f.mime.isEmpty ? naming.mimeForName(name) : f.mime, name: name));
      if (done) ok++;
    }
    if (ok > 0 && mounted) toast(context, '已放进 $ok 项');
  }

  /** _copy：复制文字 */
  Future<void> _copy(LibraryItem x) async {
    await Clipboard.setData(ClipboardData(text: x.body));
    if (mounted) toast(context, '已复制');
  }

  /** _saveTemp：把图片或文件内容存到缓存目录，返回文件 */
  Future<File?> _saveTemp(LibraryItem x) async {
    File? out;
    final temp = context.read<AppState>().paths.temp.path;
    await run(() async {
      final bytes = await lib!.blob(x.id);
      final dir = Directory('$temp${Platform.pathSeparator}library');
      await dir.create(recursive: true);
      final name = x.name.isEmpty ? '${x.id}${x.isImage ? '.png' : ''}' : naming.sanitize(x.name);
      out = File('${dir.path}${Platform.pathSeparator}${x.id.substring(0, 6)}-$name');
      await out!.writeAsBytes(bytes);
    });
    return out;
  }

  /** _share：分享图片或文件 */
  Future<void> _share(LibraryItem x) async {
    final f = await _saveTemp(x);
    if (f != null) await shareFile(f.path, title: x.name);
  }

  /** _favorite：收藏到「收藏夹」 */
  Future<void> _favorite(LibraryItem x) async {
    await run(() async {
      if (x.hasBlob) {
        await lib!.addBlob(LibraryKind.favorites, await lib!.blob(x.id), mime: x.mime, name: x.name, title: x.title, meta: '来自剪切板');
      } else {
        await lib!.addText(LibraryKind.favorites, title: x.title, body: x.body, meta: '来自剪切板');
      }
    }, done: '已收藏');
  }

  /** _more：更多操作 */
  Future<void> _more(LibraryItem x) async {
    final i = await actionSheet(context, [
      SheetAction(x.pinned ? '取消置顶' : '置顶', icon: LucideIcons.pin300),
      const SheetAction('收藏', icon: LucideIcons.star300),
      if (x.isText) const SheetAction('做成提示词', icon: LucideIcons.messageSquareText300),
      const SheetAction('删除', icon: LucideIcons.trash2300, danger: true),
    ]);
    if (i == null || !mounted) return;
    final labels = [x.pinned ? '取消置顶' : '置顶', '收藏', if (x.isText) '做成提示词', '删除'];
    switch (labels[i]) {
      case '置顶' || '取消置顶':
        await run(() => lib!.update(x, pinned: !x.pinned));
      case '收藏':
        await _favorite(x);
      case '做成提示词':
        await run(() => lib!.addText(LibraryKind.prompts, title: x.body.trim().split('\n').first, body: x.body), done: '已存为提示词');
      case '删除':
        if (await confirm(context, title: '删除这条内容', message: '电脑端的剪切板也会同时删除。', ok: '删除', danger: true) && mounted) await run(() => lib!.remove(x));
    }
  }

  /** _openImage：在看图页里查看这张图（可左右切换剪切板里的其他图片） */
  void _openImage(LibraryItem x, List<LibraryItem> all) {
    final images = all.where((e) => e.isImage && e.hasBlob).toList();
    final i = images.indexWhere((e) => e.id == x.id);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImageGalleryPage(
        count: images.length,
        index: i < 0 ? 0 : i,
        titleOf: (i) => images[i].name.isEmpty ? '图片' : images[i].name,
        loader: (i) async => MemoryImage(await lib!.blob(images[i].id)),
        actionsOf: (i) => [GalleryAction(LucideIcons.share2300, '分享', () => _share(images[i]))],
      ),
    ));
  }

  /** _clear：清空未置顶的内容 */
  Future<void> _clear() async {
    if (!await confirm(context, title: '清空剪切板', message: '置顶的内容会保留，其余全部删除。', ok: '清空', danger: true) || !mounted) return;
    await run(() => lib!.clear(kind), done: '已清空');
  }

  Widget _content(LibraryItem x, List<LibraryItem> all) {
    final c = context.pd;
    if (x.isImage && x.hasBlob) {
      return GestureDetector(
        onTap: () => _openImage(x, all),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(context.style.smallRadius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, minHeight: 80),
            child: FutureBuilder(
              future: lib!.blob(x.id),
              builder: (context, snap) {
                if (snap.hasError) return SizedBox(height: 80, child: Center(child: Text('图片加载失败', style: TextStyle(color: c.text3, fontSize: PdFont.summary))));
                if (!snap.hasData) return SizedBox(height: 120, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c.text3))));
                return Image.memory(snap.data!, fit: BoxFit.cover, width: double.infinity, gaplessPlayback: true);
              },
            ),
          ),
        ),
      );
    }
    if (x.hasBlob) {
      return Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(context.style.smallRadius)),
          child: Icon(LucideIcons.file300, color: c.accent, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.name.isEmpty ? '文件' : x.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text)),
            Text(formatSize(x.size), style: TextStyle(fontSize: PdFont.time, color: c.text3)),
          ]),
        ),
      ]);
    }
    return GestureDetector(
      onTap: x.body.length > 240 || '\n'.allMatches(x.body).length > 7 ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TextDetailPage(title: '剪切板', text: x.body))) : null,
      child: Text(x.body, maxLines: 8, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text, height: 1.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final store = lib;
    if (store == null) return Scaffold(appBar: const PdBar(title: '剪切板'), body: _unpaired('配对电脑后，手机和电脑可以在这里互相中转文字、图片和文件'));
    return Scaffold(
      appBar: PdBar(title: '剪切板', actions: [PdIconButton(icon: LucideIcons.trash2300, tooltip: '清空', onTap: _clear)]),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final items = store.items(kind);
          return _LibraryList(
            store: store,
            kind: kind,
            items: items,
            empty: '还没有内容\n点上面的按钮放进来，电脑端的「剪切板」同步可见',
            header: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                QuickChip(label: '粘贴', icon: LucideIcons.clipboardPaste300, accent: true, onTap: _paste),
                QuickChip(label: '图片', icon: LucideIcons.image300, onTap: () async => _addPicked(await pickImages())),
                QuickChip(label: '文件', icon: LucideIcons.file300, onTap: () async => _addPicked(await pickFiles(context.read<AppState>().paths.temp))),
                QuickChip(label: '写一条', icon: LucideIcons.pencil300, onTap: _compose),
              ]),
            ),
            itemBuilder: (context, x) => _Card(
              onLongPress: () => _more(x),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(_typeIcon(x), size: 14, color: c.text3),
                  const SizedBox(width: 6),
                  Text(formatListTime(x.updatedAt), style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  const Spacer(),
                  if (x.pinned) Icon(LucideIcons.pin300, size: 14, color: c.accent),
                ]),
                const SizedBox(height: 10),
                _content(x, items),
                const SizedBox(height: 6),
                Row(children: [
                  if (x.isText) _MiniButton(LucideIcons.copy300, '复制', () => _copy(x)) else _MiniButton(LucideIcons.share2300, '分享', () => _share(x)),
                  _MiniButton(LucideIcons.star300, '收藏', () => _favorite(x)),
                  const Spacer(),
                  PdIconButton(icon: LucideIcons.ellipsis300, tooltip: '更多', size: 18, onTap: () => _more(x)),
                ]),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/* ======================= 收藏夹 ======================= */

/**
 * FavoritesPage：收藏夹
 *
 * 聊天里长按消息选「收藏」存到这里，也可以手动写一条。
 */
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> with _LibraryState<FavoritesPage> {
  final _search = TextEditingController();

  @override
  String get kind => LibraryKind.favorites;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /** _add：手动写一条收藏 */
  Future<void> _add() async {
    final r = await Navigator.of(context).push<({String title, String body})>(MaterialPageRoute(builder: (_) => const _NoteEditor(title: '新建收藏', bodyHint: '内容')));
    if (r == null || !mounted) return;
    await run(() => lib!.addText(kind, title: r.title, body: r.body), done: '已收藏');
  }

  /** _more：更多操作 */
  Future<void> _more(LibraryItem x) async {
    final i = await actionSheet(context, [
      SheetAction(x.pinned ? '取消置顶' : '置顶', icon: LucideIcons.pin300),
      if (!x.hasBlob) const SheetAction('复制', icon: LucideIcons.copy300),
      const SheetAction('重命名', icon: LucideIcons.pencil300),
      const SheetAction('取消收藏', icon: LucideIcons.trash2300, danger: true),
    ]);
    if (i == null || !mounted) return;
    final labels = [x.pinned ? '取消置顶' : '置顶', if (!x.hasBlob) '复制', '重命名', '取消收藏'];
    switch (labels[i]) {
      case '置顶' || '取消置顶':
        await run(() => lib!.update(x, pinned: !x.pinned));
      case '复制':
        await Clipboard.setData(ClipboardData(text: x.body));
        if (mounted) toast(context, '已复制');
      case '重命名':
        final t = await inputDialog(context, title: '重命名', initial: x.title, hint: '标题');
        if (t != null && mounted) await run(() => lib!.update(x, title: t.trim()));
      case '取消收藏':
        if (await confirm(context, title: '取消收藏', message: '电脑端的收藏夹也会同时删除。', ok: '取消收藏', danger: true) && mounted) await run(() => lib!.remove(x));
    }
  }

  /** _open：查看一条收藏 */
  Future<void> _open(LibraryItem x) async {
    if (x.isImage && x.hasBlob) {
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ImageGalleryPage(count: 1, index: 0, titleOf: (_) => x.name.isEmpty ? '图片' : x.name, loader: (_) async => MemoryImage(await lib!.blob(x.id))),
      ));
    } else if (x.hasBlob) {
      final temp = context.read<AppState>().paths.temp.path;
      await run(() async {
        final bytes = await lib!.blob(x.id);
        final dir = Directory('$temp${Platform.pathSeparator}library');
        await dir.create(recursive: true);
        final f = File('${dir.path}${Platform.pathSeparator}${naming.sanitize(x.name.isEmpty ? x.id : x.name)}');
        await f.writeAsBytes(bytes);
        await shareFile(f.path, title: x.name);
      });
    } else {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TextDetailPage(title: x.title, text: x.body)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final store = lib;
    if (store == null) return Scaffold(appBar: const PdBar(title: '收藏夹'), body: _unpaired('配对电脑后可以使用收藏夹'));
    return Scaffold(
      appBar: PdBar(title: '收藏夹', actions: [PdIconButton(icon: LucideIcons.plus300, tooltip: '新建', onTap: _add)]),
      body: ListenableBuilder(
        listenable: Listenable.merge([store, _search]),
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          final items = [for (final x in store.items(kind)) if (q.isEmpty || x.title.toLowerCase().contains(q) || x.body.toLowerCase().contains(q) || x.name.toLowerCase().contains(q)) x];
          return _LibraryList(
            store: store,
            kind: kind,
            items: items,
            empty: q.isEmpty ? '还没有收藏\n在聊天里长按一条消息，选「收藏」' : '没有找到相关收藏',
            header: Padding(padding: const EdgeInsets.only(bottom: 12), child: SearchField(controller: _search, hint: '搜索收藏')),
            itemBuilder: (context, x) => _Card(
              onTap: () => _open(x),
              onLongPress: () => _more(x),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: PdTint.favorites.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(context.style.smallRadius)),
                  child: Icon(_typeIcon(x), size: 19, color: PdTint.favorites),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      x.title.isNotEmpty ? x.title : (x.hasBlob ? (x.name.isEmpty ? '文件' : x.name) : x.body.trim().split('\n').first),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: PdFont.item, color: c.text, fontWeight: FontWeight.w500),
                    ),
                    if (!x.hasBlob && (x.title.isNotEmpty || x.body.trim().contains('\n')))
                      Padding(padding: const EdgeInsets.only(top: 4), child: Text(x.body.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.text2, height: 1.5))),
                    const SizedBox(height: 6),
                    Text([formatListTime(x.updatedAt), if (x.meta.isNotEmpty) x.meta, if (x.hasBlob) formatSize(x.size)].join(' · '), style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                  ]),
                ),
                if (x.pinned) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(LucideIcons.pin300, size: 14, color: c.accent)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/* ======================= 提示词 ======================= */

/**
 * PromptsPage：提示词
 *
 * 平时用来管理；从聊天里打开（pick 为真）时点一条就把内容带回输入框。
 */
class PromptsPage extends StatefulWidget {
  const PromptsPage({super.key, this.pick = false});

  final bool pick;

  @override
  State<PromptsPage> createState() => _PromptsPageState();
}

class _PromptsPageState extends State<PromptsPage> with _LibraryState<PromptsPage> {
  final _search = TextEditingController();

  @override
  String get kind => LibraryKind.prompts;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /** _edit：新建或编辑一条提示词，标题放在 title，分类放在 meta */
  Future<void> _edit([LibraryItem? x]) async {
    final r = await Navigator.of(context).push<({String title, String body, String meta})>(
      MaterialPageRoute(builder: (_) => _NoteEditor(title: x == null ? '新建提示词' : '编辑提示词', initialTitle: x?.title ?? '', initialBody: x?.body ?? '', bodyHint: '提示词内容', withCategory: true, initialCategory: x?.meta ?? '')),
    );
    if (r == null || !mounted) return;
    if (x == null) {
      await run(() => lib!.addText(kind, title: r.title, body: r.body, meta: r.meta), done: '已保存');
    } else {
      await run(() => lib!.update(x, title: r.title, body: r.body, meta: r.meta), done: '已保存');
    }
  }

  /** _more：更多操作 */
  Future<void> _more(LibraryItem x) async {
    final i = await actionSheet(context, [
      SheetAction(x.pinned ? '取消置顶' : '置顶', icon: LucideIcons.pin300),
      const SheetAction('复制', icon: LucideIcons.copy300),
      const SheetAction('编辑', icon: LucideIcons.pencil300),
      const SheetAction('删除', icon: LucideIcons.trash2300, danger: true),
    ]);
    if (i == null || !mounted) return;
    switch (i) {
      case 0:
        await run(() => lib!.update(x, pinned: !x.pinned));
      case 1:
        await Clipboard.setData(ClipboardData(text: x.body));
        if (mounted) toast(context, '已复制');
      case 2:
        await _edit(x);
      case 3:
        if (await confirm(context, title: '删除这条提示词', message: '电脑端的提示词也会同时删除。', ok: '删除', danger: true) && mounted) await run(() => lib!.remove(x));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final store = lib;
    final title = widget.pick ? '选择提示词' : '提示词';
    if (store == null) return Scaffold(appBar: PdBar(title: title), body: _unpaired('配对电脑后可以使用提示词'));
    return Scaffold(
      appBar: PdBar(title: title, actions: [PdIconButton(icon: LucideIcons.plus300, tooltip: '新建', onTap: () => _edit())]),
      body: ListenableBuilder(
        listenable: Listenable.merge([store, _search]),
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          final items = [for (final x in store.items(kind)) if (q.isEmpty || x.title.toLowerCase().contains(q) || x.body.toLowerCase().contains(q) || x.meta.toLowerCase().contains(q)) x];
          return _LibraryList(
            store: store,
            kind: kind,
            items: items,
            empty: q.isEmpty ? '还没有提示词\n点右上角「+」写一条，聊天时一点就能用' : '没有找到相关提示词',
            header: Padding(padding: const EdgeInsets.only(bottom: 12), child: SearchField(controller: _search, hint: '搜索提示词')),
            itemBuilder: (context, x) => _Card(
              onTap: () => widget.pick ? Navigator.of(context).pop(x.body) : _edit(x),
              onLongPress: () => _more(x),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(x.title.isEmpty ? x.body.trim().split('\n').first : x.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text, fontWeight: FontWeight.w600))),
                  if (x.meta.isNotEmpty) Tag(x.meta, color: c.accentSoft, textColor: c.accent),
                  if (x.pinned) Padding(padding: const EdgeInsets.only(left: 6), child: Icon(LucideIcons.pin300, size: 14, color: c.accent)),
                ]),
                const SizedBox(height: 6),
                Text(x.body.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.text2, height: 1.5)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/** _NoteEditor：编辑标题、内容（提示词还有分类），点保存返回 */
class _NoteEditor extends StatefulWidget {
  const _NoteEditor({required this.title, this.initialTitle = '', this.initialBody = '', this.bodyHint = '', this.withCategory = false, this.initialCategory = ''});

  final String title;
  final String initialTitle;
  final String initialBody;
  final String bodyHint;
  final bool withCategory;
  final String initialCategory;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final _t = TextEditingController(text: widget.initialTitle);
  late final _b = TextEditingController(text: widget.initialBody);
  late final _m = TextEditingController(text: widget.initialCategory);

  @override
  void dispose() {
    _t.dispose();
    _b.dispose();
    _m.dispose();
    super.dispose();
  }

  void _save() {
    if (_b.text.trim().isEmpty && _t.text.trim().isEmpty) {
      toast(context, '内容不能为空');
      return;
    }
    Navigator.of(context).pop((title: _t.text.trim(), body: _b.text, meta: _m.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    InputDecoration deco(String hint) => InputDecoration(hintText: hint, fillColor: c.card);
    return Scaffold(
      appBar: PdBar(title: widget.title, actions: [PdIconButton(icon: LucideIcons.check300, tooltip: '保存', onTap: _save)]),
      body: ListView(padding: const EdgeInsets.all(PdSize.gutter), children: [
        TextField(controller: _t, decoration: deco('标题（可不填）')),
        if (widget.withCategory) ...[const SizedBox(height: 12), TextField(controller: _m, decoration: deco('分类（可不填，如 写作、代码）'))],
        const SizedBox(height: 12),
        TextField(controller: _b, minLines: 10, maxLines: 24, decoration: deco(widget.bodyHint)),
      ]),
    );
  }
}

/** showPromptPicker：从提示词库里选一条，返回内容，没选返回空 */
Future<String?> showPromptPicker(BuildContext context) => Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const PromptsPage(pick: true)));

/** favoriteText：把一段文字收藏起来（聊天里长按消息使用），失败时提示 */
Future<void> favoriteText(BuildContext context, {required String text, String source = ''}) async {
  final scope = context.read<AppState>().scope;
  if (scope == null) return;
  try {
    final t = text.trim();
    await scope.library.addText(LibraryKind.favorites, title: '', body: t, meta: source);
    if (context.mounted) toast(context, '已收藏');
  } on ApiException catch (e) {
    if (context.mounted) toast(context, e.offline ? '电脑不在线，稍后再试' : e.message);
  }
}
