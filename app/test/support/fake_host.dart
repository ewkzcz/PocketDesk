/**
 * 测试用假电脑端：实现 tus 上传（含分段拼接与校验）与 Range 下载，可注入断网、校验失败、过期与文件变化等故障。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/** FakeUpload：服务端的一次上传 */
class FakeUpload {
  FakeUpload(this.length, this.meta, {this.partial = false});

  final int length;
  final Map<String, String> meta;
  final bool partial;
  final BytesBuilder data = BytesBuilder(copy: false);
  String resultName = '';

  int get offset => data.length;
}

/**
 * FakeHost：本地 HTTP 服务
 */
class FakeHost {
  late final HttpServer _server;
  final uploads = <String, FakeUpload>{};
  final files = <String, Uint8List>{};
  final completed = <String, Uint8List>{};
  var _seq = 0;

  /** 故障注入 */
  int dropPatchAfter = -1;
  int checksumFailures = 0;
  int goneOnHead = 0;
  int dropDownloadAfter = -1;
  String etagOverride = '';
  int patchCalls = 0;
  int maxConcurrentPatch = 0;
  int _concurrentPatch = 0;
  int rangeRequests = 0;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  /** start：启动服务 */
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  /** close：关闭服务 */
  Future<void> close() => _server.close(force: true);

  /** _meta：解析 Upload-Metadata */
  static Map<String, String> _meta(String? h) {
    final out = <String, String>{};
    if (h == null || h.isEmpty) return out;
    for (final pair in h.split(',')) {
      final kv = pair.trim().split(' ');
      out[kv[0]] = kv.length > 1 ? utf8.decode(base64.decode(kv[1])) : '';
    }
    return out;
  }

  /** _finish：落盘并生成结果名（重名加序号） */
  void _finish(FakeUpload u, HttpResponse res) {
    var name = u.meta['filename'] ?? 'noname.bin';
    var i = 1;
    final stem = name;
    while (completed.containsKey(name)) {
      final dot = stem.lastIndexOf('.');
      name = dot > 0 ? '${stem.substring(0, dot)}-$i${stem.substring(dot)}' : '$stem-$i';
      i++;
    }
    final bytes = u.data.toBytes();
    final want = u.meta['sha256'] ?? '';
    if (want.isNotEmpty && sha256.convert(bytes).toString() != want) {
      res.statusCode = 460;
      return;
    }
    completed[name] = bytes;
    u.resultName = name;
    res.headers.set('X-PD-Name', Uri.encodeComponent(name));
    res.headers.set('X-PD-Path', Uri.encodeComponent('${u.meta['date'] ?? ''}/$name'));
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    try {
      if (path.startsWith('/files/')) {
        await _tus(req, res, path.substring('/files/'.length));
      } else if (path.startsWith('/dl/')) {
        await _download(req, res, path.substring('/dl/'.length));
      } else {
        res.statusCode = 404;
      }
    } catch (_) {
      // 故障注入时连接可能已被主动断开
    }
    try {
      await res.close();
    } catch (_) {
      // 忽略
    }
  }

  /** _tus：tus 协议处理 */
  Future<void> _tus(HttpRequest req, HttpResponse res, String id) async {
    res.headers.set('Tus-Resumable', '1.0.0');
    switch (req.method) {
      case 'POST':
        final concat = req.headers.value('upload-concat') ?? '';
        final meta = _meta(req.headers.value('upload-metadata'));
        final nid = 'u${_seq++}';
        if (concat.startsWith('final;')) {
          final ids = concat.substring(6).split(' ').map((p) => p.split('/').last).toList();
          final u = FakeUpload(0, meta);
          for (final pid in ids) {
            u.data.add(uploads[pid]!.data.toBytes());
            uploads.remove(pid);
          }
          uploads[nid] = u;
          res.statusCode = 201;
          res.headers.set('Location', '/files/$nid');
          _finish(u, res);
          return;
        }
        final len = int.parse(req.headers.value('upload-length')!);
        uploads[nid] = FakeUpload(len, meta, partial: concat == 'partial');
        res.statusCode = 201;
        res.headers.set('Location', '/files/$nid');
        if (len == 0 && concat != 'partial') _finish(uploads[nid]!, res);
      case 'HEAD':
        if (goneOnHead > 0) {
          goneOnHead--;
          uploads.remove(id);
        }
        final u = uploads[id];
        if (u == null) {
          res.statusCode = 404;
          return;
        }
        res.headers.set('Upload-Offset', '${u.offset}');
        res.headers.set('Upload-Length', '${u.length}');
        if (u.resultName.isNotEmpty) res.headers.set('X-PD-Name', Uri.encodeComponent(u.resultName));
      case 'PATCH':
        patchCalls++;
        _concurrentPatch++;
        if (_concurrentPatch > maxConcurrentPatch) maxConcurrentPatch = _concurrentPatch;
        try {
          final u = uploads[id];
          if (u == null) {
            res.statusCode = 404;
            return;
          }
          final off = int.parse(req.headers.value('upload-offset')!);
          if (off != u.offset) {
            res.statusCode = 409;
            res.headers.set('Upload-Offset', '${u.offset}');
            return;
          }
          final body = BytesBuilder();
          await for (final part in req) {
            body.add(part);
            if (dropPatchAfter >= 0 && body.length >= dropPatchAfter) {
              // 与电脑端一致：带校验头的块中途断开时丢弃这一块
              dropPatchAfter = -1;
              await req.response.detachSocket(writeHeaders: false).then((s) => s.destroy());
              return;
            }
          }
          final bytes = body.toBytes();
          final sum = req.headers.value('upload-checksum')!.split(' ')[1];
          if (checksumFailures > 0 || base64.encode(sha256.convert(bytes).bytes) != sum) {
            checksumFailures = checksumFailures > 0 ? checksumFailures - 1 : 0;
            res.statusCode = 460;
            return;
          }
          u.data.add(bytes);
          res.statusCode = 204;
          res.headers.set('Upload-Offset', '${u.offset}');
          if (!u.partial && u.offset == u.length) _finish(u, res);
        } finally {
          _concurrentPatch--;
        }
      case 'DELETE':
        uploads.remove(id);
        res.statusCode = 204;
    }
  }

  /** _download：Range 下载，支持 If-Range */
  Future<void> _download(HttpRequest req, HttpResponse res, String name) async {
    final data = files[name];
    if (data == null) {
      res.statusCode = 404;
      return;
    }
    final etag = etagOverride.isNotEmpty ? etagOverride : '"${sha256.convert(data).toString().substring(0, 12)}"';
    res.headers.set('ETag', etag);
    final range = req.headers.value('range');
    final ifRange = req.headers.value('if-range');
    var start = 0;
    var end = data.length - 1;
    if (range != null && (ifRange == null || ifRange == etag)) {
      rangeRequests++;
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
      res.statusCode = 206;
      res.headers.set('Content-Range', 'bytes $start-$end/${data.length}');
    } else {
      res.statusCode = 200;
    }
    res.contentLength = end - start + 1;
    final slice = data.sublist(start, end + 1);
    if (dropDownloadAfter >= 0 && slice.length > dropDownloadAfter) {
      // 写出响应头与部分数据后直接断开连接
      final cut = dropDownloadAfter;
      dropDownloadAfter = -1;
      final sock = await res.detachSocket();
      sock.add(slice.sublist(0, cut));
      await sock.flush();
      sock.destroy();
      return;
    }
    res.add(slice);
  }
}

/** randomBytes：可重复的伪随机数据 */
Uint8List randomBytes(int n, [int seed = 7]) {
  final out = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16 & 0xff;
  }
  return out;
}
