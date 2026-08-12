import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_config.dart';
import 'llm_provider.dart';
import 'tool_call_parser.dart';

export 'llm_provider.dart';
export 'tool_call_parser.dart' show PromptedToolParser, ToolMarker;

/// 도구 호출을 감싸는 태그(프롬프트 계약). 본문 스트림에서 이 사이를 도구 호출로 본다.
const String _openTag = '<tool_call>';
const String _closeTag = '</tool_call>';

/// OpenAI 호환 API 지만 **네이티브 function calling 을 못 쓰는** 백엔드용 provider.
///
/// 차이점(OpenAI 표준 ↔ 이 백엔드 번역은 전부 내부에서 처리):
/// - 요청에 `tools`/`tool_choice` 를 보내지 않는다. 대신 도구 설명을 **시스템
///   프롬프트로 주입**하고, 모델이 `<tool_call>{json}</tool_call>` 형태로 답하게 한다.
/// - 응답 본문(content)에서 그 블록을 파싱해 [LlmToolCalls] 로 방출한다(사용자에게는
///   감춰진다). 블록 밖의 텍스트만 [LlmContent] 로 흘린다.
/// - 들어온 OpenAI 형태의 `tool`/`assistant.tool_calls` 메시지는 평문으로 역번역한다
///   (로컬 서버가 `role:"tool"` 을 모를 수 있으므로).
class OpenAiPromptedClient implements LlmProvider {
  OpenAiPromptedClient({http.Client? client})
      : _injected = client,
        _client = client ?? http.Client();

  final http.Client? _injected;
  final http.Client _client;

  Map<String, String> _headers(LlmConfig cfg) => {
        'Content-Type': 'application/json',
        if (cfg.apiKey.isNotEmpty) 'Authorization': 'Bearer ${cfg.apiKey}',
      };

  String _base(LlmConfig cfg) => cfg.baseUrl.endsWith('/')
      ? cfg.baseUrl.substring(0, cfg.baseUrl.length - 1)
      : cfg.baseUrl;

  @override
  Future<LlmTestResult> test(LlmConfig cfg) async {
    if (cfg.baseUrl.isEmpty) return const LlmTestResult(false, 'URL is empty.');
    final uri = Uri.tryParse('${_base(cfg)}/models');
    if (uri == null) return const LlmTestResult(false, 'Invalid URL.');
    // 헤더에 실을 수 없는 문자가 키에 있으면 전송 시 FormatException 이 나므로 미리 안내.
    final keyErr = apiKeyHeaderError(cfg.apiKey);
    if (keyErr != null) return LlmTestResult(false, keyErr);
    try {
      final resp = await _client
          .get(uri, headers: _headers(cfg))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) return const LlmTestResult(true, 'Connected');
      return LlmTestResult(
          false, 'HTTP ${resp.statusCode}: ${_short(bodyText(resp))}');
    } catch (e) {
      return LlmTestResult(false, 'Connection failed: $e');
    }
  }

  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) async* {
    // 키에 헤더로 못 실을 문자가 있으면 전송 시 FormatException 이 나므로 미리 막고 안내.
    final keyErr = apiKeyHeaderError(cfg.apiKey);
    if (keyErr != null) throw Exception(keyErr);
    final client = _injected ?? http.Client();
    try {
      final hasTools = tools != null && tools.isNotEmpty;
      // tool/assistant.tool_calls 메시지를 평문으로 역번역.
      final outMessages = translateMessages(messages);
      if (hasTools) {
        final toolPrompt = buildToolSystemPrompt(tools);
        // system 메시지를 맨 앞 1개만 반영하는 로컬 서버를 위해, 기존 첫 system
        // 메시지가 있으면 거기에 병합하고 없으면 맨 앞에 새로 넣는다.
        if (outMessages.isNotEmpty && outMessages.first['role'] == 'system') {
          final existing = outMessages.first['content'];
          outMessages[0] = {
            'role': 'system',
            'content': '${existing is String ? existing : ''}\n\n$toolPrompt'
                .trimLeft(),
          };
        } else {
          outMessages.insert(0, {'role': 'system', 'content': toolPrompt});
        }
      }

      final req =
          http.Request('POST', Uri.parse('${_base(cfg)}/chat/completions'));
      req.headers.addAll(_headers(cfg));
      req.headers['Connection'] = 'close';
      req.body = jsonEncode({
        'model': cfg.model,
        'stream': true,
        'stream_options': {'include_usage': true},
        'messages': outMessages,
        if (cfg.reasoningEffort.isNotEmpty)
          'reasoning_effort': cfg.reasoningEffort,
        // tools/tool_choice 는 보내지 않는다(프롬프트로 대체).
      });

      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        // 엄격 utf8(bytesToString 기본)은 깨진 바이트에서 FormatException 을 던지므로
        // allowMalformed 로 안전하게 디코딩한다.
        final body = utf8.decode(await resp.stream.toBytes(), allowMalformed: true);
        throw Exception('HTTP ${resp.statusCode}: ${_short(body)}');
      }

      final parser = PromptedToolParser(knownNames: knownToolNames(tools));
      // 스트림 중간에 깨진 바이트가 와도 대화가 끊기지 않도록 관대한 디코더 사용.
      final lines = resp.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
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
              // 도구 호출 블록은 숨기고, 그 밖의 텍스트만 흘린다.
              final visible = parser.add(content);
              if (visible.isNotEmpty) yield LlmContent(visible);
            }
            final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
            if (reasoning is String && reasoning.isNotEmpty) {
              yield LlmReasoning(reasoning);
            }
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

      final tail = parser.finish();
      if (tail.isNotEmpty) yield LlmContent(tail);

      final calls = parser.toolCalls();
      if (calls.isNotEmpty) yield LlmToolCalls(calls);
      // 도구로 인정 못 한(파싱 실패/미지 이름) 블록은 유실 방지를 위해 텍스트로 복원.
      final unparsed = parser.unparsedAsText();
      if (unparsed.isNotEmpty) yield LlmContent(unparsed);
    } finally {
      if (_injected == null) client.close();
    }
  }

  static String _short(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;

  @override
  void dispose() => _client.close();
}

