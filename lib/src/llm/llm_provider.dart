import 'dart:convert';

import 'package:http/http.dart' as http;

import 'llm_config.dart';
import 'openai_client.dart';
import 'openai_prompted_client.dart';

/// 응답 본문을 인코딩 문제 없이 문자열로 읽는다. 서버가 `charset=utf-8` 이라 해도
/// 실제 바이트가 깨져 있으면 http 의 `resp.body`(엄격 UTF-8)가 FormatException 을
/// 던진다. allowMalformed 로 최대한 복원해 예외를 막고, 비-ASCII 오류 메시지가
/// 깨지는 것도 방지한다(대부분의 JSON API 는 UTF-8).
String bodyText(http.Response resp) =>
    utf8.decode(resp.bodyBytes, allowMalformed: true);

/// API 키를 HTTP `Authorization` 헤더로 실을 수 있는지 검사한다. 헤더 값에 제어문자나
/// 비-ASCII 문자(붙여넣기 하다 섞인 공백/개행/한글/특수문자 등)가 있으면 dart:io 가
/// 요청 전송 시 **FormatException** 을 던진다. 그걸 미리 잡아 사용자에게 명확한
/// 메시지를 돌려주기 위한 검사다. 문제 없으면 null.
String? apiKeyHeaderError(String key) {
  for (var i = 0; i < key.length; i++) {
    final c = key.codeUnitAt(i);
    // 헤더 값에 안전한 범위: 출력 가능한 ASCII(0x20~0x7E)만 허용.
    if (c < 0x20 || c > 0x7e) {
      final hex = c.toRadixString(16).toUpperCase().padLeft(4, '0');
      return 'API key has an invalid character at position ${i + 1} (U+$hex). '
          'Only printable ASCII is allowed — check for spaces, line breaks, or '
          'non-ASCII characters pasted into the key.';
    }
  }
  return null;
}

/// 연결 상태 확인 결과.
class LlmTestResult {
  const LlmTestResult(this.ok, this.message);
  final bool ok;
  final String message;
}

/// 모델이 요청한 도구 호출 하나(네이티브 tool_calls 든 프롬프트 파싱이든 동일 형태).
class ToolCall {
  const ToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;

  /// JSON 문자열(부분 스트림을 합친 것).
  final String arguments;
}

/// 스트리밍 이벤트(provider 중립).
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

/// LLM 백엔드 추상화(래퍼). 앱은 이 인터페이스로만 LLM 과 통신하고,
/// 구체 구현(OpenAI 호환, 추후 Anthropic 등)은 이 아래에 붙는다.
///
/// 경계의 표준 포맷:
/// - 입력 [messages] 는 OpenAI 형태의 메시지 객체 리스트(raw),
///   [tools] 는 OpenAI 형태의 function-calling 스키마 리스트.
/// - 출력은 중립 [LlmEvent] 스트림.
/// OpenAI 가 아닌 provider 는 이 표준 포맷 ↔ 자기 네이티브 포맷을 내부에서 번역한다
/// (function calling 포함).
abstract interface class LlmProvider {
  /// 연결 상태 확인.
  Future<LlmTestResult> test(LlmConfig cfg);

  /// Chat 스트리밍 + function calling.
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  });

  /// 리소스 정리.
  void dispose();
}

/// 설정의 연결 방식([LlmConfig.connection])에 맞는 provider 를 만든다.
/// 새 백엔드를 추가할 땐 여기에 분기를 더한다.
LlmProvider createLlmProvider(LlmConnection connection, {http.Client? client}) {
  switch (connection) {
    case LlmConnection.openai:
      return OpenAiClient(client: client);
    case LlmConnection.openaiPrompted:
      return OpenAiPromptedClient(client: client);
  }
}
