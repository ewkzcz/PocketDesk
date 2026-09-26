/**
 * 查看用下载：把电脑上的文件下载到手机缓存（带进度），返回本地文件与 ETag。
 */
library;

import 'dart:async';
import 'dart:io';

import '../../core/app_state.dart';
import '../../net/api.dart';

/** Fetched：下载结果 */
typedef Fetched = ({File file, String etag});

/**
 * fetchToFile：下载到指定文件
 *
 * 处理流程：
 * 1、带令牌请求，非 200 转为 ApiException
 * 2、先写临时文件，完成后改名，避免留下半个文件
 */
Future<Fetched> fetchToFile(HostScope scope, Uri url, File dest, {void Function(int got, int total)? onProgress}) async {
  final api = scope.conn.api;
  final client = scope.conn.httpClient();
  try {
    // 1、请求
    final HttpClientResponse res;
    try {
      final req = await client.getUrl(url).timeout(const Duration(seconds: 15));
      api.headers().forEach(req.headers.set);
      res = await req.close().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw ApiException(0, 'timeout', '连接电脑超时');
    } on SocketException {
      throw ApiException(0, 'offline', '无法连接电脑');
    } on HandshakeException {
      throw ApiException(0, 'cert', '电脑证书与配对时不一致');
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw ApiException(res.statusCode, 'http_${res.statusCode}', res.statusCode == 404 ? '文件不存在' : '下载失败（${res.statusCode}）');
    }
    // 2、写入
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    var got = 0;
    final total = res.contentLength;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      await sink.close();
    } catch (e) {
      await sink.close();
      if (await tmp.exists()) await tmp.delete();
      throw ApiException(0, 'offline', '下载中断，请重试');
    }
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
    return (file: dest, etag: res.headers.value('etag') ?? '');
  } finally {
    client.close();
  }
}

/** cacheFileFor：工作区文件在手机缓存中的位置 */
File cacheFileFor(AppState app, String wsId, String relPath, {String sub = 'view'}) {
  final safe = relPath.split('/').where((p) => p.isNotEmpty && p != '..' && p != '.').join(Platform.pathSeparator);
  return File('${app.paths.temp.path}${Platform.pathSeparator}$sub${Platform.pathSeparator}$wsId${Platform.pathSeparator}$safe');
}