/// 도구 목록(OpenAI 스키마)을 모델이 이해할 시스템 프롬프트로 만든다.
String buildToolSystemPrompt(List<Map<String, Object?>> tools) {
  final b = StringBuffer()
    ..writeln('You can use tools. To call a tool, output a single block exactly '
        'in this form and nothing else after it:')
    ..writeln('$_openTag{"name": "<tool_name>", "arguments": {<args>}}$_closeTag')
    ..writeln('Call at most one tool per message. After you receive the tool '
        'result, continue. If no tool is needed, answer normally without a '
        '$_openTag block.')
    ..writeln()
    ..writeln('Available tools:');
  for (final t in tools) {
    final fn = (t['function'] as Map?)?.cast<String, Object?>() ?? const {};
    final name = (fn['name'] as String?) ?? '';
    final desc = (fn['description'] as String?) ?? '';
    final params = fn['parameters'];
    b.writeln('- name: $name');
    if (desc.isNotEmpty) b.writeln('  description: $desc');
    if (params != null) b.writeln('  parameters (JSON Schema): ${jsonEncode(params)}');
  }
  return b.toString().trimRight();
}

/// OpenAI 형태의 메시지를, 도구를 모르는 백엔드도 이해할 평문으로 번역한다.
/// - `role:"tool"` → 도구 결과를 담은 `user` 메시지.
/// - `assistant` + `tool_calls` → 같은 호출을 `<tool_call>` 텍스트로 담은 `assistant` 메시지.
/// - 그 외 메시지는 그대로 둔다.
List<Map<String, Object?>> translateMessages(
    List<Map<String, Object?>> messages) {
  final out = <Map<String, Object?>>[];
  for (final m in messages) {
    final role = m['role'];
    if (role == 'tool') {
      final id = (m['tool_call_id'] as String?) ?? '';
      final content = m['content'];
      out.add({
        'role': 'user',
        'content': 'Tool result${id.isEmpty ? '' : ' ($id)'}:\n'
            '${content is String ? content : jsonEncode(content)}',
      });
      continue;
    }
    if (role == 'assistant' && m['tool_calls'] is List) {
      final calls = (m['tool_calls'] as List);
      final b = StringBuffer();
      final c = m['content'];
      if (c is String && c.isNotEmpty) b.writeln(c);
      for (final raw in calls) {
        if (raw is! Map) continue;
        final fn = (raw['function'] as Map?)?.cast<String, Object?>() ?? const {};
        final name = (fn['name'] as String?) ?? '';
        final args = fn['arguments'];
        // arguments 는 이미 JSON 문자열(예: '{"path":"x"}'). 그대로 끼워도 유효 JSON.
        final argText = args is String && args.trim().isNotEmpty ? args : '{}';
        b.writeln('$_openTag{"name": "$name", "arguments": $argText}$_closeTag');
      }
      out.add({'role': 'assistant', 'content': b.toString().trim()});
      continue;
    }
    out.add(m);
  }
  return out;
}
