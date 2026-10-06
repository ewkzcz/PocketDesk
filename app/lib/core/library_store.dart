/**
 * 资料库仓库：收藏、剪切板、提示词三类资料的缓存与读写，电脑端有变化时收到通知后刷新。
 */
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../net/api.dart';
import 'safe_notifier.dart';

/** 资料类型 */
abstract final class LibraryKind {
  static const favorites = 'fav';
  static const clips = 'clip';
  static const prompts = 'prompt';
  static const presets = 'preset';
}

/** LibraryStore：一台电脑的资料库 */
class LibraryStore extends ChangeNotifier with SafeNotifier {
  LibraryStore({required this.api});

  /** 取当前接口客户端（连接切换地址后会变化） */
  final PdApi Function() api;

  final Map<String, List<LibraryItem>> _items = {};
  final Set<String> _loading = {};
  final Set<String> _loaded = {};

  /** error：最近一次读取失败的提示，成功后清空 */
  String error = '';

  /** items：某一类资料（置顶优先，再按更新时间倒序） */
  List<LibraryItem> items(String kind) => _items[kind] ?? const [];

  /** loading：某一类是否正在读取 */
  bool loading(String kind) => _loading.contains(kind);

  /** loaded：某一类是否已读取过 */
  bool loaded(String kind) => _loaded.contains(kind);

  final Map<String, Future<Uint8List>> _blobs = {};

  /** blob：图片或文件内容（同一条只下载一次，失败后下次重新下载） */
  Future<Uint8List> blob(String id) => _blobs[id] ??= api().libraryBlob(id).then(Uint8List.fromList).catchError((Object e) {
        _blobs.removeWhere((k, _) => k == id);
        throw e;
      });

  /** refresh：从电脑读取某一类资料 */
  Future<void> refresh(String kind) async {
    if (kind.isEmpty || !_loading.add(kind)) return;
    try {
      _items[kind] = await api().library(kind);
      _loaded.add(kind);
      error = '';
    } on ApiException catch (e) {
      error = e.offline ? '电脑不在线' : e.message;
    } finally {
      _loading.remove(kind);
      notifyListeners();
    }
  }

  /** addText：新增文字资料 */
  Future<LibraryItem> addText(String kind, {String title = '', String body = '', String meta = '', String mime = 'text/plain'}) async {
    final x = await api().addLibrary(kind, title: title, body: body, meta: meta, mime: mime);
    _put(x);
    return x;
  }

  /** addBlob：新增图片或文件资料 */
  Future<LibraryItem> addBlob(String kind, List<int> bytes, {required String mime, String name = '', String title = '', String meta = ''}) async {
    final x = await api().addLibraryBlob(kind, bytes, mime: mime, name: name, title: title, meta: meta);
    _put(x);
    return x;
  }

  /** update：修改标题、正文、说明或置顶 */
  Future<void> update(LibraryItem x, {String? title, String? body, String? meta, bool? pinned}) async {
    _put(await api().patchLibrary(x.id, title: title, body: body, meta: meta, pinned: pinned));
  }

  /** remove：删除一条 */
  Future<void> remove(LibraryItem x) async {
    await api().deleteLibrary(x.id);
    _items[x.kind] = [for (final i in items(x.kind)) if (i.id != x.id) i];
    _blobs.removeWhere((k, _) => k == x.id);
    notifyListeners();
  }

  /** clear：清空某一类里未置顶的资料 */
  Future<void> clear(String kind) async {
    await api().clearLibrary(kind);
    _items[kind] = [for (final i in items(kind)) if (i.pinned) i];
    notifyListeners();
  }

  /** _put：把新增或修改后的一条放进缓存并排好顺序 */
  void _put(LibraryItem x) {
    final list = [x, for (final i in items(x.kind)) if (i.id != x.id) i];
    list.sort((a, b) => a.pinned != b.pinned ? (a.pinned ? -1 : 1) : b.updatedAt.compareTo(a.updatedAt));
    _items[x.kind] = list;
    notifyListeners();
  }
}
