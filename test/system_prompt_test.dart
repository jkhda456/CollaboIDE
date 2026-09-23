// 기본 프롬프트는 핵심만, 도구별 안내는 그 도구가 켜져 있을 때만.
import 'package:collabo_ide/src/llm/system_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('기본 프롬프트에는 도구별 안내가 박혀 있지 않고, 샌드박스 환경을 말한다', () {
    for (final g in kToolGuides) {
      expect(kDefaultSystemPrompt, isNot(contains(g.heading)), reason: g.heading);
    }
    expect(kDefaultSystemPrompt, contains('Linux sandbox'));
    expect(kDefaultSystemPrompt, isNot(contains('request_elevation')));
    expect(kDefaultSystemPrompt, isNot(contains('set_goal')), reason: '계획 규율은 계획 도구가 있을 때만');
  });

  test('켜진 도구에 해당하는 안내만 붙는다', () {
    expect(toolGuidesFor(const []), isNull);
    final onlyFiles = toolGuidesFor(const ['read_file', 'read_lines'])!;
    expect(onlyFiles, contains('Large files'));
    expect(onlyFiles, isNot(contains('Terminal sessions')));
    expect(onlyFiles, isNot(contains('Long-running commands')));

    final all = toolGuidesFor(const ['run_command', 'term_open', 'run_subagent', 'verify_work', 'search_text'])!;
    for (final h in ['Delegating to sub-agents', 'Verifying your work', 'Long-running commands', 'Terminal sessions', 'Large files']) {
      expect(all, contains(h));
    }
  });

  test('서브에이전트에는 위임·검증 안내를 주지 않는다', () {
    final sub = toolGuidesFor(const ['run_command', 'run_subagent', 'verify_work'], forSubAgent: true)!;
    expect(sub, contains('Long-running commands'));
    expect(sub, isNot(contains('Delegating to sub-agents')));
    expect(sub, isNot(contains('Verifying your work')));
  });

  test('사용자 프롬프트에 같은 제목이 있으면 다시 붙이지 않는다', () {
    const saved = 'My rules.\n\nTerminal sessions\n- my own terminal rules';
    final g = toolGuidesFor(const ['term_open', 'run_command'], existing: saved)!;
    expect(g, isNot(contains('Terminal sessions')));
    expect(g, contains('Long-running commands'));
  });

  test('기본값 판정: 빈 값·지금 기본값·옛 기본값은 기본값, 고친 것은 아니다', () {
    expect(isDefaultPromptText(''), isTrue);
    expect(isDefaultPromptText('  $kDefaultSystemPrompt\n'), isTrue);
    expect(isDefaultPromptText('You are my assistant.'), isFalse);
    expect(isDefaultPromptText('$kDefaultSystemPrompt\nAlways answer in Korean.'), isFalse);
    // 지문은 공백 차이에 흔들리지 않는다(저장·편집기에서 줄바꿈이 바뀌어도 같은 값).
    expect(promptFingerprint('a  b\n c'), promptFingerprint('a b c'));
    expect(kLegacyDefaultPromptFingerprints, isNotEmpty);
  });
}
