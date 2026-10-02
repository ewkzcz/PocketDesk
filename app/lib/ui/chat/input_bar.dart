/**
 * 聊天输入栏：语音与键盘切换、输入框、「/」指令按钮、「+」扩展面板，输入文字后「+」变为绿色「发送」；按住说话，上滑取消。
 */
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../tokens.dart';

/** PanelItem：扩展面板的一项 */
class PanelItem {
  const PanelItem(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;
}

/**
 * ChatInputBar：输入栏
 */
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.focus,
    required this.onSend,
    required this.panel,
    required this.onPanel,
    this.showSlash = true,
    this.quote = '',
    this.onClearQuote,
    this.attachments = const [],
    this.onPasteImage,
    this.onImageInserted,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSend;
  final List<PanelItem> panel;
  final void Function(String key) onPanel;
  final bool showSlash;
  final String quote;
  final VoidCallback? onClearQuote;

  /** onPasteImage：长按输入框菜单里的「粘贴图片」 */
  final VoidCallback? onPasteImage;

  /** onImageInserted：输入法（剪贴板、表情图）插入的图片 */
  final void Function(KeyboardInsertedContent content)? onImageInserted;

  /** 待发送的附件（名称与进度文字），点击移除 */
  final List<({String name, String status, VoidCallback remove})> attachments;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  bool _voice = false;
  bool _panel = false;
  bool _listening = false;
  bool _cancelZone = false;
  SpeechToText? _stt;
  String _heard = '';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focus.removeListener(_onFocus);
    unawaited(_stt?.cancel());
    super.dispose();
  }

  void _onText() => setState(() {});

  /** _onFocus：键盘弹出时收起扩展面板 */
  void _onFocus() {
    if (widget.focus.hasFocus && _panel) setState(() => _panel = false);
  }

  bool get _hasText => widget.controller.text.trim().isNotEmpty || widget.attachments.isNotEmpty;

  /** _togglePanel：展开或收起扩展面板 */
  void _togglePanel() {
    setState(() => _panel = !_panel);
    if (_panel) widget.focus.unfocus();
  }

  /** _toggleVoice：切换语音与键盘 */
  void _toggleVoice() {
    setState(() {
      _voice = !_voice;
      _panel = false;
    });
    if (_voice) {
      widget.focus.unfocus();
    } else {
      widget.focus.requestFocus();
    }
  }

  /**
   * _startListen：按下开始识别
   *
   * 处理流程：
   * 1、首次使用时初始化系统语音识别，不可用时提示
   * 2、识别结果实时显示在浮层
   */
  Future<void> _startListen() async {
    // 1、初始化
    final stt = _stt ??= SpeechToText();
    final ok = await stt.initialize(onError: (_) {});
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('语音识别不可用，请检查麦克风权限')));
      return;
    }
    unawaited(HapticFeedback.lightImpact());
    setState(() {
      _listening = true;
      _heard = '';
      _cancelZone = false;
    });
    // 2、识别
    await stt.listen(
      onResult: (r) {
        if (mounted) setState(() => _heard = r.recognizedWords);
      },
      listenOptions: SpeechListenOptions(partialResults: true, listenMode: ListenMode.dictation, localeId: 'zh_CN'),
    );
  }

  /** _endListen：松开结束，结果放进输入框（上滑松开则取消） */
  Future<void> _endListen() async {
    if (!_listening) return;
    final cancel = _cancelZone;
    setState(() => _listening = false);
    if (cancel) {
      await _stt?.cancel();
      return;
    }
    await _stt?.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _heard.trim().isEmpty) return;
    final t = widget.controller.text;
    widget.controller.text = t.isEmpty ? _heard.trim() : '$t${_heard.trim()}';
    widget.controller.selection = TextSelection.collapsed(offset: widget.controller.text.length);
    setState(() => _voice = false);
    widget.focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    final bar = Container(
      decoration: BoxDecoration(color: c.bar, border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.quote.isNotEmpty) _QuoteLine(text: widget.quote, onClear: widget.onClearQuote),
          if (widget.attachments.isNotEmpty) _Attachments(items: widget.attachments),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              _RoundIcon(icon: _voice ? LucideIcons.keyboard300 : LucideIcons.mic300, tooltip: _voice ? '键盘' : '语音', onTap: _toggleVoice),
              Expanded(
                child: _voice
                    ? GestureDetector(
                        onLongPressStart: (_) => _startListen(),
                        onLongPressMoveUpdate: (d) => setState(() => _cancelZone = d.localOffsetFromOrigin.dy < -60),
                        onLongPressEnd: (_) => _endListen(),
                        child: Container(
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(color: _listening ? c.pressed : c.field, borderRadius: BorderRadius.circular(PdSize.smallRadius)),
                          child: Text(_listening ? '松开 结束' : '按住 说话', style: TextStyle(fontSize: PdFont.item, fontWeight: FontWeight.w500, color: c.text)),
                        ),
                      )
                    : ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 38),
                        child: TextField(
                          controller: widget.controller,
                          focusNode: widget.focus,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          style: TextStyle(fontSize: PdFont.item, color: c.text, height: 1.35),
                          contextMenuBuilder: (context, state) => AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: state.contextMenuAnchors,
                            buttonItems: [
                              ...state.contextMenuButtonItems,
                              if (widget.onPasteImage != null)
                                ContextMenuButtonItem(
                                  label: '粘贴图片',
                                  onPressed: () {
                                    state.hideToolbar();
                                    widget.onPasteImage!();
                                  },
                                ),
                            ],
                          ),
                          contentInsertionConfiguration: widget.onImageInserted == null
                              ? null
                              : ContentInsertionConfiguration(allowedMimeTypes: const ['image/png', 'image/jpeg', 'image/gif', 'image/webp'], onContentInserted: widget.onImageInserted!),
                          decoration: InputDecoration(
                            hintText: '输入消息…',
                            fillColor: c.field,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                          ),
                        ),
                      ),
              ),
              if (widget.showSlash && !_hasText)
                _SlashButton(
                  onTap: () {
                    widget.controller.text = '/';
                    widget.controller.selection = const TextSelection.collapsed(offset: 1);
                    setState(() => _voice = false);
                    widget.focus.requestFocus();
                  },
                ),
              if (_hasText && !_voice)
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 2),
                  child: FilledButton(
                    onPressed: widget.onSend,
                    style: FilledButton.styleFrom(minimumSize: const Size(56, 34), padding: const EdgeInsets.symmetric(horizontal: 12)),
                    child: const Text('发送'),
                  ),
                )
              else
                _RoundIcon(icon: _panel ? LucideIcons.circleX300 : LucideIcons.circlePlus300, tooltip: '更多', onTap: _togglePanel),
            ]),
          ),
          AnimatedSize(
            duration: PdMotion.normal,
            curve: PdMotion.curve,
            child: _panel ? _Panel(items: widget.panel, onTap: (k) {
              setState(() => _panel = false);
              widget.onPanel(k);
            }) : const SizedBox(width: double.infinity),
          ),
        ]),
      ),
    );
    if (!_listening) return bar;
    return Stack(clipBehavior: Clip.none, children: [
      bar,
      Positioned(
        left: 40,
        right: 40,
        bottom: 80,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: _cancelZone ? c.danger : c.accent, borderRadius: BorderRadius.circular(PdSize.cardRadius)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(_cancelZone ? LucideIcons.x300 : LucideIcons.audioLines300, color: Colors.white, size: 28),
              const SizedBox(height: 8),
              Text(_heard.isEmpty ? '正在听…' : _heard, textAlign: TextAlign.center, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(height: 6),
              Text(_cancelZone ? '松开手指，取消' : '上滑取消', style: const TextStyle(color: PdDarkUi.overlayText, fontSize: 12)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/** _RoundIcon：输入栏的圆形图标按钮 */
class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        label: tooltip,
        button: true,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 26, color: context.pd.text2)),
        ),
      );
}

