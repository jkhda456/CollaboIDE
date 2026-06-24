/// LLM 연결 방식. 지금은 OpenAI 호환 API 만. (추후: 자체 런쳐)
enum LlmConnection { openai }

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
  });

  /// 연결 방식(OpenAI 호환 등).
  final LlmConnection connection;

  /// API 베이스 URL (예: https://api.openai.com/v1).
  final String baseUrl;

  /// API 키(Bearer). 로컬 서버 등은 비어 있을 수 있다.
  final String apiKey;

  /// 사용할 모델 이름(예: gpt-4o-mini).
  final String model;

  bool get isConfigured => baseUrl.isNotEmpty && model.isNotEmpty;

  LlmConfig copyWith({
    LlmConnection? connection,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) =>
      LlmConfig(
        connection: connection ?? this.connection,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  Map<String, Object?> toJson() => {
        'connection': connection.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
      };

  factory LlmConfig.fromJson(Map<String, Object?> json) => LlmConfig(
        connection: _connFromName(json['connection'] as String?),
        baseUrl: (json['baseUrl'] as String?) ?? '',
        apiKey: (json['apiKey'] as String?) ?? '',
        model: (json['model'] as String?) ?? '',
      );
}
