/// 하나의 도구 정의(OpenAI function-calling tool 스키마).
class ToolDef {
  const ToolDef({
    required this.name,
    required this.description,
    required this.parameters,
    required this.raw,
  });

  final String name;
  final String description;
  final Map<String, Object?> parameters;

  /// OpenAI tools 배열에 그대로 넣을 수 있는 원본 스키마.
  final Map<String, Object?> raw;

  factory ToolDef.fromSchema(Map<String, Object?> schema) {
    final fn = (schema['function'] as Map?)?.cast<String, Object?>() ?? const {};
    return ToolDef(
      name: (fn['name'] as String?) ?? '',
      description: (fn['description'] as String?) ?? '',
      parameters: (fn['parameters'] as Map?)?.cast<String, Object?>() ?? const {},
      raw: schema,
    );
  }
}

/// 도구 모듈(기본 또는 사용자 추가). `describe` 결과로 구성된다.
class ToolModule {
  const ToolModule({
    required this.name,
    required this.version,
    required this.scriptPath,
    required this.isBase,
    required this.tools,
  });

  /// 모듈 식별자(describe 의 module 필드, 예: collabo_base).
  final String name;
  final String version;
  final String scriptPath;

  /// 고정 기본 모듈 여부(사용자가 제거할 수 없음).
  final bool isBase;
  final List<ToolDef> tools;

  factory ToolModule.fromDescribe(
    Map<String, Object?> json, {
    required String scriptPath,
    required bool isBase,
  }) {
    final rawTools = (json['tools'] as List?) ?? const [];
    return ToolModule(
      name: (json['module'] as String?) ?? 'module',
      version: (json['version'] as String?) ?? '',
      scriptPath: scriptPath,
      isBase: isBase,
      tools: rawTools
          .whereType<Map>()
          .map((t) => ToolDef.fromSchema(t.cast<String, Object?>()))
          .toList(),
    );
  }
}

/// 도구 호출 결과(`call` 응답).
class ToolCallResult {
  const ToolCallResult({
    required this.ok,
    this.result,
    this.error,
    this.needsElevation = false,
    this.reason,
  });

  final bool ok;
  final Object? result;
  final String? error;

  /// 관리자 권한 상승이 필요함(native 가 상승 후 재실행).
  final bool needsElevation;
  final String? reason;

  factory ToolCallResult.fromJson(Map<String, Object?> json) => ToolCallResult(
        ok: json['ok'] == true,
        result: json['result'],
        error: json['error'] as String?,
        needsElevation: json['needs_elevation'] == true,
        reason: json['reason'] as String?,
      );
}
