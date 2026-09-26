/**
 * 选择目录：在工作区内逐级浏览文件夹，点「选择此目录」返回相对路径（移动文件、切换会话工作目录时使用）。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../file_kinds.dart';
import '../tokens.dart';
import '../widgets.dart';

/** pickDir：打开目录选择，返回工作区内相对路径（根目录为 "."），取消返回 null */
Future<String?> pickDir(BuildContext context, {required Workspace ws, String start = '', String title = '选择目录', String action = '选择此目录'}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => DirPicker(ws: ws, start: start, title: title, action: action)));

/** pickWorkspaceFile：在工作区中选择一个文件，返回相对路径 */
Future<String?> pickWorkspaceFile(BuildContext context, {required Workspace ws, String start = ''}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => DirPicker(ws: ws, start: start, title: '选择工作区文件', files: true)));

/**
 * DirPicker：目录选择页
 */
class DirPicker extends StatefulWidget {
  const DirPicker({super.key, required this.ws, this.start = '', this.title = '选择目录', this.action = '选择此目录', this.files = false});

  final Workspace ws;

  /** 为 true 时同时列出文件，点击文件即返回 */
  final bool files;
  final String start;
  final String title;
  final String action;

  @override
  State<DirPicker> createState() => _DirPickerState();
}

class _DirPickerState extends State<DirPicker> {
  late String _path = widget.start == '.' ? '' : widget.start;
  List<FileEntry> _dirs = [];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  /** _load：读取当前目录下的文件夹 */
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await context.read<AppState>().scope!.conn.api.list(widget.ws.id, _path.isEmpty ? '.' : _path);
      if (!mounted) return;
      setState(() => _dirs = r.entries.where((e) => e.isDir || widget.files).toList());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /** _go：进入或返回目录 */
  void _go(String p) {
    _path = p;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final parts = _path.isEmpty ? <String>[] : _path.split('/');
    return PopScope(
      canPop: _path.isEmpty,
      onPopInvokedWithResult: (did, _) {
        if (!did) _go(parts.sublist(0, parts.length - 1).join('/'));
      },
      child: Scaffold(
        appBar: PdBar(title: widget.title),
        body: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter, vertical: 10),
            child: Text([widget.ws.name, ...parts].join(' / '), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.summary, color: c.text3)),
          ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: c.accent))
                : _error.isNotEmpty
                    ? EmptyHint(icon: LucideIcons.wifiOff300, text: _error, action: '重试', onAction: _load)
                    : _dirs.isEmpty
                        ? EmptyHint(icon: LucideIcons.folderOpen300, text: widget.files ? '这里是空的' : '没有子文件夹')
                        : ListView.separated(
                            itemCount: _dirs.length,
                            separatorBuilder: (_, _) => const InsetDivider(indent: 68),
                            itemBuilder: (_, i) {
                              final d = _dirs[i];
                              return Material(
                                color: c.card,
                                child: InkWell(
                                  onTap: () => d.isDir ? _go(d.path) : Navigator.pop(context, d.path),
                                  child: SizedBox(
                                    height: PdSize.fileItem,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter),
                                      child: Row(children: [
                                        FileIcon(name: d.name, isDir: d.isDir, dateFolder: d.dateFolder, size: 36),
                                        const SizedBox(width: 16),
                                        Expanded(child: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.item, color: c.text))),
                                        if (d.isDir) Icon(LucideIcons.chevronRight300, size: 18, color: c.text4),
                                      ]),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
          if (!widget.files)
          Container(
            color: c.bar,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(context, _path.isEmpty ? '.' : _path), child: Text(widget.action))),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
