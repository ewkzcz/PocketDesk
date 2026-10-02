/**
 * 改动查看：本会话累计改动的文件清单，点开单个文件看逐行差异；Markdown 文件可直接用阅读器打开。
 */
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../tokens.dart';
import '../viewers/open_file.dart';
import 'files_page.dart';
import '../widgets.dart';

/**
 * DiffPage：改动清单；指定 initial 时直接显示该文件的差异
 */
class DiffPage extends StatefulWidget {
  const DiffPage({super.key, required this.sessionId, this.initial, this.files = const [], this.ws});

  final String sessionId;
  final FileChange? initial;
  final List<FileChange> files;
  final Workspace? ws;

  @override
  State<DiffPage> createState() => _DiffPageState();
}

class _DiffPageState extends State<DiffPage> {
  List<FileChange> _files = [];
  bool _git = true;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    // 从改动卡片进入时直接显示这一轮的文件；否则读取本会话累计改动
    if (widget.initial == null && widget.files.isEmpty) {
      _load();
    } else {
      _loading = false;
    }
  }

  /** _load：读取本会话累计改动 */
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await context.read<AppState>().scope!.conn.api.diffSummary(widget.sessionId);
      if (!mounted) return;
      setState(() {
        _files = r.files;
        _git = r.git;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final init = widget.initial;
    if (init != null) return DiffFileView(sessionId: widget.sessionId, file: init, ws: widget.ws);
    final c = context.pd;
    final turn = widget.files.isNotEmpty;
    final files = turn ? widget.files : _files;
    return Scaffold(
      appBar: PdBar(title: turn ? '本轮改动' : '本会话改动', subtitle: _loading ? '' : '${files.length} 个文件${turn || _git ? '' : ' · 根据各轮改动记录统计'}'),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: c.accent))
          : files.isEmpty
              ? EmptyHint(icon: LucideIcons.gitCompare300, text: _error.isNotEmpty ? _error : '本会话还没有改动文件', action: _error.isNotEmpty ? '重试' : '', onAction: _load)
              : ListView.separated(
                  padding: const EdgeInsets.only(top: 12),
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const InsetDivider(),
                  itemBuilder: (_, i) {
                    final f = files[i];
                    return PdCell(
                      title: f.path,
                      subtitle: f.binary ? '二进制文件' : '+${f.added}  -${f.removed}',
                      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DiffFileView(sessionId: widget.sessionId, file: f, ws: widget.ws))),
                    );
                  },
                ),
    );
  }
}

/**
 * DiffFileView：单个文件的差异
 */
class DiffFileView extends StatefulWidget {
  const DiffFileView({super.key, required this.sessionId, required this.file, this.ws});

  final String sessionId;
  final FileChange file;
  final Workspace? ws;

  @override
  State<DiffFileView> createState() => _DiffFileViewState();
}

