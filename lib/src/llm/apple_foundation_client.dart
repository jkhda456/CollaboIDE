import 'dart:async';

import 'package:afm_bridge/afm_bridge.dart';
import 'package:flutter/foundation.dart';

import 'llm_config.dart';
import 'llm_provider.dart';
import 'openai_prompted_client.dart' show buildToolSystemPrompt, translateMessages;
import 'tool_call_parser.dart';

/// Apple Foundation Models(기기 안에서 도는 온디바이스 모델) 백엔드.
///
/// 네트워크가 없다 — `afm_bridge` 플러그인의 채널로 부른다. 요청·응답은 OpenAI Chat
/// Completions 모양이라 나머지 배관(메시지·도구·스트리밍)은 다른 연결과 같다.
///
/// **mac/iOS 전용.** 다른 플랫폼에서는 플러그인이 없어 채널 호출이 곧바로 실패한다 —
/// 설정 화면이 애초에 이 연결을 보여 주지 않는다([appleFoundationSupported]).
///
/// 지시문은 따로 두지 않는다 — **프롬프트 설정(시스템 프롬프트)** 이 다른 연결과 똑같이 `system`
/// 메시지로 들어간다. 엔진의 `defaultInstructions` 는 모든 요청(턴 요약·분류 같은 내부 호출까지)에
/// 붙고 4K 컨텍스트를 매번 차지하므로 쓰지 않는다(2026-09-23 설정 항목 제거).
///
/// 도구 호출은 두 갈래다:
///  - 기본: OpenAI 처럼 `tools` 를 그대로 넘기고 `tool_calls` 를 받는다.
///  - [LlmConfig.afmPromptedTools]: 도구를 **프롬프트로 주입**하고 본문에서 파싱한다
///    (`openaiPrompted` 와 같은 방식). 모델이 `tools` 를 무시할 때 쓴다.
class AppleFoundationClient implements LlmProvider {
  AppleFoundationClient({AfmApi? api}) : _api = api ?? const _PluginAfmApi();

  final AfmApi _api;

  /// 마지막으로 엔진에 넘긴 설정 — 같은 값이면 다시 부르지 않는다(엔진이 새로 만들어진다).
  String _configured = '';

  @override
  Future<LlmTestResult> test(LlmConfig cfg) async {
    try {
      await _applyConfig(cfg);
      final status = await _api.status();
      if (!status.available) {
        return LlmTestResult(false, _statusMessage(status));
      }
      if (cfg.afmPrewarm) await _api.prewarm();
      return LlmTestResult(true, _statusMessage(status));
    } catch (e) {
      return LlmTestResult(false, _errorText(e));
    }
  }

  /// 상태 한 줄: 사용 가능 여부 + 이유/컨텍스트 크기.
  static String _statusMessage(AfmStatus s) {
    final bits = <String>[
      if (s.message.isNotEmpty) s.message,
      if (s.modelLabel != null) 'model: ${s.modelLabel}',
      if (s.reason != null) 'reason: ${s.reason!.name}',
      if (s.contextSize != null) 'context: ${s.contextSize} tok',
      if (s.osVersion.isNotEmpty) 'OS ${s.osVersion}',
    ];
    return bits.isEmpty
        ? (s.available ? 'Apple Foundation Models is ready.' : 'Not available.')
        : bits.join(' · ');
  }

