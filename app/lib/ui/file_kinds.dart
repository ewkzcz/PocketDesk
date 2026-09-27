/**
 * 文件类型：按扩展名判断查看方式，并给出列表图标与颜色。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'tokens.dart';

/** 查看方式（book 为 txt，用小说阅读器打开；word、excel、slides 为 Office 文档） */
enum ViewKind { markdown, pdf, image, text, book, word, excel, slides, media, other }

const _image = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg'};
const _media = {'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi', 'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'};
const _archive = {'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz'};
const _text = {
  'txt', 'log', 'json', 'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'env', 'csv', 'tsv', 'xml', 'html', 'htm', 'css', 'scss', 'less', //
  'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'vue', 'svelte', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'm', 'mm', 'c', 'h', 'cc', //
  'cpp', 'hpp', 'cs', 'php', 'lua', 'dart', 'sh', 'bash', 'zsh', 'fish', 'ps1', 'bat', 'cmd', 'sql', 'graphql', 'proto', 'gradle', //
  'properties', 'lock', 'gitignore', 'dockerfile', 'makefile', 'r', 'scala', 'ex', 'exs', 'erl', 'hs', 'clj', 'tex', 'rst', 'adoc', 'diff', 'patch',
};

/** 无扩展名但通常是文本的文件 */
const _textNames = {'makefile', 'dockerfile', 'license', 'readme', 'procfile', 'gemfile', 'rakefile', 'jenkinsfile', 'vagrantfile'};

/** extOf：小写扩展名 */
String extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0) return '';
  if (i == 0) return name.substring(1).toLowerCase();
  return name.substring(i + 1).toLowerCase();
}

/** viewKindOf：按文件名判断查看方式 */
ViewKind viewKindOf(String name) {
  final e = extOf(name);
  if (e == 'md' || e == 'markdown') return ViewKind.markdown;
  if (e == 'pdf') return ViewKind.pdf;
  if (e == 'txt') return ViewKind.book;
  if (e == 'docx') return ViewKind.word;
  if (e == 'xlsx' || e == 'xlsm') return ViewKind.excel;
  if (e == 'pptx') return ViewKind.slides;
  if (_image.contains(e) && e != 'svg') return ViewKind.image;
  if (_media.contains(e)) return ViewKind.media;
  if (_text.contains(e) || _textNames.contains(name.toLowerCase()) || e == 'svg') return ViewKind.text;
  return ViewKind.other;
}

/** FileIcon：列表中的文件图标（彩色浅底） */
class FileIcon extends StatelessWidget {
  const FileIcon({super.key, required this.name, required this.isDir, this.dateFolder = false, this.size = 40});

  final String name;
  final bool isDir;
  final bool dateFolder;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final (IconData icon, Color color) = _pick(c);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(PdSize.smallRadius)),
      child: Icon(icon, size: size * 0.55, color: color),
    );
  }

  (IconData, Color) _pick(PdColors c) {
    if (isDir) return (dateFolder ? LucideIcons.folderClock300 : LucideIcons.folder300, dateFolder ? c.accent : c.text3);
    final e = extOf(name);
    if (_archive.contains(e)) return (LucideIcons.fileArchive300, PdFileColors.archive);
    return switch (viewKindOf(name)) {
      ViewKind.markdown || ViewKind.text => (e == 'md' ? LucideIcons.fileText300 : LucideIcons.fileCode300, c.info),
      ViewKind.book => (LucideIcons.bookOpen300, PdFileColors.book),
      ViewKind.word => (LucideIcons.fileText300, PdFileColors.word),
      ViewKind.excel => (LucideIcons.sheet300, PdFileColors.excel),
      ViewKind.slides => (LucideIcons.presentation300, PdFileColors.slides),
      ViewKind.pdf => (LucideIcons.fileText300, c.danger),
      ViewKind.image => (LucideIcons.fileImage300, PdFileColors.image),
      ViewKind.media => (_media.contains(e) && {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus'}.contains(e) ? LucideIcons.fileAudio300 : LucideIcons.fileVideo300, PdFileColors.media),
      ViewKind.other => (LucideIcons.file300, c.text3),
    };
  }
}
