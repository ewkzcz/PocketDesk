/**
 * 手机工作空间：电脑桌面端通过实时连接管理手机上的一个文件夹（默认「手机存储/PocketDesk」），电脑发来的文件也存到这里的日期文件夹。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../transfer/naming.dart' as naming;
import 'connection.dart';
import 'settings.dart';
import 'transfer_manager.dart';

/** DeviceBridge：手机系统能力（存储授权、通知、剪贴板图片） */
class DeviceBridge {
  const DeviceBridge([this._ch = const MethodChannel('pocketdesk/device')]);

  final MethodChannel _ch;

  /** storageRoot：手机存储根目录，非安卓为空 */
  Future<String> storageRoot() async => Platform.isAndroid ? (await _ch.invokeMethod<String>('storageRoot') ?? '') : '';

  /** hasAllFiles：是否已授权读写手机上的文件夹 */
  Future<bool> hasAllFiles() async => !Platform.isAndroid || (await _ch.invokeMethod<bool>('hasAllFiles') ?? false);

  /** requestAllFiles：打开系统授权页 */
  Future<void> requestAllFiles() async {
    if (Platform.isAndroid) await _ch.invokeMethod<void>('requestAllFiles');
  }

  /** notify：显示通知，count 计入桌面图标角标 */
  Future<void> notify(int id, String title, String body, int count) async {
    if (Platform.isAndroid) await _ch.invokeMethod<void>('notify', {'id': id, 'title': title, 'body': body, 'count': count});
  }

  /** cancelNotify：清除通知，id 为空时清除全部 */
  Future<void> cancelNotify([int? id]) async {
    if (Platform.isAndroid) await _ch.invokeMethod<void>('cancelNotify', {'id': id});
  }

  /** openTailscaleStore：在浏览器打开 Tailscale 安卓版的 GitHub 页面 */
  Future<void> openTailscaleStore() async {
    if (Platform.isAndroid) await _ch.invokeMethod<void>('openTailscale');
  }

  /** clipboardImage：剪贴板里的图片存到缓存后的路径，没有图片时为空 */
  Future<String?> clipboardImage() async => Platform.isAndroid ? _ch.invokeMethod<String>('clipboardImage') : null;
}

/** PhoneFsError：返回给电脑的错误说明 */
class PhoneFsError implements Exception {
  PhoneFsError(this.message);

  final String message;

  @override
  String toString() => message;
}

/**
 * PhoneSpace：手机工作空间
 */
class PhoneSpace extends ChangeNotifier {
  PhoneSpace({required this.settings, required this.fallbackRoot, this.device = const DeviceBridge()});

  final AppSettings settings;
  final DeviceBridge device;

  /** 非安卓或拿不到手机存储时的默认目录 */
  final Directory fallbackRoot;

  String _storage = '';
  bool _permitted = false;

  /** storage：手机存储根目录 */
  String get storage => _storage;

  /** permitted：已授权读写 */
  bool get permitted => _permitted;

  /** defaultRoot：默认工作空间目录 */
  String get defaultRoot => _storage.isNotEmpty ? '$_storage/PocketDesk' : fallbackRoot.path;

  /** root：当前工作空间目录 */
  String get root => settings.phoneRoot ?? defaultRoot;

  /** refresh：读取存储位置与授权状态（从系统授权页回来时调用） */
  Future<void> refresh() async {
    try {
      _storage = await device.storageRoot();
      _permitted = await device.hasAllFiles();
    } on MissingPluginException {
      _permitted = !Platform.isAndroid;
    } on PlatformException {
      _permitted = false;
    }
    notifyListeners();
  }

  /** setRoot：更换工作空间目录，只能在手机存储内 */
  Future<String> setRoot(String abs) async {
    final p = _clean(abs);
    if (_storage.isNotEmpty && p != _storage && !p.startsWith('$_storage/')) throw PhoneFsError('只能选择手机存储里的文件夹');
    await Directory(p).create(recursive: true);
    settings.phoneRoot = p == defaultRoot ? null : p;
    notifyListeners();
    return root;
  }

