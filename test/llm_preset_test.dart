import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LlmPreset: JSON 왕복(설정 필드 보존)', () {
    final preset = LlmPreset(
      id: 'p1',
      name: 'GPT',
      config: const LlmConfig(
        baseUrl: 'http://x/v1',
        apiKey: 'k',
        model: 'gpt-4o',
        multimodal: true,
        reasoningEffort: 'high',
      ),
    );
    final back = LlmPreset.fromJson(preset.toJson());
    expect(back.id, 'p1');
    expect(back.name, 'GPT');
    expect(back.config.baseUrl, 'http://x/v1');
    expect(back.config.model, 'gpt-4o');
    expect(back.config.multimodal, isTrue);
    expect(back.config.reasoningEffort, 'high');
  });

  test('LlmPreset: label 은 이름 → 모델 → id 순으로 폴백', () {
    expect(
      LlmPreset(id: 'p1', name: '내 모델', config: const LlmConfig(model: 'm'))
          .label,
      '내 모델',
    );
    expect(
      LlmPreset(id: 'p1', name: '  ', config: const LlmConfig(model: 'gpt'))
          .label,
      'gpt',
    );
    expect(
      LlmPreset(id: 'p1', name: '', config: const LlmConfig()).label,
      'p1',
    );
  });

  test('LlmPreset: config 누락 JSON 도 안전하게 파싱', () {
    final back = LlmPreset.fromJson({'id': 'p2', 'name': 'n'});
    expect(back.id, 'p2');
    expect(back.config.isConfigured, isFalse);
  });

  test('LlmPreset.newId: 매번 다른 식별자', () {
    final a = LlmPreset.newId();
    final b = LlmPreset.newId();
    expect(a, isNot(b));
    expect(a.startsWith('p'), isTrue);
  });
}
