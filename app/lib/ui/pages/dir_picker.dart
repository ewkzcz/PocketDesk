/**
 * 选择目录：在工作区内逐级浏览文件夹，点「选择此目录」返回相对路径（移动文件、切换会话工作目录、选择工作空间时使用）；
 * 点路径中的任一级可直接跳回，可在当前位置新建文件夹。
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

  /** _mkdir：在当前位置新建文件夹并进入 */
  Future<void> _mkdir() async {
    final name = await inputDialog(context, title: '新建文件夹', hint: '文件夹名称');
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final created = await context.read<AppState>().scope!.conn.api.op(widget.ws.id, 'mkdir', _path.isEmpty ? '.' : _path, name: name.trim());
      _go(created);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final parts = _path.isEmpty ? <String>[] : _path.split('/');
    final start = widget.start == '.' ? '' : widget.start;
    return PopScope(
      // 回到打开时的位置后，返回键直接关闭；更上层用路径跳转
      canPop: _path.isEmpty || _path == start,
      onPopInvokedWithResult: (did, _) {
        if (!did) _go(parts.sublist(0, parts.length - 1).join('/'));
      },
      child: Scaffold(
        appBar: PdBar(title: widget.title, actions: [
          if (!widget.files && !widget.ws.readOnly) PdIconButton(icon: LucideIcons.folderPlus300, tooltip: '新建文件夹', onTap: _mkdir),
        ]),
        body: Column(children: [
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: PdSize.gutter - 6),
              children: [
                for (var i = parts.length; i >= 0; i--)
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: i == parts.length ? null : () => _go(parts.sublist(0, i).join('/')),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                      child: Text(
                        i == 0 ? widget.ws.name : '/ ${parts[i - 1]}',
                        style: TextStyle(fontSize: PdFont.summary, color: i == parts.length ? c.text : c.info),
                      ),
                    ),
                  ),
              ],
            ),
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
