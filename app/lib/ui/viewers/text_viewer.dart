/**
 * 文本查看与编辑：语法高亮、自动换行切换；可编辑时支持撤销重做、查找替换，保存时带 If-Match 防止覆盖电脑上的新修改。
 */
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../core/app_state.dart';
import '../../data/models.dart';
import '../../net/api.dart';
import '../file_kinds.dart';
import '../tokens.dart';
import '../widgets.dart';
import 'fetch.dart';
import 'save.dart';

/** 最多高亮的字节数，更大的文件只显示纯文本，保证滚动流畅 */
const _highlightLimit = 200 * 1024;

/** languageFor：扩展名对应的高亮语言 */
String languageFor(String name) => switch (extOf(name)) {
      'js' || 'mjs' || 'cjs' || 'jsx' => 'javascript',
      'ts' || 'tsx' => 'typescript',
      'py' => 'python',
      'rb' => 'ruby',
      'rs' => 'rust',
      'kt' || 'kts' => 'kotlin',
      'sh' || 'bash' || 'zsh' || 'fish' => 'bash',
      'ps1' => 'powershell',
      'yml' || 'yaml' => 'yaml',
      'md' || 'markdown' => 'markdown',
      'html' || 'htm' || 'xml' || 'svg' || 'vue' => 'xml',
      'h' || 'c' => 'cpp',
      'cc' || 'cpp' || 'hpp' => 'cpp',
      'cs' => 'cs',
      'm' || 'mm' => 'objectivec',
      'toml' || 'ini' || 'cfg' || 'conf' || 'properties' => 'ini',
      'diff' || 'patch' => 'diff',
      'json' || 'go' || 'java' || 'swift' || 'dart' || 'sql' || 'php' || 'lua' || 'css' || 'scss' || 'less' || 'scala' || 'r' => extOf(name),
      _ => 'plaintext',
    };

/**
 * TextViewerPage：文本查看与编辑
 */
class TextViewerPage extends StatefulWidget {
  const TextViewerPage({super.key, required this.ws, required this.path, this.readOnly = false});

  final Workspace ws;
  final String path;
  final bool readOnly;

  @override
  State<TextViewerPage> createState() => _TextViewerPageState();
}

class _TextViewerPageState extends State<TextViewerPage> {
  String _text = '';
  String _etag = '';
  late String _path = widget.path;
  bool _loading = true;
  String _error = '';
  bool _wrap = true;
  bool _editing = false;
  bool _saving = false;
  bool _find = false;
  final _edit = TextEditingController();
  final _undo = UndoHistoryController();
  final _editFocus = FocusNode();
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();
  int _hit = -1;

