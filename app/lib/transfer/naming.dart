/**
 * 手机端命名规则（与电脑端一致）：日期文件夹、无名数据按时间戳命名、非法字符替换、重名加序号。
 */
library;

import 'dart:io';

/** dateFolder：YYYYMMDD */
String dateFolder(DateTime t) => '${t.year.toString().padLeft(4, '0')}${_two(t.month)}${_two(t.day)}';

String _two(int n) => n.toString().padLeft(2, '0');

/** _mimeExt：常见 MIME 的扩展名 */
const _mimeExt = {
  'text/plain': '.txt',
  'text/markdown': '.md',
  'text/html': '.html',
  'text/csv': '.csv',
  'image/jpeg': '.jpg',
  'image/png': '.png',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/heic': '.heic',
  'video/mp4': '.mp4',
  'video/quicktime': '.mov',
  'audio/mpeg': '.mp3',
  'audio/mp4': '.m4a',
  'application/pdf': '.pdf',
  'application/zip': '.zip',
  'application/json': '.json',
};

/** extForMime：根据 MIME 推断扩展名，文本兜底 .txt，其他兜底 .bin */
String extForMime(String mime) {
  final base = mime.split(';').first.trim().toLowerCase();
  final e = _mimeExt[base];
  if (e != null) return e;
  if (base.startsWith('text/')) return '.txt';
  return '.bin';
}

/** mimeForName：按扩展名推断 MIME */
String mimeForName(String name) {
  final ext = name.contains('.') ? '.${name.split('.').last.toLowerCase()}' : '';
  if (ext == '.jpeg') return 'image/jpeg';
  for (final e in _mimeExt.entries) {
    if (e.value == ext) return e.key;
  }
  return 'application/octet-stream';
}

/** timestampName：20261001-093015-042.txt */
String timestampName(DateTime t, String mime) =>
    '${dateFolder(t)}-${_two(t.hour)}${_two(t.minute)}${_two(t.second)}-${t.millisecond.toString().padLeft(3, '0')}${extForMime(mime)}';

/** Windows 保留设备名 */
const _reserved = {'CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'};

/**
 * sanitize：处理成各系统都能保存的文件名
 *
 * 处理流程：
 * 1、去掉路径部分
 * 2、非法字符与控制字符替换为 _
 * 3、去掉结尾的点和空格，空名改为 _
 * 4、保留设备名追加 _
 */
String sanitize(String name) {
  // 1、路径
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  if (slash >= 0) name = name.substring(slash + 1);
  // 2、非法字符
  final b = StringBuffer();
  for (final r in name.runes) {
    if (r < 0x20 || r == 0x7f || r'\/:*?"<>|'.runes.contains(r)) {
      b.write('_');
    } else {
      b.writeCharCode(r);
    }
  }
  // 3、结尾与空名
  var s = b.toString().replaceAll(RegExp(r'[.\s]+$'), '').replaceAll(RegExp(r'^\s+'), '');
  if (s.isEmpty) return '_';
  // 4、保留名
  final (stem, ext) = splitExt(s);
  if (_reserved.contains(stem.toUpperCase())) s = '${stem}_$ext';
  return s;
}

/** splitExt：拆出主名和扩展名，以点开头且无其他点的视为无扩展名 */
(String, String) splitExt(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0) return (name, '');
  return (name.substring(0, i), name.substring(i));
}

/** candidate：第 i 个候选名：name.ext、name-1.ext、name-2.ext */
String candidate(String name, int i) {
  if (i == 0) return name;
  final (stem, ext) = splitExt(name);
  return '$stem-$i$ext';
}

/**
 * placeFile：把临时文件以「不存在才创建」的方式移动到目录，重名（不区分大小写）加序号，返回最终文件
 */
Future<File> placeFile(File tmp, Directory dir, String name) async {
  await dir.create(recursive: true);
  final taken = <String>{
    await for (final e in dir.list()) e.uri.pathSegments.where((s) => s.isNotEmpty).last.toLowerCase(),
  };
  final clean = sanitize(name);
  for (var i = 0; i < 100000; i++) {
    final cand = candidate(clean, i);
    if (taken.contains(cand.toLowerCase())) continue;
    final dst = File('${dir.path}${Platform.pathSeparator}$cand');
    // 以独占方式创建占位文件锁定名字，已存在则尝试下一个候选名
    try {
      await dst.create(exclusive: true);
    } on FileSystemException {
      continue;
    }
    try {
      return await tmp.rename(dst.path);
    } on FileSystemException {
      // 跨分区时改名失败，退回复制
      await tmp.copy(dst.path);
      await tmp.delete();
      return dst;
    }
  }
  throw const FileSystemException('重名文件过多');
}
