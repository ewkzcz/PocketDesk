/**
 * 分享：通过系统分享面板发出文件或文字。
 */
library;

import 'package:share_plus/share_plus.dart';

/** 当前 App 版本，与 pubspec 保持一致 */
const appVersion = '1.0.0';

/** shareFile：分享本机文件 */
Future<void> shareFile(String path, {String title = ''}) =>
    SharePlus.instance.share(ShareParams(files: [XFile(path)], title: title.isEmpty ? null : title));

/** shareText：分享文字 */
Future<void> shareText(String text) => SharePlus.instance.share(ShareParams(text: text));
