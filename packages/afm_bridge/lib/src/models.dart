/// 모델 상태.
class AfmStatus {
  const AfmStatus({
    required this.available,
    required this.reason,
    required this.message,
    required this.messageKo,
    required this.contextSize,
    required this.supportedLanguages,
    required this.osVersion,
    this.modelVersion,
    this.modelVariant,
    this.modelName,
  });

  factory AfmStatus.fromJson(Map<String, dynamic> json) => AfmStatus(
        available: json['available'] as bool? ?? false,
        reason: AfmUnavailableReason.parse(json['reason'] as String?),
        message: json['message'] as String? ?? '',
        messageKo: json['message_ko'] as String? ?? '',
        contextSize: json['context_size'] as int?,
        supportedLanguages: (json['supported_languages'] as List?)?.cast<String>() ?? const [],
        osVersion: json['os_version'] as String? ?? '',
        modelVersion: json['model_version'] as String?,
        modelVariant: json['model_variant'] as String?,
        modelName: json['model_name'] as String?,
      );

  final bool available;

  /// 사용할 수 없는 이유 (available 이면 null)
  final AfmUnavailableReason? reason;

  /// 사람이 읽을 안내 문구 (영/한)
  final String message;
  final String messageKo;
  final int? contextSize;
  final List<String> supportedLanguages;
  final String osVersion;

  /// 모델 세대: '2'(iOS/macOS 26.4+), '3'(27+). OS 미지원이면 null.
  final String? modelVersion;

  /// 27+ 에서 시스템이 고른 변형: 'core3'(3B) · 'coreAdvanced3'(20B sparse, 더 큰 컨텍스트). 26 은 null.
  final String? modelVariant;

  /// 사람이 읽을 모델 이름(예: 'Apple Foundation Model v2').
  final String? modelName;

  /// 짧은 표시용 라벨(예: 'AFM 2', 'AFM 3 Core Advanced').
  String? get modelLabel => switch ((modelVersion, modelVariant)) {
        (null, _) => null,
        (final v?, 'coreAdvanced3') => 'AFM $v Core Advanced',
        (final v?, 'core3') => 'AFM $v Core',
        (final v?, _) => 'AFM $v',
      };

  @override
  String toString() =>
      'AfmStatus(available: $available, reason: ${reason?.name}, contextSize: $contextSize, model: $modelLabel)';
}

enum AfmUnavailableReason {
  deviceNotEligible,
  appleIntelligenceNotEnabled,
  modelNotReady,

  /// iOS / macOS 26.4 미만
  unsupportedOS,
  unknown;

  static AfmUnavailableReason? parse(String? value) {
    if (value == null) return null;
    return AfmUnavailableReason.values.firstWhere((e) => e.name == value, orElse: () => AfmUnavailableReason.unknown);
  }
}

/// OpenAI 형식 에러.
class AfmBridgeException implements Exception {
  const AfmBridgeException({required this.message, this.status, this.type, this.code, this.param});

  factory AfmBridgeException.fromJson(Map<String, dynamic> json) {
    final error = (json['error'] as Map?)?.cast<String, dynamic>() ?? json;
    return AfmBridgeException(
      message: error['message'] as String? ?? 'Unknown error',
      status: error['status'] as int?,
      type: error['type'] as String?,
      code: error['code'] as String?,
      param: error['param'] as String?,
    );
  }

  final String message;

  /// HTTP 상태 코드에 해당하는 값 (400, 429, 503 …)
  final int? status;
  final String? type;

  /// 예: context_length_exceeded, content_filter, rate_limited, appleIntelligenceNotEnabled, cancelled
  final String? code;
  final String? param;

  @override
  String toString() => 'AfmBridgeException(${status ?? '-'} ${code ?? type}): $message';
}

/// OpenAI chat message 헬퍼.
abstract final class AfmMessage {
  static Map<String, dynamic> system(String content) => {'role': 'system', 'content': content};
  static Map<String, dynamic> user(String content) => {'role': 'user', 'content': content};
  static Map<String, dynamic> assistant(String content) => {'role': 'assistant', 'content': content};
  static Map<String, dynamic> tool(String toolCallId, String content) =>
      {'role': 'tool', 'tool_call_id': toolCallId, 'content': content};
}