/** _SlashButton：「/」指令按钮 */
class _SlashButton extends StatelessWidget {
  const _SlashButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        label: '指令',
        button: true,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: SizedBox(
            width: 36,
            height: 40,
            child: Center(child: Text('/', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: context.pd.text2))),
          ),
        ),
      );
}

/** _QuoteLine：引用回复提示 */
class _QuoteLine extends StatelessWidget {
  const _QuoteLine({required this.text, this.onClear});

  final String text;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(4)),
      child: Row(children: [
        Expanded(child: Text('引用：$text', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3))),
        GestureDetector(onTap: onClear, child: Padding(padding: const EdgeInsets.all(4), child: Icon(LucideIcons.x300, size: 14, color: c.text3))),
      ]),
    );
  }
}

/** _Attachments：待发送的附件 */
class _Attachments extends StatelessWidget {
  const _Attachments({required this.items});

  final List<({String name, String status, VoidCallback remove})> items;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (_, i) => Container(
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(color: c.chip, borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(LucideIcons.paperclip300, size: 14, color: c.text2),
            const SizedBox(width: 4),
            ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: Text(items[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text2))),
            if (items[i].status.isNotEmpty) Text(' ${items[i].status}', style: TextStyle(fontSize: PdFont.tiny, color: c.text3)),
            GestureDetector(onTap: items[i].remove, child: Padding(padding: const EdgeInsets.all(6), child: Icon(LucideIcons.x300, size: 14, color: c.text3))),
          ]),
        ),
      ),
    );
  }
}

/** _Panel：扩展面板（每行 4 个） */
class _Panel extends StatelessWidget {
  const _Panel({required this.items, required this.onTap});

  final List<PanelItem> items;
  final void Function(String key) onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.pd;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.divider, width: PdSize.divider))),
      child: LayoutBuilder(builder: (context, box) {
        final w = (box.maxWidth - 3 * 12) / 4;
        return Wrap(spacing: 12, runSpacing: 12, children: [
          for (final it in items)
            SizedBox(
              width: w,
              child: GestureDetector(
                onTap: () => onTap(it.key),
                behavior: HitTestBehavior.opaque,
                child: Column(children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(PdSize.cardRadius)),
                    child: Icon(it.icon, size: 26, color: c.text2),
                  ),
                  const SizedBox(height: 6),
                  Text(it.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: PdFont.time, color: c.text3)),
                ]),
              ),
            ),
        ]);
      }),
    );
  }
}
