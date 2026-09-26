/**
 * 选择本机文件：相册、拍摄、系统文件选择器；没有本地路径的文件先复制到缓存目录。
 */
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import '../transfer/naming.dart' as naming;

/** Picked：选中的一个文件 */
typedef Picked = ({String path, String name, String mime});

/** pickImages：从相册选择图片或视频（可多选） */
Future<List<Picked>> pickImages() async {
  final list = await ImagePicker().pickMultipleMedia();
  return [for (final x in list) (path: x.path, name: x.name, mime: x.mimeType ?? naming.mimeForName(x.name))];
}

/** takePhoto：拍摄照片（拍摄的照片没有原始文件名，由电脑端按时间命名） */
Future<List<Picked>> takePhoto() async {
  final x = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90);
  if (x == null) return const [];
  return [(path: x.path, name: '', mime: x.mimeType ?? 'image/jpeg')];
}

/** pickFiles：系统文件选择器（可多选） */
Future<List<Picked>> pickFiles(Directory cache) async {
  final list = await FilePicker.pickFiles();
  final out = <Picked>[];
  for (final f in list) {
    var path = f.path;
    if (path == null) {
      // 没有本地路径（如云盘文件）时复制到缓存目录
      await cache.create(recursive: true);
      path = '${cache.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-${naming.sanitize(f.name)}';
      await f.xFile.saveTo(path);
    }
    out.add((path: path, name: f.name, mime: naming.mimeForName(f.name)));
  }
  return out;
}
