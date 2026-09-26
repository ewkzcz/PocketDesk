/**
 * 断点上传客户端：tus 协议的创建、查询偏移、分块上传（带 SHA-256 校验头）、拼接与终止。
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/** TusError：上传错误，status 为 0 表示网络问题 */
class TusError implements Exception {
  TusError(this.status, this.message, {this.offset});

  final int status;
  final String message;
  final int? offset;

  /** 上传不存在或已过期，需要重新创建 */
  bool get gone => status == 404 || status == 410;

  /** 校验失败 */
  bool get checksum => status == 460;

  /** 偏移不一致，需要先查询 */
  bool get conflict => status == 409;

  /** 电脑端暂停了传输 */
  bool get paused => status == 503;

  @override
  String toString() => message;
}

/** PatchResult：一次上传块的结果 */
class PatchResult {
  const PatchResult(this.offset, {this.name = '', this.path = ''});

  final int offset;
  final String name;
  final String path;
}

/**
 * TusClient：面向一台电脑的上传客户端
 */
class TusClient {
  TusClient({required this.base, required this.token, required this.client});

  final Uri base;
  final String token;
  final HttpClient client;

  static const _version = '1.0.0';

  /** _open：打开请求并加上公共头 */
  Future<HttpClientRequest> _open(String method, Uri uri) async {
    final req = await client.openUrl(method, uri);
    req.headers.set('Tus-Resumable', _version);
    req.headers.set('Authorization', 'Bearer $token');
    req.persistentConnection = true;
    return req;
  }

  /** _url：相对 Location 转为绝对地址 */
  Uri _url(String location) => base.resolve(location);

  /** _meta：Upload-Metadata 头 */
  static String encodeMeta(Map<String, String> meta) =>
      meta.entries.where((e) => e.value.isNotEmpty).map((e) => '${e.key} ${base64.encode(utf8.encode(e.value))}').join(',');

  /** _fail：把非预期响应转为错误 */
  static Future<TusError> _fail(HttpClientResponse res) async {
    final body = await utf8.decodeStream(res).catchError((_) => '');
    var msg = '上传失败（${res.statusCode}）';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['message'] is String) msg = j['message'] as String;
    } on FormatException {
      // 非 JSON 错误体
    }
    final off = int.tryParse(res.headers.value('upload-offset') ?? '');
    return TusError(res.statusCode, msg, offset: off);
  }

  /** _guard：网络异常统一转为 status 0 */
  static Future<T> _guard<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on TusError {
      rethrow;
    } on SocketException catch (e) {
      throw TusError(0, '网络中断：${e.message}');
    } on HttpException catch (e) {
      throw TusError(0, '网络中断：${e.message}');
    } on TimeoutException {
      throw TusError(0, '连接超时');
    } on HandshakeException {
      throw TusError(0, '电脑证书与配对时不一致');
    }
  }

  /**
   * create：创建上传，partial 为分段上传，返回上传地址
   */
  Future<Uri> create(int length, Map<String, String> meta, {bool partial = false}) => _guard(() async {
        final req = await _open('POST', base.resolve('/files/'));
        req.headers.set('Upload-Length', '$length');
        req.headers.set('Upload-Metadata', encodeMeta(meta));
        if (partial) req.headers.set('Upload-Concat', 'partial');
        req.contentLength = 0;
        final res = await req.close().timeout(const Duration(seconds: 30));
        if (res.statusCode != 201) throw await _fail(res);
        await res.drain<void>();
        return _url(res.headers.value('location') ?? '');
      });

  /** offset：查询已收偏移，完成时一并返回文件名 */
  Future<PatchResult> offset(Uri url) => _guard(() async {
        final req = await _open('HEAD', url);
        final res = await req.close().timeout(const Duration(seconds: 30));
        await res.drain<void>();
        if (res.statusCode != 200) throw TusError(res.statusCode, '上传不存在或已过期');
        return PatchResult(int.tryParse(res.headers.value('upload-offset') ?? '') ?? 0, name: Uri.decodeComponent(res.headers.value('x-pd-name') ?? ''));
      });

  /**
   * patch：从 offset 开始上传一块数据
   *
   * 处理流程：
   * 1、计算块的 SHA-256 放入 Upload-Checksum
   * 2、分成 64KB 小片写出，逐片回调进度
   * 3、204 返回新偏移；写满时附带最终文件名与路径
   */
  Future<PatchResult> patch(Uri url, int offset, List<int> chunk, {void Function(int sent)? onProgress}) => _guard(() async {
        // 1、校验
        final sum = base64.encode(sha256.convert(chunk).bytes);
        final req = await _open('PATCH', url);
        req.headers.set('Content-Type', 'application/offset+octet-stream');
        req.headers.set('Upload-Offset', '$offset');
        req.headers.set('Upload-Checksum', 'sha256 $sum');
        req.contentLength = chunk.length;
        // 2、分片写出
        const piece = 64 * 1024;
        for (var i = 0; i < chunk.length; i += piece) {
          final end = i + piece > chunk.length ? chunk.length : i + piece;
          req.add(chunk.sublist(i, end));
          await req.flush();
          onProgress?.call(end);
        }
        // 3、结果
        final res = await req.close().timeout(const Duration(minutes: 2));
        if (res.statusCode != 204) throw await _fail(res);
        await res.drain<void>();
        return PatchResult(
          int.tryParse(res.headers.value('upload-offset') ?? '') ?? offset + chunk.length,
          name: Uri.decodeComponent(res.headers.value('x-pd-name') ?? ''),
          path: Uri.decodeComponent(res.headers.value('x-pd-path') ?? ''),
        );
      });

  /** concat：把已完成的分段拼接成完整文件，返回最终文件名 */
  Future<PatchResult> concat(List<Uri> parts, Map<String, String> meta) => _guard(() async {
        final req = await _open('POST', base.resolve('/files/'));
        req.headers.set('Upload-Concat', 'final;${parts.map((u) => u.path).join(' ')}');
        req.headers.set('Upload-Metadata', encodeMeta(meta));
        req.contentLength = 0;
        final res = await req.close().timeout(const Duration(minutes: 5));
        if (res.statusCode != 201) throw await _fail(res);
        await res.drain<void>();
        return PatchResult(0, name: Uri.decodeComponent(res.headers.value('x-pd-name') ?? ''), path: Uri.decodeComponent(res.headers.value('x-pd-path') ?? ''));
      });

  /** terminate：终止上传（取消任务时） */
  Future<void> terminate(Uri url) => _guard(() async {
        final req = await _open('DELETE', url);
        final res = await req.close().timeout(const Duration(seconds: 30));
        await res.drain<void>();
      });
}
