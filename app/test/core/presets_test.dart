/**
 * 通讯录预设模板测试：参数填进系统提示词、默认值、未引用的参数追加、会话里记录的模板标识。
 */
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketdesk/core/presets.dart';

void main() {
  test('内置模板：翻译与 OCR 识别的参数齐全，提示词里的占位符都有对应参数', () {
    for (final t in builtinPresets) {
      final keys = t.params.map((p) => p.key).toSet();
      for (final m in RegExp(r'\{\{(\w+)\}\}').allMatches(t.prompt)) {
        expect(keys, contains(m.group(1)), reason: '${t.name} 引用了没有定义的参数 ${m.group(1)}');
      }
      expect(t.defaults.length, t.params.length);
    }
    expect(builtinPreset('translate')!.params.map((p) => p.label), containsAll(['目标语言', '翻译风格']));
    expect(builtinPreset('ocr')!.params.map((p) => p.label), containsAll(['识别语言', '输出格式']));
  });

  test('render：参数值填进提示词，没填的用默认值，空值写「未指定」', () {
    final t = builtinPreset('translate')!;
    final out = t.render({'target': '日文'});
    expect(out, contains('翻译成日文'));
    expect(out, isNot(contains('{{')));
    expect(out, contains('术语表优先：未指定'));
    expect(t.render({}), contains('翻译成英文'));
  });

  test('render：提示词没有引用的参数追加在末尾', () {
    const t = PresetTemplate(
      id: 'x',
      name: '测试',
      desc: '',
      icon: 'sparkles',
      color: 0xFF000000,
      prompt: '你是助手。',
      params: [PresetParam('tone', '语气', PresetParamType.choice, options: ['正式', '随意'], def: '正式')],
    );
    final out = t.render({});
    expect(out, startsWith('你是助手。'));
    expect(out, contains('- 语气：正式'));
  });

  test('ref 与 PresetRef：会话里记录的模板标识可以读回', () {
    final t = builtinPreset('ocr')!;
    final ref = PresetRef.parse(t.ref({'lang': '英文'}))!;
    expect(ref.id, 'ocr');
    expect(ref.name, 'OCR 识别');
    expect(ref.params['lang'], '英文');
    expect(ref.params['format'], '纯文本');
    expect(PresetRef.parse(''), isNull);
    expect(PresetRef.parse('不是 JSON'), isNull);
  });

  test('自定义模板：序列化后能读回，格式不对时返回空', () {
    final t = builtinPreset('polish')!;
    final back = PresetTemplate.tryParse(jsonEncode(t.toJson()), libraryId: 'lib1')!;
    expect(back.name, '润色改写');
    expect(back.builtIn, isFalse);
    expect(back.libraryId, 'lib1');
    expect(back.params.length, t.params.length);
    expect(back.render({}), t.render({}));
    expect(PresetTemplate.tryParse('{"a":1}'), isNull);
    expect(PresetTemplate.tryParse('坏数据'), isNull);
  });

  test('mergePresets：同编号的修改版替换内置模板，其余作为自定义模板排在后面', () {
    final changed = PresetTemplate(id: 'translate', name: '翻译', desc: '', icon: 'languages', color: 0, prompt: '改过的 {{target}}', params: builtinPreset('translate')!.params, builtIn: true, libraryId: 'lib1');
    const mine = PresetTemplate(id: 'custom-1', name: '周报', desc: '', icon: 'mail', color: 0, prompt: '写周报', builtIn: false, libraryId: 'lib2');
    final all = mergePresets([changed, mine]);
    expect(all.length, builtinPresets.length + 1);
    final t = all.firstWhere((x) => x.id == 'translate');
    expect(t.overridden, isTrue);
    expect(t.builtIn, isTrue);
    expect(t.render({}), startsWith('改过的 英文'));
    expect(all.last.id, 'custom-1');
    expect(all.firstWhere((x) => x.id == 'ocr').overridden, isFalse);
  });
}
