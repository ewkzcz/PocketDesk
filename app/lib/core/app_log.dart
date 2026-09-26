/**
 * 手机端日志：按天写入文件、保留 7 天，写入前去掉令牌等敏感信息，可一键导出给开发者排查。
 */
library;

import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';

/** sanitizeLog：去掉令牌、配对码与本机路径中的用户名 */
String sanitizeLog(String s) => s
    .replaceAllMapped(RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]+', caseSensitive: false), (m) => '${m[1]}***')
    .replaceAllMapped(RegExp(r'("?(?:token|code|password)"?\s*[:=]\s*"?)[^",\s}]+', caseSensitive: false), (m) => '${m[1]}***')
    .replaceAllMapped(RegExp(r'(/(?:Users|home)/)[^/\s]+'), (m) => '${m[1]}~');

/**
 * AppLog：日志写入器
 */
class AppLog {
  AppLog(this.dir, {DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final Directory dir;
  final DateTime Function() _now;
  static final _day = DateFormat('yyyyMMdd');
  static final _time = DateFormat('HH:mm:ss.SSS');
  Future<void> _chain = Future.value();

  /** 全局实例，未初始化时只丢弃 */
  static AppLog? instance;

  /** i / w / e：记录信息、警告、错误 */
  static void i(String tag, String msg) => instance?.write('I', tag, msg);
  static void w(String tag, String msg) => instance?.write('W', tag, msg);
  static void e(String tag, Object err, [StackTrace? st]) => instance?.write('E', tag, st == null ? '$err' : '$err\n$st');

  /** _file：某天的日志文件 */
  File _file(DateTime d) => File('${dir.path}${Platform.pathSeparator}app-${_day.format(d)}.log');

  /** write：顺序追加一行 */
  Future<void> write(String level, String tag, String msg) {
    final now = _now();
    final line = '${_time.format(now)} $level [$tag] ${sanitizeLog(msg)}\n';
    return _chain = _chain.then((_) async {
      try {
        await dir.create(recursive: true);
        await _file(now).writeAsString(line, mode: FileMode.append, flush: false);
      } catch (_) {
        // 存储不可用时不影响使用
      }
    });
  }

  /** prune：删除 7 天前的日志 */
  Future<void> prune() async {
    if (!await dir.exists()) return;
    final keep = {for (var i = 0; i < 7; i++) 'app-${_day.format(_now().subtract(Duration(days: i)))}.log'};
    await for (final f in dir.list()) {
      final name = f.uri.pathSegments.last;
      if (f is File && name.startsWith('app-') && !keep.contains(name)) await f.delete();
    }
  }

  /**
   * export：把最近的日志合并为一个文件，返回路径
   */
  Future<File> export(Directory out, {String header = ''}) async {
    await _chain;
    final files = (await dir.exists()) ? (await dir.list().where((f) => f is File && f.uri.pathSegments.last.startsWith('app-')).cast<File>().toList()) : <File>[];
    files.sort((a, b) => a.path.compareTo(b.path));
    final dest = File('${out.path}${Platform.pathSeparator}pocketdesk-phone-${_day.format(_now())}.log');
    final sink = dest.openWrite();
    if (header.isNotEmpty) sink.writeln(sanitizeLog(header));
    for (final f in files) {
      sink.writeln('===== ${f.uri.pathSegments.last} =====');
      sink.write(await f.readAsString());
    }
    await sink.close();
    return dest;
  }
}
