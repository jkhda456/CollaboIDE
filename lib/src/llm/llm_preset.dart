import 'llm_config.dart';

/// 이름이 붙은 LLM 연결 프리셋. 여러 개를 미리 만들어 두고,
/// 프로젝트 대화 / 도구(run_subagent·verify_work)별로 골라 쓴다.
///
/// 메인 DB 설정(`llm_presets`)에 JSON 리스트로 저장된다. 식별자는 생성 시
/// 한 번 부여되고 바뀌지 않는다(프로젝트/도구 매핑이 id 로 참조하기 때문).
class LlmPreset {
  const LlmPreset({
    required this.id,
    required this.name,
    required this.config,
  });

  /// 안정적 식별자(프로젝트/도구 매핑의 참조 키).
  final String id;

  /// 사용자에게 보이는 이름(예: 'GPT-4o', '로컬 llama').
  final String name;

  /// 연결 설정(URL/키/모델/멀티모달/추론강도).
  final LlmConfig config;

  /// 표시용 이름(비어 있으면 모델명, 그것도 없으면 식별자 일부).
  String get label {
    if (name.trim().isNotEmpty) return name.trim();
    if (config.model.trim().isNotEmpty) return config.model.trim();
    return id;
  }

  LlmPreset copyWith({String? id, String? name, LlmConfig? config}) =>
      LlmPreset(
        id: id ?? this.id,
        name: name ?? this.name,
        config: config ?? this.config,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'config': config.toJson(),
      };

  factory LlmPreset.fromJson(Map<String, Object?> json) {
    final cfgRaw = json['config'];
    return LlmPreset(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      config: cfgRaw is Map
          ? LlmConfig.fromJson(Map<String, Object?>.from(cfgRaw))
          : const LlmConfig(),
    );
  }

  /// 새 식별자(시간 기반, 충돌 방지용 접미 카운터).
  static String newId() {
    final t = DateTime.now().microsecondsSinceEpoch;
    final n = _seq = (_seq + 1) & 0xffff;
    return 'p${t.toRadixString(36)}${n.toRadixString(36)}';
  }

  static int _seq = 0;
}