  /** _clean：规范化绝对路径 */
  static String _clean(String p) {
    final parts = <String>[];
    for (final s in p.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(s);
      }
    }
    return '/${parts.join('/')}';
  }

  /** _abs：工作空间内相对路径对应的完整路径，不允许跳出工作空间 */
  String _abs(String rel) {
    final parts = rel.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (parts.any((s) => s == '..')) throw PhoneFsError('路径不合法');
    return parts.isEmpty ? root : '$root/${parts.join('/')}';
  }

  /** _name：文件或文件夹名不能含路径分隔符 */
  static String _name(Object? v) {
    final n = (v as String? ?? '').trim();
    if (n.isEmpty || n == '.' || n == '..' || n.contains('/') || n.contains('\\')) throw PhoneFsError('名称不合法');
    return n;
  }

  /**
   * handle：处理电脑的请求，返回应答数据
   *
   * 处理流程：
   * 1、未授权时直接说明原因（查看信息与浏览目录除外）
   * 2、按操作读写工作空间；文件内容经 HTTPS 与电脑交换
   */
  Future<Object?> handle(String op, Map<String, dynamic> args, HostConnection conn) async {
    // 1、授权
    if (op != 'info') {
      await refresh();
      if (!_permitted) throw PhoneFsError('手机还没授权访问存储，请在手机上打开「我 → 手机工作空间」授权');
    }
    // 2、操作
    switch (op) {
      case 'info':
        await refresh();
        return {'root': root, 'defaultRoot': defaultRoot, 'storage': _storage, 'permitted': _permitted};
      case 'list':
        final dir = Directory(_abs(args['path'] as String? ?? ''));
        if (!await dir.exists()) {
          if ((args['path'] as String? ?? '').isEmpty) {
            await dir.create(recursive: true);
          } else {
            throw PhoneFsError('文件夹不存在');
          }
        }
        return {'root': root, 'entries': await _entries(dir)};
      case 'mkdir':
        final d = Directory('${_abs(args['path'] as String? ?? '')}/${_name(args['name'])}');
        if (await d.exists()) throw PhoneFsError('已有同名文件夹');
        await d.create(recursive: true);
        return {'ok': true};
      case 'delete':
        for (final p in (args['paths'] as List? ?? const []).cast<String>()) {
          if (p.split('/').where((s) => s.isNotEmpty).isEmpty) throw PhoneFsError('不能删除工作空间本身');
          final abs = _abs(p);
          final type = await FileSystemEntity.type(abs, followLinks: false);
          if (type == FileSystemEntityType.directory) {
            await Directory(abs).delete(recursive: true);
          } else if (type != FileSystemEntityType.notFound) {
            await File(abs).delete();
          }
        }
        return {'ok': true};
      case 'rename':
        final from = _abs(args['path'] as String? ?? '');
        if (from == root) throw PhoneFsError('不能重命名工作空间本身');
        final to = '${from.substring(0, from.lastIndexOf('/'))}/${_name(args['name'])}';
        if (await FileSystemEntity.type(to, followLinks: false) != FileSystemEntityType.notFound) throw PhoneFsError('已有同名文件或文件夹');
        await (await FileSystemEntity.isDirectory(from) ? Directory(from) : File(from)).rename(to);
        return {'ok': true};
      case 'browse':
        return _browse(args['path'] as String? ?? '');
      case 'setRoot':
        return {'root': await setRoot(args['path'] as String? ?? '')};
      case 'push':
        await _push(conn, args['id'] as String, File(_abs(args['path'] as String? ?? '')));
        return {'ok': true};
      case 'pull':
        final dir = Directory(_abs(args['dir'] as String? ?? ''));
        final name = _name(args['name']);
        return {'name': await _pull(conn, args['id'] as String, dir, name, overwrite: args['overwrite'] == true)};
    }
    throw PhoneFsError('不支持的操作');
  }

  /** _entries：目录内容，文件夹在前 */
  static Future<List<Map<String, Object>>> _entries(Directory dir) async {
    final out = <Map<String, Object>>[];
    await for (final e in dir.list(followLinks: false)) {
      final st = await e.stat();
      out.add({'name': e.path.substring(e.path.lastIndexOf('/') + 1), 'isDir': st.type == FileSystemEntityType.directory, 'size': st.size, 'modTime': st.modified.millisecondsSinceEpoch});
    }
    out.sort((a, b) => a['isDir'] != b['isDir'] ? (a['isDir'] == true ? -1 : 1) : (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    return out;
  }

  /** _browse：选择工作空间目录时浏览手机存储里的文件夹 */
  Future<Map<String, Object?>> _browse(String abs) async {
    final top = _storage.isNotEmpty ? _storage : fallbackRoot.path;
    var p = abs.isEmpty ? top : _clean(abs);
    if (p != top && !p.startsWith('$top/')) p = top;
    final dirs = <String>[];
    await for (final e in Directory(p).list(followLinks: false)) {
      final name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (e is Directory && !name.startsWith('.') && name != 'Android') dirs.add(name);
    }
    dirs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return {'path': p, 'parent': p == top ? null : p.substring(0, p.lastIndexOf('/')), 'dirs': dirs, 'root': root};
  }

  /** _push：把手机上的文件上传给电脑 */
  Future<void> _push(HostConnection conn, String id, File f) async {
    if (!await f.exists()) throw PhoneFsError('文件不存在');
    final client = conn.httpClient();
    try {
      final req = await client.openUrl('PUT', conn.api.uri('/api/phone/blob/$id'));
      conn.api.headers().forEach(req.headers.set);
      req.contentLength = await f.length();
      await req.addStream(f.openRead());
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode != 200) throw PhoneFsError('发送失败（${res.statusCode}）');
    } finally {
      client.close();
    }
  }

  /** _pull：取电脑发来的文件写入目录；覆盖时替换同名文件，否则重名加序号，返回最终文件名 */
  Future<String> _pull(HostConnection conn, String id, Directory dir, String name, {required bool overwrite}) async {
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/.pd-recv-$id');
    final client = conn.httpClient();
    try {
      final req = await client.getUrl(conn.api.uri('/api/phone/blob/$id'));
      conn.api.headers().forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw PhoneFsError('接收失败（${res.statusCode}）');
      }
      await res.pipe(tmp.openWrite());
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } finally {
      client.close();
    }
    if (overwrite) {
      await tmp.rename('${dir.path}/$name');
      return name;
    }
    final f = await naming.placeFile(tmp, dir, name);
    return f.path.substring(f.path.lastIndexOf('/') + 1);
  }
}

/** PhoneSpaceSaver：电脑发来的文件存到手机工作空间的日期文件夹，未授权时交给 [fallback] */
class PhoneSpaceSaver implements FileSaver {
  PhoneSpaceSaver(this.space, this.fallback);

  final PhoneSpace space;
  final FileSaver fallback;

  @override
  Future<String> save(File temp, String dateFolder, String name) async {
    await space.refresh();
    if (!space.permitted) return fallback.save(temp, dateFolder, name);
    return DirSaver(() async => Directory(space.root)).save(temp, dateFolder, name);
  }
}
