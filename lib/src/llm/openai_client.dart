import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_config.dart';

/// 연결 상태 확인 결과.
class LlmTestResult {
  const LlmTestResult(this.ok, this.message);
  final bool ok;
  final String message;
}

/// 모델이 요청한 도구 호출 하나.
class ToolCall {
  const ToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;

  /// JSON 문자열(부분 스트림을 합친 것).
  final String arguments;
}

/// 스트리밍 이벤트.
sealed class LlmEvent {}

class LlmContent extends LlmEvent {
  LlmContent(this.text);
  final String text;
}

class LlmReasoning extends LlmEvent {
  LlmReasoning(this.text);
  final String text;
}

class LlmUsage extends LlmEvent {
  LlmUsage({required this.prompt, required this.completion, required this.total});
  final int prompt;
  final int completion;
  final int total;
}

/// 스트림 종료 시, 모델이 도구 호출을 요청했으면 방출된다.
class LlmToolCalls extends LlmEvent {
  LlmToolCalls(this.calls);
  final List<ToolCall> calls;
}

/// OpenAI 호환 Chat Completions 클라이언트(스트리밍 + function calling).
class OpenAiClient {
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
            if (content is String && content.isNotEmpty) yield LlmContent(content);
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

      if (toolAcc.isNotEmpty) {
        final indices = toolAcc.keys.toList()..sort();
        yield LlmToolCalls([
          for (final i in indices)
            ToolCall(
              id: (toolAcc[i]!['id'] as String?) ?? 'call_$i',
              name: (toolAcc[i]!['name'] as String?) ?? '',
              arguments: (toolAcc[i]!['args'] as StringBuffer).toString(),
            ),
        ]);
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

  void dispose() => _client.close();
}
