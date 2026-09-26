/**
 * 展示格式：文件大小、列表时间（今天显示时分、昨天、星期、日期）、相对时间、剩余时间、速度。
 */
library;

/** formatSize：字节数转为 B / KB / MB / GB */
String formatSize(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s} ${units[i]}';
}

/** formatSpeed：每秒字节数 */
String formatSpeed(double bps) => '${formatSize(bps)}/s';

String _two(int n) => n.toString().padLeft(2, '0');

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/**
 * formatListTime：会话列表时间
 *
 * 处理流程：
 * 1、今天显示时:分
 * 2、昨天显示「昨天」
 * 3、一周内显示星期，今年内显示月/日，更早显示年/月/日
 */
String formatListTime(int ms, {DateTime? now}) {
  if (ms <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  // 1、今天
  if (diff <= 0) return '${_two(t.hour)}:${_two(t.minute)}';
  // 2、昨天
  if (diff == 1) return '昨天';
  // 3、更早
  if (diff < 7) return _weekdays[t.weekday - 1];
  if (t.year == n.year) return '${t.month}月${t.day}日';
  return '${t.year}/${t.month}/${t.day}';
}

/** formatChatTime：聊天中的时间分隔（今天 14:20 / 昨天 09:00 / 10月1日 09:00） */
String formatChatTime(int ms, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final head = formatListTime(ms, now: now);
  return head.contains(':') ? '今天 $hm' : '$head $hm';
}

/** formatAgo：相对时间（刚刚 / N 分钟前 / N 小时前 / 昨天 / 日期） */
String formatAgo(int ms, {DateTime? now}) {
  if (ms <= 0) return '';
  final n = now ?? DateTime.now();
  final d = n.difference(DateTime.fromMillisecondsSinceEpoch(ms));
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  if (d.inHours < 24 && t.day == n.day) return '${d.inHours} 小时前';
  final s = formatListTime(ms, now: n);
  return s.contains(':') ? '${d.inHours} 小时前' : s;
}

/** formatRemain：剩余时间 */
String formatRemain(int seconds) {
  if (seconds < 0) return '';
  if (seconds < 60) return '剩余 $seconds 秒';
  if (seconds < 3600) return '剩余 ${seconds ~/ 60} 分 ${seconds % 60} 秒';
  return '剩余 ${seconds ~/ 3600} 小时 ${seconds % 3600 ~/ 60} 分';
}

/** formatClock：年月日时分 */
String formatClock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}

/** isDateFolder：是否为 YYYYMMDD 日期文件夹 */
bool isDateFolder(String name) => RegExp(r'^\d{8}$').hasMatch(name);
