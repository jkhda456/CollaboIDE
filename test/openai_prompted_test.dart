import 'dart:convert';

import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/openai_prompted_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 청크 리스트를 SSE 스트리밍 응답으로 만들어 주는 가짜 서버.
http.Client _sseClient(List<String> contentDeltas,
    {void Function(Map<String, Object?> body)? onRequest}) {
  return MockClient((req) async {
    if (req.url.path.endsWith('/models')) {
      return http.Response('{"data":[]}', 200);
    }
    onRequest?.call(jsonDecode(req.body) as Map<String, Object?>);
    final sb = StringBuffer();
    for (final d in contentDeltas) {
      sb.write('data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': d}
              }
            ]
          })}\n\n');
    }
    sb.write('data: ${jsonEncode({
          'choices': [],
          'usage': {'prompt_tokens': 3, 'completion_tokens': 5, 'total_tokens': 8}
        })}\n\n');
    sb.write('data: [DONE]\n\n');
    return http.Response(sb.toString(), 200,
        headers: {'content-type': 'text/event-stream'});
  });
}

void main() {
  const cfg = LlmConfig(
      connection: LlmConnection.openaiPrompted,
      baseUrl: 'http://x/v1',
      model: 'local');

  group('PromptedToolParser', () {
    test('도구 호출 블록을 본문에서 가려내고 ToolCall 로 추출', () {
      final p = PromptedToolParser();
      final visible = StringBuffer()
        ..write(p.add('Sure, reading.'))
        ..write(p.add('<tool_call>{"name":"read_file",'))
        ..write(p.add('"arguments":{"path":"a.txt"}}</tool_call>'))
        ..write(p.add(' done'))
        ..write(p.finish());
      expect(visible.toString(), 'Sure, reading. done');
      final calls = p.toolCalls();
      expect(calls, hasLength(1));
      expect(calls.first.name, 'read_file');
      expect(jsonDecode(calls.first.arguments), {'path': 'a.txt'});
    });

    test('델타 경계에 마커가 걸쳐도 안전(부분 마커 홀드백)', () {
      final p = PromptedToolParser();
      final out = StringBuffer();
      // 여는 태그가 두 청크에 쪼개져 들어온다.
      out.write(p.add('hi <tool'));
      out.write(p.add('_call>{"name":"x","arguments":{}}</tool_call>'));
      out.write(p.finish());
      expect(out.toString(), 'hi ');
      expect(p.toolCalls().single.name, 'x');
    });

    test('닫히지 않은 블록은 도구가 아니라 텍스트로 복원(유실 방지)', () {
      final p = PromptedToolParser();
      final out = StringBuffer()
        ..write(p.add('text <tool_call>{"name":"x"'))
        ..write(p.finish());
      expect(out.toString(), 'text <tool_call>{"name":"x"');
      expect(p.toolCalls(), isEmpty);
    });

    test('태그 안 마크다운 코드펜스도 벗겨서 파싱', () {
      final p = PromptedToolParser();
      p.add('<tool_call>\n```json\n{"name":"run","arguments":{"cmd":"ls"}}\n```\n</tool_call>');
      p.finish();
      final c = p.toolCalls().single;
      expect(c.name, 'run');
      expect(jsonDecode(c.arguments), {'cmd': 'ls'});
    });

    test('MLX 형식: <|tool_call>call:ns:name{느슨한 args}<tool_call|>', () {
      // 비대칭 마커 + call: 접두어 + 네임스페이스 이름 + 따옴표 없는 키/작은따옴표 값.
      final p = PromptedToolParser(knownNames: {'read_file'});
      final visible = StringBuffer()
        ..write(p.add('Reading '))
        ..write(p.add("<|tool_call>call:collabo_ide:read_file{path:'test.py'}"))
        ..write(p.add('<tool_call|> ok'))
        ..write(p.finish());
      expect(visible.toString(), 'Reading  ok');
      final c = p.toolCalls().single;
      // 네임스페이스(collabo_ide:)는 벗겨져 알려진 이름으로 정규화.
      expect(c.name, 'read_file');
      expect(jsonDecode(c.arguments), {'path': 'test.py'});
    });

    test('MLX 비대칭 마커가 델타 경계에 쪼개져도 안전', () {
      final p = PromptedToolParser(knownNames: {'run_command'});
      final out = StringBuffer()
        ..write(p.add('go <|tool'))
        ..write(p.add("_call>call:run_command{cmd:'ls -al', n:2}<tool_c"))
        ..write(p.add('all|> end'))
        ..write(p.finish());
      expect(out.toString(), 'go  end');
      final c = p.toolCalls().single;
      expect(c.name, 'run_command');
      expect(jsonDecode(c.arguments), {'cmd': 'ls -al', 'n': 2});
    });

    test('알려지지 않은 이름은 도구로 인정하지 않고 텍스트로 복원', () {
      final p = PromptedToolParser(knownNames: {'read_file'});
      final visible = StringBuffer()
        ..write(p.add('<|tool_call>call:evil_tool{}<tool_call|>'))
        ..write(p.finish());
      expect(p.toolCalls(), isEmpty);
      // 가려졌던 블록이 원래 마커째 텍스트로 되돌아온다(유실 방지).
      expect(visible.toString() + p.unparsedAsText(),
          '<|tool_call>call:evil_tool{}<tool_call|>');
    });
  });

  group('translateMessages', () {
    test('tool 역할 → user 평문, assistant.tool_calls → 텍스트 호출', () {
      final out = translateMessages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'hi'},
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'id': 'c1',
              'type': 'function',
              'function': {'name': 'read_file', 'arguments': '{"path":"a"}'}
            }
          ]
        },
        {'role': 'tool', 'tool_call_id': 'c1', 'content': 'file body'},
      ]);
      expect(out[0]['role'], 'system');
      expect(out[1]['role'], 'user');
      // assistant 호출이 <tool_call> 텍스트로.
      expect(out[2]['role'], 'assistant');
      expect((out[2]['content'] as String).contains('<tool_call>'), isTrue);
      expect((out[2]['content'] as String).contains('read_file'), isTrue);
      // tool 결과는 user 평문으로.
      expect(out[3]['role'], 'user');
      expect((out[3]['content'] as String).contains('file body'), isTrue);
      expect((out[3]['content'] as String).contains('c1'), isTrue);
    });
  });

  group('buildToolSystemPrompt', () {
    test('도구 이름/설명/스키마를 담는다', () {
      final s = buildToolSystemPrompt([
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'description': 'Read a file',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'}
              }
            }
          }
        }
      ]);
      expect(s.contains('read_file'), isTrue);
      expect(s.contains('Read a file'), isTrue);
      expect(s.contains('<tool_call>'), isTrue);
      expect(s.contains('"properties"'), isTrue);
    });
  });

  group('OpenAiPromptedClient.streamChat', () {
    test('tools 를 보내지 않고 시스템 프롬프트로 주입, 본문에서 도구 호출 파싱', () async {
      Map<String, Object?>? sent;
      final client = OpenAiPromptedClient(
          client: _sseClient([
        'Working ',
        '<tool_call>{"name":"read_file","arguments":{"path":"a"}}</tool_call>',
      ], onRequest: (b) => sent = b));

      final events = await client.streamChat(
        cfg: cfg,
        messages: [
          {'role': 'user', 'content': 'read a'}
        ],
        tools: [
          {
            'type': 'function',
            'function': {'name': 'read_file', 'description': 'Read', 'parameters': {}}
          }
        ],
      ).toList();

      // 요청 본문엔 tools 가 없어야 하고, 시스템 프롬프트가 주입돼야 한다.
      expect(sent!.containsKey('tools'), isFalse);
      final msgs = (sent!['messages'] as List).cast<Map>();
      expect(msgs.first['role'], 'system');
      expect((msgs.first['content'] as String).contains('read_file'), isTrue);

      // 보이는 텍스트엔 도구 블록이 없어야 한다.
      final text = events
          .whereType<LlmContent>()
          .map((e) => e.text)
          .join();
      expect(text.contains('<tool_call>'), isFalse);
      expect(text.trim(), 'Working');

      // 도구 호출이 방출돼야 한다.
      final toolEvents = events.whereType<LlmToolCalls>().toList();
      expect(toolEvents, hasLength(1));
      expect(toolEvents.first.calls.single.name, 'read_file');
    });
  });
}