  bool get _dirty => _editing && _edit.text != _text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _edit.dispose();
    _undo.dispose();
    _editFocus.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  /** _load：读取文件 */
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await readWsFile(context.read<AppState>().scope!, widget.ws.id, _path);
      if (!mounted) return;
      final text = utf8.decode(r.bytes, allowMalformed: true);
      setState(() {
        _text = text;
        _etag = r.etag;
        if (text.contains('\u0000')) _error = '这是二进制文件，无法以文本查看';
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /** _startEdit：进入编辑 */
  void _startEdit() {
    _edit.text = _text;
    _undo.value = UndoHistoryValue.empty;
    setState(() => _editing = true);
    _editFocus.requestFocus();
  }

  /** _save：保存（冲突时交给用户选择） */
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final r = await saveWithConflict(context, ws: widget.ws, path: _path, bytes: utf8.encode(_edit.text), etag: _etag);
      if (!mounted) return;
      if (r.saved) {
        setState(() {
          _text = _edit.text;
          _etag = r.etag;
          _path = r.path;
          _editing = false;
        });
        toast(context, r.path == widget.path ? '已保存' : '已另存为 ${r.path.split('/').last}');
      } else {
        // 放弃修改：重新读取电脑上的版本
        setState(() => _editing = false);
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /** _findNext：查找下一个 */
  void _findNext() {
    final q = _findCtrl.text;
    if (q.isEmpty) return;
    final t = _edit.text;
    var i = t.indexOf(q, _hit + 1);
    if (i < 0) i = t.indexOf(q);
    if (i < 0) {
      toast(context, '没有找到');
      return;
    }
    _hit = i;
    _edit.selection = TextSelection(baseOffset: i, extentOffset: i + q.length);
    _editFocus.requestFocus();
  }

  /** _replace：替换当前或全部 */
  void _replace({bool all = false}) {
    final q = _findCtrl.text;
    if (q.isEmpty) return;
    if (all) {
      final n = q.allMatches(_edit.text).length;
      _edit.text = _edit.text.replaceAll(q, _replaceCtrl.text);
      toast(context, '已替换 $n 处');
      return;
    }
    final sel = _edit.selection;
    if (sel.isValid && _edit.text.substring(sel.start, sel.end) == q) {
      _edit.text = _edit.text.replaceRange(sel.start, sel.end, _replaceCtrl.text);
      _hit = sel.start + _replaceCtrl.text.length - 1;
    }
    _findNext();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final canEdit = !widget.readOnly && _error.isEmpty && !_loading && (context.read<AppState>().scope?.conn.status?.features.fileEdit ?? true);
    final mono = TextStyle(fontSize: 13, height: 1.5, fontFamily: PdFont.mono, fontFamilyFallback: PdFont.monoFallback, color: c.text);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (did, _) async {
        if (did) return;
        final leave = await confirm(context, title: '放弃未保存的修改？', ok: '放弃', danger: true);
        if (leave && context.mounted) {
          setState(() => _editing = false);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: c.card,
        appBar: PdBar(
          title: _path.split('/').last,
          subtitle: widget.readOnly ? '只读' : (_editing ? '编辑中' : ''),
          actions: _editing
              ? [
                  ValueListenableBuilder(
                    valueListenable: _undo,
                    builder: (_, v, _) => PdIconButton(icon: LucideIcons.undo2300, tooltip: '撤销', onTap: v.canUndo ? _undo.undo : null),
                  ),
                  ValueListenableBuilder(
                    valueListenable: _undo,
                    builder: (_, v, _) => PdIconButton(icon: LucideIcons.redo2300, tooltip: '重做', onTap: v.canRedo ? _undo.redo : null),
                  ),
                  PdIconButton(icon: LucideIcons.searchCode300, tooltip: '查找替换', onTap: () => setState(() => _find = !_find)),
                  _saving
                      ? const SizedBox(width: 44, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))))
                      : PdIconButton(icon: LucideIcons.check300, tooltip: '保存', color: c.accent, onTap: _save),
                ]
              : [
                  PdIconButton(icon: _wrap ? LucideIcons.wrapText300 : LucideIcons.textAlignStart300, tooltip: _wrap ? '不换行' : '自动换行', onTap: () => setState(() => _wrap = !_wrap)),
                  if (canEdit) PdIconButton(icon: LucideIcons.pencil300, tooltip: '编辑', onTap: _startEdit),
                ],
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: c.accent))
            : _error.isNotEmpty
                ? EmptyHint(icon: LucideIcons.fileX300, text: _error, action: '重试', onAction: _load)
                : _editing
                    ? Column(children: [
                        if (_find) _FindBar(find: _findCtrl, replace: _replaceCtrl, onNext: _findNext, onReplace: () => _replace(), onReplaceAll: () => _replace(all: true)),
                        Expanded(
                          child: TextField(
                            controller: _edit,
                            focusNode: _editFocus,
                            undoController: _undo,
                            maxLines: null,
                            expands: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            keyboardType: TextInputType.multiline,
                            textAlignVertical: TextAlignVertical.top,
                            style: mono,
                            decoration: InputDecoration(fillColor: c.card, contentPadding: const EdgeInsets.all(12)),
                          ),
                        ),
                      ])
                    : _View(text: _text, name: _path, wrap: _wrap, mono: mono, dark: dark),
      ),
    );
  }
}

/** _View：只读显示（小文件语法高亮） */
class _View extends StatelessWidget {
  const _View({required this.text, required this.name, required this.wrap, required this.mono, required this.dark});

  final String text;
  final String name;
  final bool wrap;
  final TextStyle mono;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final lang = languageFor(name);
    final Widget body = text.length <= _highlightLimit && lang != 'plaintext'
        ? HighlightView(text, language: lang, theme: {...(dark ? atomOneDarkTheme : githubTheme), 'root': TextStyle(color: mono.color, backgroundColor: context.pd.card)}, textStyle: mono, padding: const EdgeInsets.all(12))
        : Padding(padding: const EdgeInsets.all(12), child: SelectableText(text, style: mono));
    if (wrap) return SingleChildScrollView(child: body);
    return SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: body));
  }
}

/** _FindBar：查找替换栏 */
class _FindBar extends StatelessWidget {
  const _FindBar({required this.find, required this.replace, required this.onNext, required this.onReplace, required this.onReplaceAll});

  final TextEditingController find;
  final TextEditingController replace;
  final VoidCallback onNext;
  final VoidCallback onReplace;
  final VoidCallback onReplaceAll;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    InputDecoration deco(String hint) => InputDecoration(hintText: hint, fillColor: c.page, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8));
    return Container(
      color: c.bar,
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Column(children: [
        Row(children: [
          Expanded(child: TextField(controller: find, decoration: deco('查找'), onSubmitted: (_) => onNext())),
          PdIconButton(icon: LucideIcons.arrowDown300, tooltip: '下一个', onTap: onNext),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: TextField(controller: replace, decoration: deco('替换为'))),
          TextButton(onPressed: onReplace, child: const Text('替换')),
          TextButton(onPressed: onReplaceAll, child: const Text('全部')),
        ]),
      ]),
    );
  }
}