class _DiffFileViewState extends State<DiffFileView> {
  String? _diff;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 二进制文件（如 pdf、图片，或只改了格式的 Office 文件）没有文字差异，直接提示预览
    if (widget.file.binary && widget.file.ref.isEmpty) {
      setState(() => _diff = '');
      return;
    }
    try {
      final d = await context.read<AppState>().scope!.conn.api.diffFile(widget.sessionId, widget.file.path, ref: widget.file.ref);
      if (mounted) setState(() => _diff = d);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /** _where：文件在电脑上的位置，优先用完整路径，较早的记录按会话工作目录推算 */
  Future<({Workspace ws, String rel, String abs})?> _where() async {
    final app = context.read<AppState>();
    final api = app.scope?.conn.api;
    if (api == null) {
      toast(context, '电脑不在线');
      return null;
    }
    try {
      final pc = (await api.workspaces()).where((w) => w.system).firstOrNull;
      if (pc == null) return null;
      var abs = widget.file.abs;
      if (abs.isEmpty) {
        final ws = widget.ws;
        final s = app.scope?.sessions.byId(widget.sessionId);
        if (ws == null || s == null) return null;
        final rel = s.cwd == '.' || s.cwd.isEmpty ? widget.file.path : '${s.cwd}/${widget.file.path}';
        abs = ws.absPath(rel);
      }
      final rel = pc.relOf(abs);
      return rel.isEmpty ? null : (ws: pc, rel: rel, abs: abs);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
      return null;
    }
  }

  /** _read：在手机上预览文件，位置不受会话工作目录限制 */
  Future<void> _read() async {
    final w = await _where();
    if (!mounted) return;
    if (w == null) {
      toast(context, '找不到这个文件');
      return;
    }
    await openWorkspaceFile(context, ws: w.ws, entry: FileEntry(name: w.rel.split('/').last, path: w.rel, isDir: false, size: 0, modTime: 0), siblings: const [], readOnly: w.ws.readOnly);
  }

  /** _folder：打开文件所在的文件夹 */
  Future<void> _folder() async {
    final w = await _where();
    if (!mounted) return;
    if (w == null) {
      toast(context, '找不到这个文件');
      return;
    }
    final i = w.abs.lastIndexOf(w.abs.contains('\\') ? '\\' : '/');
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FilesPage(openDir: i <= 0 ? w.abs : w.abs.substring(0, i))));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final gone = widget.file.status == 'D' || widget.file.status == 'deleted';
    final diff = _diff;
    return Scaffold(
      appBar: PdBar(
        title: widget.file.path.split('/').last,
        subtitle: widget.file.path,
        actions: [
          if (!gone) PdIconButton(icon: LucideIcons.eye300, tooltip: '预览文件', onTap: _read),
          PdIconButton(icon: LucideIcons.folderOpen300, tooltip: '打开所在文件夹', onTap: _folder),
        ],
      ),
      backgroundColor: c.card,
      body: diff == null
          ? (_error.isNotEmpty ? EmptyHint(icon: LucideIcons.fileX300, text: _error) : Center(child: CircularProgressIndicator(color: c.accent)))
          : diff.trim().isEmpty
              ? (widget.file.binary && !gone
                  ? EmptyHint(icon: LucideIcons.fileImage300, text: '二进制文件没有文字差异\n可以直接预览这个文件', action: '预览文件', onAction: _read)
                  : const EmptyHint(icon: LucideIcons.fileCheck300, text: '没有文本差异'))
              : DiffText(diff),
    );
  }
}

/**
 * DiffText：逐行着色的差异文本（新增绿色、删除红色、段落头蓝色），可横向滚动
 */
class DiffText extends StatelessWidget {
  const DiffText(this.diff, {super.key});

  final String diff;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final lines = diff.split('\n');
    final mono = TextStyle(fontSize: 12, height: 1.5, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback, color: c.text);
    return LayoutBuilder(builder: (context, box) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: box.maxWidth),
          child: SizedBox(
            width: _width(lines, box.maxWidth),
            child: ListView.builder(
              itemCount: lines.length,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemBuilder: (_, i) {
                final l = lines[i];
                Color? bg;
                var fg = c.text;
                if (l.startsWith('+') && !l.startsWith('+++')) {
                  bg = c.accent.withValues(alpha: 0.12);
                } else if (l.startsWith('-') && !l.startsWith('---')) {
                  bg = c.danger.withValues(alpha: 0.12);
                } else if (l.startsWith('@@')) {
                  fg = c.info;
                } else if (l.startsWith('diff ') || l.startsWith('index ') || l.startsWith('+++') || l.startsWith('---')) {
                  fg = c.text3;
                }
                return Container(color: bg, padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(l.isEmpty ? ' ' : l, softWrap: false, style: mono.copyWith(color: fg)));
              },
            ),
          ),
        ),
      );
    });
  }

  /** _width：按最长行估算内容宽度 */
  static double _width(List<String> lines, double min) {
    final longest = lines.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    final w = longest * 7.4 + 24;
    return w < min ? min : (w > 6000 ? 6000 : w);
  }
}