  /// 엔진 설정을 반영한다. `configure` 는 엔진을 새로 만들므로 **값이 바뀔 때만** 부른다.
  Future<void> _applyConfig(LlmConfig cfg) async {
    final sig = [
      cfg.afmPermissiveGuardrails,
      cfg.afmTrimHistory,
      cfg.afmMaxConcurrent,
    ].join('|');
    if (sig == _configured) return;
    await _api.configure(
      permissiveGuardrails: cfg.afmPermissiveGuardrails,
      trimHistory: cfg.afmTrimHistory,
      maxConcurrentRequests: cfg.afmMaxConcurrent > 0 ? cfg.afmMaxConcurrent : null,
    );
    _configured = sig;
  }

  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) async* {
    await _applyConfig(cfg);
    final hasTools = tools != null && tools.isNotEmpty;
    final prompted = cfg.afmPromptedTools;

    // 프롬프트 주입 모드: 도구 스키마를 system 에 넣고 tool 메시지를 평문으로 되돌린다.
    final outMessages = prompted ? translateMessages(messages) : messages;
    if (prompted && hasTools) {
      final toolPrompt = buildToolSystemPrompt(tools);
      if (outMessages.isNotEmpty && outMessages.first['role'] == 'system') {
        final existing = outMessages.first['content'];
        outMessages[0] = {
          'role': 'system',
          'content': '${existing is String ? existing : ''}\n\n$toolPrompt'.trimLeft(),
        };
      } else {
        outMessages.insert(0, {'role': 'system', 'content': toolPrompt});
      }
    }

    final request = <String, dynamic>{
      'messages': outMessages,
      if (!prompted && hasTools) 'tools': tools,
    };

    // 본문에서 도구 호출을 건지는 파서(다른 연결과 같은 것을 쓴다). 프롬프트 모드는
    // 항상 필요하고, 네이티브 모드에서는 설정(parseTextToolCalls)을 켰을 때만 쓴다.
    final parser = (prompted || cfg.parseTextToolCalls)
        ? PromptedToolParser(knownNames: knownToolNames(tools))
        : null;
    final native = _NativeToolCalls();

    await for (final chunk in _api.stream(request)) {
      final choices = chunk['choices'] as List?;
      if (choices != null && choices.isNotEmpty) {
        final first = choices.first;
        final delta = first is Map ? first['delta'] as Map? : null;
        final content = delta?['content'];
        if (content is String && content.isNotEmpty) {
          final visible = parser == null ? content : parser.add(content);
          if (visible.isNotEmpty) yield LlmContent(visible);
        }
        final reasoning = delta?['reasoning_content'] ?? delta?['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) yield LlmReasoning(reasoning);
        final calls = delta?['tool_calls'];
        if (calls is List) native.add(calls);
      }
      final usage = chunk['usage'];
      if (usage is Map) {
        yield LlmUsage(
          prompt: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
          completion: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
          total: (usage['total_tokens'] as num?)?.toInt() ?? 0,
        );
      }
    }

    // 꼬리 정리 → 도구 호출. **네이티브 tool_calls 가 우선**이고, 없으면 본문에서 건진 것.
    if (parser != null) {
      final tail = parser.finish();
      if (tail.isNotEmpty) yield LlmContent(tail);
    }
    final nativeCalls = native.result();
    final calls =
        nativeCalls.isNotEmpty ? nativeCalls : (parser?.toolCalls() ?? const <ToolCall>[]);
    if (calls.isNotEmpty) yield LlmToolCalls(calls);
    // 도구로 인정 못 한(파싱 실패·모르는 이름) 블록은 유실 방지를 위해 텍스트로 되돌린다.
    final unparsed = parser?.unparsedAsText() ?? '';
    if (unparsed.isNotEmpty) yield LlmContent(unparsed);
  }

  static String _errorText(Object e) {
    if (e is AfmBridgeException) {
      final code = e.code ?? e.type;
      return code == null ? e.message : '${e.message} ($code)';
    }
    return '$e';
  }

  @override
  void dispose() {}
}

/// 이 플랫폼에서 Apple Foundation Models 를 고를 수 있는가(mac/iOS 전용).
bool get appleFoundationSupported =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// 기기 모델의 상태(컨텍스트 창 크기 포함). 이 플랫폼에 없거나 실패하면 null.
/// 설정 화면이 컨텍스트 창을 자동으로 채우는 데 쓴다(26 은 4096, 27 의 큰 변형은 더 크다).
Future<AfmStatus?> appleFoundationStatus() async {
  if (!appleFoundationSupported) return null;
  try {
    return await AfmBridge.status();
  } catch (_) {
    return null;
  }
}

/// 스트리밍 chunk 로 쪼개져 오는 `tool_calls` 를 합친다(OpenAI 와 같은 모양).
class _NativeToolCalls {
  final Map<int, ({String id, String name, StringBuffer args})> _byIndex = {};

  void add(List<Object?> raw) {
    for (final entry in raw) {
      if (entry is! Map) continue;
      final index = (entry['index'] as num?)?.toInt() ?? 0;
      final fn = entry['function'] as Map?;
      final slot = _byIndex.putIfAbsent(
          index, () => (id: '', name: '', args: StringBuffer()));
      final id = entry['id'] as String?;
      final name = fn?['name'] as String?;
      final args = fn?['arguments'];
      if (args is String) slot.args.write(args);
      if ((id != null && id.isNotEmpty) || (name != null && name.isNotEmpty)) {
        _byIndex[index] = (
          id: id != null && id.isNotEmpty ? id : slot.id,
          name: name != null && name.isNotEmpty ? name : slot.name,
          args: slot.args,
        );
      }
    }
  }

  List<ToolCall> result() => [
        for (final e in _byIndex.entries)
          if (e.value.name.isNotEmpty)
            ToolCall(
              id: e.value.id.isEmpty ? 'afm_${e.key}' : e.value.id,
              name: e.value.name,
              arguments: e.value.args.toString(),
            ),
      ];
}

/// 플러그인 호출 경계. **시험이 갈아 끼우는 자리**다 — 채널은 mac/iOS 에서만 산다.
abstract interface class AfmApi {
  Future<AfmStatus> status();
  Future<void> configure({
    bool? permissiveGuardrails,
    bool? trimHistory,
    int? maxConcurrentRequests,
  });
  Future<void> prewarm();
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> request);
}

class _PluginAfmApi implements AfmApi {
  const _PluginAfmApi();

  @override
  Future<AfmStatus> status() => AfmBridge.status();

  @override
  Future<void> configure({
    bool? permissiveGuardrails,
    bool? trimHistory,
    int? maxConcurrentRequests,
  }) =>
      AfmBridge.configure(
        permissiveGuardrails: permissiveGuardrails,
        trimHistory: trimHistory,
        maxConcurrentRequests: maxConcurrentRequests,
      );

  @override
  Future<void> prewarm() => AfmBridge.prewarm();

  @override
  Stream<Map<String, dynamic>> stream(Map<String, dynamic> request) =>
      AfmBridge.chatCompletionsStream(request);
}
