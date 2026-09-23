// 작은 컨텍스트 모델(Apple 온디바이스 4K 등)에 요청을 맞추는 규칙.
import 'package:afm_bridge/afm_bridge.dart' show AfmBridgeException;
import 'package:collabo_ide/src/llm/context_fit.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _tool(String name, {int descLen = 40}) => {
      'type': 'function',
      'function': {
        'name': name,
        'description': 'x' * descLen,
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path'},
          },
        },
      },
    };

void main() {
  test('Apple 연결은 감지 전이면 4096 으로 보고 맞춤을 켠다', () {
    const cfg = LlmConfig(connection: LlmConnection.appleFoundation);
    expect(cfg.effectiveContextWindow, 4096);
    final fit = ContextFit.of(cfg);
    expect(fit.active, isTrue);
    expect(fit.outputReserve, 1024);
    expect(fit.inputBudget, 3072);
    // 도구가 가장 크다: 입력 − 프롬프트 15% − 대화 최소 25%
    expect(fit.toolBudget, 3072 - fit.promptBudget - fit.conversationFloor);
    expect(fit.toolBudget, greaterThan(fit.promptBudget + fit.conversationFloor));
  });

  test('창을 모르는 네트워크 연결·큰 창·자동 맞춤 끔이면 아무것도 줄이지 않는다', () {
    expect(ContextFit.of(const LlmConfig()).active, isFalse);
    expect(ContextFit.of(const LlmConfig(contextWindow: 131072)).active, isFalse);
    expect(
        ContextFit.of(const LlmConfig(connection: LlmConnection.appleFoundation, autoFitContext: false))
            .active,
        isFalse);
    final tools = [_tool('run_subagent'), _tool('read_file')];
    expect(ContextFit.of(const LlmConfig()).selectTools(tools), tools);
  });

  test('작은 창: 도구는 최대한 싣고(개수 상한 없음) 위임·계획 도구만 뺀다, 원래 순서 유지', () {
    final fit = ContextFit.of(const LlmConfig(connection: LlmConnection.appleFoundation));
    final tools = [
      _tool('web_search', descLen: 200),
      _tool('run_subagent'),
      _tool('edit_file'),
      _tool('term_open', descLen: 200),
      _tool('read_file'),
      _tool('update_plan'),
      _tool('list_directory'),
      _tool('write_file'),
      _tool('search_text'),
      _tool('run_command'),
    ];
    final names = fit.selectTools(tools).map(ContextFit.toolName).toList();
    expect(names, [
      'web_search', 'edit_file', 'term_open', 'read_file', 'list_directory', 'write_file',
      'search_text', 'run_command',
    ]);
  });

  test('몫이 모자라면 우선순위가 낮은 큰 도구부터 빠진다', () {
    final fit = ContextFit.of(const LlmConfig(connection: LlmConnection.appleFoundation));
    Map<String, Object?> huge(String name) => {
          'type': 'function',
          'function': {
            'name': name,
            'description': 'Huge.',
            'parameters': {
              'type': 'object',
              'properties': {for (var i = 0; i < 120; i++) 'field_$i': {'type': 'string'}},
            },
          },
        };
    final tools = [huge('web_open'), _tool('read_file'), huge('term_send'), _tool('list_directory')];
    // 핵심 도구가 먼저 들어가고, 큰 도구 둘 중 먼저 온 것만 남는다(뒤의 것은 몫을 넘는다).
    expect(fit.selectTools(tools).map(ContextFit.toolName), ['web_open', 'read_file', 'list_directory']);
  });

  test('도구 정의 줄이기: 설명은 첫 문장, 이름·인자·타입·필수는 그대로', () {
    final tool = {
      'type': 'function',
      'function': {
        'name': 'edit_file',
        'description': 'Edit a file by replacing text. Use read_file first. Very long details follow here.',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Path of the file to edit. Relative to the project root.'},
            'items': {
              'type': 'array',
              'items': {'type': 'string', 'description': 'One item. More text.'},
            },
          },
          'required': ['path'],
        },
      },
    };
    final c = ContextFit.compactTool(tool)['function'] as Map;
    expect(c['name'], 'edit_file');
    expect(c['description'], 'Edit a file by replacing text.');
    final params = c['parameters'] as Map;
    expect(params['required'], ['path']);
    expect((params['properties'] as Map)['path'], {'type': 'string', 'description': 'Path of the file to edit.'});
    expect(((params['properties'] as Map)['items'] as Map)['items'], {'type': 'string', 'description': 'One item.'});
  });

  test('기본 프롬프트면 간결판, 사용자 프롬프트는 그대로(길면 경고)', () {
    final fit = ContextFit.of(const LlmConfig(connection: LlmConnection.appleFoundation));
    expect(fit.systemPrompt('long default', isDefault: true), kCompactSystemPrompt);
    expect(fit.systemPrompt('my prompt', isDefault: false), 'my prompt');
    expect(fit.promptTooLong('short'), isFalse);
    expect(fit.promptTooLong('word ' * 1000), isTrue);
    expect(ContextFit.estimateText(kCompactSystemPrompt), lessThan(fit.promptBudget));
  });

  test('토큰 추정: 한글은 글자당 약 1토큰, 영문은 약 3.6자당 1토큰', () {
    expect(ContextFit.estimateText('안녕하세요'), 5);
    expect(ContextFit.estimateText('a' * 36), 10);
  });

  test('설정 저장·복원(예전 설정은 창 0 · 자동 맞춤 켬)', () {
    const cfg = LlmConfig(contextWindow: 8192, autoFitContext: false);
    final back = LlmConfig.fromJson(cfg.toJson());
    expect(back.contextWindow, 8192);
    expect(back.autoFitContext, isFalse);
    final old = LlmConfig.fromJson(const {'connection': 'openai'});
    expect(old.contextWindow, 0);
    expect(old.autoFitContext, isTrue);
  });

  test('컨텍스트 길이 초과는 재시도 대상이 아니다(Apple·OpenAI 호환 모두 알아본다)', () {
    expect(isContextLengthError(const AfmBridgeException(message: 'too long', code: 'context_length_exceeded')), isTrue);
    expect(isContextLengthError(const AfmBridgeException(message: 'busy', code: 'rate_limited')), isFalse);
    expect(isContextLengthError(Exception('HTTP 400: {"error":{"code":"context_length_exceeded"}}')), isTrue);
    expect(isContextLengthError(Exception("HTTP 400: This model's maximum context length is 8192 tokens")), isTrue);
    expect(isContextLengthError(Exception('HTTP 500: upstream error')), isFalse);
  });
}
