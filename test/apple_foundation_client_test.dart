// Apple Foundation Models(기기 내 모델) 백엔드.
//
// 채널은 mac/iOS 에서만 살아 있으므로, 플러그인 경계([AfmApi])를 가짜로 갈아 끼우고
// **앱이 기대하는 모양으로 번역되는지**만 본다: 본문·도구 호출·usage·오류.
import 'dart:async';

import 'package:afm_bridge/afm_bridge.dart';
import 'package:collabo_ide/src/llm/apple_foundation_client.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAfm implements AfmApi {
  _FakeAfm({
    this.chunks = const [],
    this.available = true,
    this.reason,
    this.error,
  });

  final List<Map<String, dynamic>> chunks;
  final bool available;
  final String? reason;
  final Object? error;

  /// 마지막으로 보낸 요청과 configure 인자(무엇이 넘어갔는지 확인용).
  Map<String, dynamic>? request;
  final List<Map<String, Object?>> configures = [];
  int prewarms = 0;

  @override
  Future<AfmStatus> status() async => AfmStatus.fromJson({
        'available': available,
        'reason': reason,
        'message': available ? 'ready' : 'Apple Intelligence is off',
        'message_ko': available ? '사용할 수 있습니다' : 'Apple Intelligence 가 꺼져 있습니다',
        'context_size': 4096,
        'supported_languages': ['ko', 'en'],
        'os_version': '26.4',
        'model_version': '2',
        'model_name': 'Apple Foundation Model v2',
      });

  @override
  Future<void> configure({
    bool? permissiveGuardrails,
    bool? trimHistory,
    int? maxConcurrentRequests,
  }) async =>
      configures.add({
        'permissiveGuardrails': permissiveGuardrails,
        'trimHistory': trimHistory,
        'maxConcurrentRequests': maxConcurrentRequests,
      });

  @override
  Future<void> prewarm() async => prewarms++;

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> req) {
    request = req;
    if (error != null) return Stream<Map<String, dynamic>>.error(error!);
    return Stream<Map<String, dynamic>>.fromIterable(chunks);
  }
}

Map<String, dynamic> _content(String text) => {
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    };

const _cfg = LlmConfig(connection: LlmConnection.appleFoundation);

const _tools = [
  {
    'type': 'function',
    'function': {'name': 'read_file', 'description': 'read', 'parameters': {}},
  },
];

Future<List<LlmEvent>> _collect(Stream<LlmEvent> s) => s.toList();

void main() {
  test('설정만 고르면 쓸 수 있다(주소·키·모델 이름이 없다)', () {
    expect(_cfg.isConfigured, isTrue);
    expect(_cfg.effectiveModel, 'apple-on-device');
    expect(connectionUsesNetwork(LlmConnection.appleFoundation), isFalse);
  });

  test('본문과 usage 를 앱 이벤트로 옮긴다', () async {
    final api = _FakeAfm(chunks: [
      _content('안녕'),
      _content('하세요'),
      {
        'choices': [],
        'usage': {'prompt_tokens': 12, 'completion_tokens': 3, 'total_tokens': 15},
      },
    ]);
    final events = await _collect(
        AppleFoundationClient(api: api).streamChat(cfg: _cfg, messages: const []));

    expect(events.whereType<LlmContent>().map((e) => e.text).join(), '안녕하세요');
    final usage = events.whereType<LlmUsage>().single;
    expect(usage.prompt, 12);
    expect(usage.total, 15);
  });

  test('네이티브 tool_calls 는 조각을 합쳐 돌려준다', () async {
    final api = _FakeAfm(chunks: [
      {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'function': {'name': 'read_file', 'arguments': '{"path":'},
                },
              ],
            },
          },
        ],
      },
      {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': '"a.md"}'},
                },
              ],
            },
          },
        ],
      },
    ]);
    final events = await _collect(AppleFoundationClient(api: api)
        .streamChat(cfg: _cfg, messages: const [], tools: _tools));

    final call = events.whereType<LlmToolCalls>().single.calls.single;
    expect(call.id, 'call_1');
    expect(call.name, 'read_file');
    expect(call.arguments, '{"path":"a.md"}');
    expect(api.request!['tools'], isNotNull, reason: '기본은 네이티브 — tools 를 그대로 넘긴다');
  });

  test('프롬프트 주입 모드: 도구를 system 에 넣고 본문에서 호출을 읽는다', () async {
    final api = _FakeAfm(chunks: [
      _content('생각 중… <tool_call>{"name": "read_file", "arguments": {"path": "a.md"}}</tool_call>'),
    ]);
    final cfg = _cfg.copyWith(afmPromptedTools: true);
    final events = await _collect(AppleFoundationClient(api: api)
        .streamChat(cfg: cfg, messages: const [], tools: _tools));

    expect(api.request!['tools'], isNull, reason: '프롬프트로 넣었으니 tools 는 안 보낸다');
    final system = (api.request!['messages'] as List).first as Map;
    expect(system['role'], 'system');
    expect('${system['content']}', contains('read_file'));
    final call = events.whereType<LlmToolCalls>().single.calls.single;
    expect(call.name, 'read_file');
    expect(events.whereType<LlmContent>().map((e) => e.text).join(), contains('생각 중'));
  });

  test('연결 확인: 쓸 수 없으면 이유를 돌려주고, 쓸 수 있으면 설정을 반영한다', () async {
    final off = _FakeAfm(available: false, reason: 'appleIntelligenceNotEnabled');
    final r1 = await AppleFoundationClient(api: off).test(_cfg);
    expect(r1.ok, isFalse);
    expect(r1.message, contains('appleIntelligenceNotEnabled'));
    expect(off.prewarms, 0, reason: '쓸 수 없으면 미리 올리지 않는다');

    final on = _FakeAfm();
    final cfg = _cfg.copyWith(afmMaxConcurrent: 2, afmPermissiveGuardrails: true);
    final r2 = await AppleFoundationClient(api: on).test(cfg);
    expect(r2.ok, isTrue);
    expect(r2.message, contains('4096'), reason: '컨텍스트 크기를 알려 준다');
    expect(r2.message, contains('AFM 2'), reason: '모델 세대를 알려 준다');
    expect(on.prewarms, 1);
    expect(on.configures.single['maxConcurrentRequests'], 2);
    expect(on.configures.single['permissiveGuardrails'], isTrue);
  });

  test('엔진 설정은 값이 바뀔 때만 다시 보낸다(부를 때마다 엔진이 새로 만들어진다)', () async {
    final api = _FakeAfm();
    final client = AppleFoundationClient(api: api);
    await _collect(client.streamChat(cfg: _cfg, messages: const []));
    await _collect(client.streamChat(cfg: _cfg, messages: const []));
    expect(api.configures, hasLength(1));

    await _collect(client.streamChat(
        cfg: _cfg.copyWith(afmPermissiveGuardrails: false), messages: const []));
    expect(api.configures, hasLength(2));
  });

  test('플러그인 오류는 코드와 함께 올라온다', () async {
    final api = _FakeAfm(
        error: const AfmBridgeException(message: 'too long', code: 'context_length_exceeded'));
    final client = AppleFoundationClient(api: api);
    expect(
      () => _collect(client.streamChat(cfg: _cfg, messages: const [])),
      throwsA(isA<AfmBridgeException>()),
    );
    // 연결 확인에서는 사람이 읽을 한 줄로 바뀐다.
    final r = await client.test(_cfg);
    expect(r.ok, isTrue, reason: 'status 는 따로다 — 스트림 오류와 섞이지 않는다');
  });
}
