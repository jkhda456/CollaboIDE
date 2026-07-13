/// LLM 연결 방식.
/// - [openai]: OpenAI 호환 API, **네이티브** function calling(`tools`/`tool_calls`).
/// - [openaiPrompted]: OpenAI 호환 API 지만 도구를 **프롬프트로 주입**하고 응답
///   본문(content)에서 도구 호출을 파싱한다. tools 를 무시하거나 본문에 텍스트로
///   내뱉는 로컬 서버(Ollama/LM Studio/MLX 등)용 폴백.
enum LlmConnection { openai, openaiPrompted }

LlmConnection _connFromName(String? n) => LlmConnection.values.firstWhere(
      (c) => c.name == n,
      orElse: () => LlmConnection.openai,
    );

/// LLM 연결 설정. 메인 DB(설정)에 JSON 으로 저장된다.
class LlmConfig {
  const LlmConfig({
    this.connection = LlmConnection.openai,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.multimodal = false,
    this.reasoningEffort = '',
    this.parseTextToolCalls = false,
  });

  /// 연결 방식(OpenAI 호환 등).
  final LlmConnection connection;

  /// API 베이스 URL (예: https://api.openai.com/v1).
  final String baseUrl;

  /// API 키(Bearer). 로컬 서버 등은 비어 있을 수 있다.
  final String apiKey;

  /// 사용할 모델 이름(예: gpt-4o-mini).
  final String model;

  /// 멀티모달(이미지 입력) 지원 여부. 켜면 대화에서 + 버튼으로 이미지를 첨부할 수 있다.
  final bool multimodal;

  /// 추론 강도(`reasoning_effort`). 빈 문자열이면 미전송(요청에 포함하지 않음).
  /// 비어 있지 않으면(예: 'none'|'low'|'high') 요청 본문에 그대로 전달한다.
  final String reasoningEffort;

  /// 네이티브(`openai`) 연결에서, 서버가 `tool_calls` 를 못 채우고 도구 호출을 **본문
  /// 텍스트 마커**(`<tool_call>…`, `<|tool_call>…` 등)로 흘릴 때 그걸 파싱해 복원할지.
  ///
  /// **기본 off.** 표준 OpenAI 호환 서버는 본문을 스캔할 필요가 없으므로, 텍스트로
  /// 도구 호출을 흘리는 별종 서버(일부 MLX/로컬)를 `openai` 로 쓸 때만 켠다.
  /// (`openaiPrompted` 연결은 이 파싱이 본질이라 이 플래그와 무관하게 항상 동작.)
  final bool parseTextToolCalls;

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;

  LlmConfig copyWith({
    LlmConnection? connection,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? multimodal,
    String? reasoningEffort,
    bool? parseTextToolCalls,
  }) =>
      LlmConfig(
        connection: connection ?? this.connection,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        multimodal: multimodal ?? this.multimodal,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        parseTextToolCalls: parseTextToolCalls ?? this.parseTextToolCalls,
      );

  Map<String, Object?> toJson() => {
        'connection': connection.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'multimodal': multimodal,
        'reasoningEffort': reasoningEffort,
        'parseTextToolCalls': parseTextToolCalls,
      };

  factory LlmConfig.fromJson(Map<String, Object?> json) => LlmConfig(
        connection: _connFromName(json['connection'] as String?),
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        model: (json['model'] as String?) ?? '',
        multimodal: (json['multimodal'] as bool?) ?? false,
        reasoningEffort: (json['reasoningEffort'] as String?) ?? '',
        parseTextToolCalls: (json['parseTextToolCalls'] as bool?) ?? false,
      );
}
