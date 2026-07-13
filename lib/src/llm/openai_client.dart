import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_config.dart';
import 'llm_provider.dart';
import 'tool_call_parser.dart';

// 중립 타입(LlmEvent/ToolCall/LlmTestResult/LlmProvider)은 llm_provider.dart 에
// 정의돼 있다. 기존 import 경로 호환을 위해 여기서 다시 내보낸다.
export 'llm_provider.dart';

/// OpenAI 호환 Chat Completions 클라이언트(스트리밍 + function calling).
class OpenAiClient implements LlmProvider {
  OpenAiClient({http.Client? client})
      : _injected = client,
        _client = client ?? http.Client();

  /// 테스트에서 주입한 클라이언트(있으면 streamChat 도 이걸 재사용한다).
  final http.Client? _injected;
  final http.Client _client;

  Map<String, String> _headers(LlmConfig cfg) => {
        'Content-Type': 'application/json',
        if (cfg.apiKey.isNotEmpty) 'Authorization': 'Bearer ${cfg.apiKey}',
      };

  String _base(LlmConfig cfg) => cfg.baseUrl.endsWith('/')
      ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
      : cfg.baseUrl;

  /// 연결 상태 확인: `GET {baseUrl}/models`.
  @override
  Future<LlmTestResult> test(LlmConfig cfg) async {
    if (cfg.baseUrl.isEmpty) return const LlmTestResult(false, 'URL is empty.');
    try {
      final resp = await _client
          .get(Uri.parse('${_base(cfg)}/models'), headers: _headers(cfg))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) return const LlmTestResult(true, 'Connected');
      return LlmTestResult(false, 'HTTP ${resp.statusCode}: ${_short(resp.body)}');
    } catch (e) {
      return LlmTestResult(false, 'Connection failed: $e');
    }
  }

  /// Chat Completions 스트리밍. [messages] 는 OpenAI 메시지 객체 리스트(raw),
  /// [tools] 는 function-calling tool 스키마 리스트(없으면 미전송).
  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) async* {
    // 매 요청마다 새 클라이언트를 쓰고 끝나면 닫는다. keep-alive 연결을 재사용하면
    // 이전 턴에서 남은(죽은) 연결로 요청이 나가 서버에 도달하지 못하고 멈추는
    // 문제가 있어, 연결 재사용을 피한다(첫 요청만 되고 다음이 멈추는 증상 방지).
    // 단, 테스트에서 주입한 클라이언트가 있으면 그걸 그대로 쓴다(닫지 않음).
    final client = _injected ?? http.Client();
    try {
      final req =
          http.Request('POST', Uri.parse('${_base(cfg)}/chat/completions'));
      req.headers.addAll(_headers(cfg));
      req.headers['Connection'] = 'close';
      req.body = jsonEncode({
        'model': cfg.model,
        'stream': true,
        'stream_options': {'include_usage': true},
        'messages': messages,
        // 설정에서 선택한 경우에만 추론 강도를 전달(빈 값이면 미전송).
        if (cfg.reasoningEffort.isNotEmpty)
          'reasoning_effort': cfg.reasoningEffort,
        if (tools != null && tools.isNotEmpty) ...{
          'tools': tools,
          'tool_choice': 'auto',
        },
      });

      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        throw Exception('HTTP ${resp.statusCode}: ${_short(body)}');
      }

      // 도구 호출은 index 별로 조각이 스트리밍되므로 누적해 합친다.
      final toolAcc = <int, Map<String, Object?>>{};

      // 폴백(옵션, 기본 off): OpenAI 호환이라며 tool_calls 를 못 채우고 도구 호출을
      // 본문 텍스트로 흘리는 별종 서버(일부 MLX/로컬) 대비. 설정에서 켜고
      // tools(→ 알려진 이름)가 있을 때만 본문을 파서에 통과시켜 마커를 가려낸다.
      // 표준 서버는 스캔 오버헤드가 없도록 기본적으로 비활성. 네이티브 tool_calls 우선.
      final knownNames = knownToolNames(tools);
      final parser = (cfg.parseTextToolCalls && knownNames != null)
          ? PromptedToolParser(knownNames: knownNames)
          : null;

      final lines =
          resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;

        final Map<String, dynamic> json;
        try {
          json = jsonDecode(data) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }

        final choices = json['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final delta = (choices.first as Map)['delta'] as Map?;
          if (delta != null) {
            final content = delta['content'];
            if (content is String && content.isNotEmpty) {
              if (parser != null) {
                // 도구 호출 마커는 가리고, 그 밖의 텍스트만 흘린다.
                final visible = parser.add(content);
                if (visible.isNotEmpty) yield LlmContent(visible);
              } else {
                yield LlmContent(content);
              }
            }
            final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
            if (reasoning is String && reasoning.isNotEmpty) {
              yield LlmReasoning(reasoning);
            }
            _accumulateToolCalls(delta['tool_calls'], toolAcc);
          }
        }

        final usage = json['usage'] as Map?;
        if (usage != null) {
          yield LlmUsage(
            prompt: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
            completion: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
            total: (usage['total_tokens'] as num?)?.toInt() ?? 0,
          );
        }
      }

      // 파서를 썼다면 버퍼에 남은 텍스트를 반드시 흘린다(홀드백 유실 방지).
      if (parser != null) {
        final tail = parser.finish();
        if (tail.isNotEmpty) yield LlmContent(tail);
      }

      if (toolAcc.isNotEmpty) {
        // 네이티브 tool_calls 우선.
        final indices = toolAcc.keys.toList()..sort();
        yield LlmToolCalls([
          for (final i in indices)
            ToolCall(
              id: (toolAcc[i]!['id'] as String?) ?? 'call_$i',
              name: (toolAcc[i]!['name'] as String?) ?? '',
              arguments: (toolAcc[i]!['args'] as StringBuffer).toString(),
            ),
        ]);
        // 파서가 (오탐으로) 가린 게 있으면 텍스트로 되돌린다.
        final unparsed = parser?.unparsedAsText() ?? '';
        if (unparsed.isNotEmpty) yield LlmContent(unparsed);
      } else if (parser != null) {
        // 네이티브로 안 왔지만 본문 텍스트로 샌 도구 호출을 폴백으로 복원.
        final calls = parser.toolCalls();
        if (calls.isNotEmpty) yield LlmToolCalls(calls);
        final unparsed = parser.unparsedAsText();
        if (unparsed.isNotEmpty) yield LlmContent(unparsed);
      }
    } finally {
      if (_injected == null) client.close();
    }
  }

  void _accumulateToolCalls(Object? raw, Map<int, Map<String, Object?>> acc) {
    if (raw is! List) return;
    for (final tc in raw) {
      if (tc is! Map) continue;
      final idx = (tc['index'] as num?)?.toInt() ?? 0;
      final entry = acc.putIfAbsent(
        idx,
        () => {'id': null, 'name': null, 'args': StringBuffer()},
      );
      if (tc['id'] != null) entry['id'] = tc['id'];
      final fn = tc['function'];
      if (fn is Map) {
        if (fn['name'] != null) entry['name'] = fn['name'];
        if (fn['arguments'] is String) {
          (entry['args'] as StringBuffer).write(fn['arguments']);
        }
      }
    }
  }

  static String _short(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;

  @override
  void dispose() => _client.close();
}
