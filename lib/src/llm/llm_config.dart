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
    this.firstResponseTimeoutSec = defaultFirstResponseTimeoutSec,
  });

  /// [firstResponseTimeoutSec] 기본값(초). 예전에는 5분 고정이었는데, 로컬 모델은
  /// 큰 컨텍스트의 **프리필**만으로 그보다 오래 걸리는 일이 흔해 늘렸다.
  static const int defaultFirstResponseTimeoutSec = 600;

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

  /// 첫 응답(**프리필**) 대기 시간(초). 요청을 보낸 뒤 **첫 이벤트**가 이 시간 안에
  /// 오지 않으면 끊고 재시도한다. 이벤트가 하나라도 오면 타이머는 **해제**되어,
  /// 그 뒤로는 아무리 오래 걸려도 시간으로 끊지 않는다(§note 2026-08-13).
  ///
  /// **0 이면 제한 없음** — 프리필이 아무리 오래 걸려도 기다린다(중지는 언제든 가능).
  /// 서버마다 속도가 다르므로 앱 전역이 아니라 **연결(프리셋)별** 값이다.
  final int firstResponseTimeoutSec;

  /// 첫 응답 대기 시간. `0` 이하면 **제한 없음**(null).
  Duration? get firstResponseTimeout => firstResponseTimeoutSec > 0
      ? Duration(seconds: firstResponseTimeoutSec)
      : null;

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;

  LlmConfig copyWith({
    LlmConnection? connection,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? multimodal,
    String? reasoningEffort,
    bool? parseTextToolCalls,
    int? firstResponseTimeoutSec,
  }) =>
      LlmConfig(
        connection: connection ?? this.connection,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
        multimodal: multimodal ?? this.multimodal,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        parseTextToolCalls: parseTextToolCalls ?? this.parseTextToolCalls,
        firstResponseTimeoutSec:
            firstResponseTimeoutSec ?? this.firstResponseTimeoutSec,
      );

  Map<String, Object?> toJson() => {
        'connection': connection.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'multimodal': multimodal,
        'reasoningEffort': reasoningEffort,
        'parseTextToolCalls': parseTextToolCalls,
        'firstResponseTimeoutSec': firstResponseTimeoutSec,
      };

  factory LlmConfig.fromJson(Map<String, Object?> json) => LlmConfig(
        connection: _connFromName(json['connection'] as String?),
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        model: (json['model'] as String?) ?? '',
        multimodal: (json['multimodal'] as bool?) ?? false,
        reasoningEffort: (json['reasoningEffort'] as String?) ?? '',
        parseTextToolCalls: (json['parseTextToolCalls'] as bool?) ?? false,
        // 키가 없는 예전 설정은 기본값으로 읽는다(예전 동작은 5분 고정이었다).
        // 음수는 0(제한 없음)으로 정규화해 저장·표시가 흔들리지 않게 한다.
        firstResponseTimeoutSec: switch (json['firstResponseTimeoutSec']) {
          final num v => v.toInt() < 0 ? 0 : v.toInt(),
          _ => defaultFirstResponseTimeoutSec,
        },
      );
}
