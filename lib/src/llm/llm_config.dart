import 'stream_budget.dart' show kDefaultTokPerSec;

/// LLM 연결 방식.
/// - [openai]: OpenAI 호환 API, **네이티브** function calling(`tools`/`tool_calls`).
/// - [openaiPrompted]: OpenAI 호환 API 지만 도구를 **프롬프트로 주입**하고 응답
///   본문(content)에서 도구 호출을 파싱한다. tools 를 무시하거나 본문에 텍스트로
///   내뱉는 로컬 서버(Ollama/LM Studio/MLX 등)용 폴백.
/// - [appleFoundation]: **Apple Foundation Models**(기기 안에서 도는 온디바이스 모델).
///   네트워크가 아니라 플러그인 채널로 부른다(`afm_bridge`) — mac/iOS 에서만 보인다.
///   요청·응답 모양은 OpenAI 와 같아서 위 둘과 같은 배관을 그대로 쓴다.
enum LlmConnection { openai, openaiPrompted, appleFoundation }

/// 이 연결이 **네트워크 주소**를 쓰는가. Apple 온디바이스는 주소도 키도 없다.
bool connectionUsesNetwork(LlmConnection c) => c != LlmConnection.appleFoundation;

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
    this.responseTokenBudget = defaultResponseTokenBudget,
    this.speedTps = 0,
    this.measuredTps = 0,
    this.afmPromptedTools = false,
    this.afmPermissiveGuardrails = true,
    this.afmPrewarm = true,
    this.afmMaxConcurrent = 0,
    this.afmTrimHistory = true,
    this.contextWindow = 0,
    this.autoFitContext = true,
  });

  /// Apple 온디바이스 모델의 이름(고정). 사용자가 고를 것이 없다.
  static const String appleModel = 'apple-on-device';

  /// [firstResponseTimeoutSec] 기본값 — **0, 제한 없음**.
  ///
  /// 프리필 구간에서는 서버가 SSE 로 아무것도 내보내지 않는다. 즉 시계로는 "열심히
  /// 일하는 중" 과 "죽은 연결" 을 구분할 수 없다. 구분도 못 하면서 멀쩡한 작업을 죽이는
  /// 쪽이 훨씬 큰 피해라, 여기서는 **기다리는 쪽**을 기본으로 둔다(중지는 언제든 가능).
  /// 값을 넣으면 그 초만큼만 기다린다.
  static const int defaultFirstResponseTimeoutSec = 0;

  /// [responseTokenBudget] 기본값. "이 정도 토큰을 뽑을 시간" 이 한 응답의 상한이다.
  static const int defaultResponseTokenBudget = 90000;

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

  /// 첫 응답(**프리필**) 대기 시간(초). 요청을 보낸 뒤 **첫 이벤트**까지만 적용된다.
  /// **기본 0 = 제한 없음**([defaultFirstResponseTimeoutSec] 참고).
  ///
  /// 첫 이벤트가 오면 이 타이머는 해제되고, 그때부터는 [responseTokenBudget] 이
  /// 환산한 시간이 상한이 된다.
  final int firstResponseTimeoutSec;

  /// 응답 하나에 허용하는 **토큰 예산**. 시간 상한은 이걸 실측 속도로 나눠 정한다
  /// (`stream_budget.dart`). **0 이면 제한 없음.**
  ///
  /// 이 값이 무한 반복 출력을 잡는 장치다 — 같은 문자를 계속 뱉는 상태는 속도와
  /// 무관하게 예산을 태우므로 반드시 걸린다. 출력을 파싱할 필요가 없다.
  final int responseTokenBudget;

  /// 사용자가 지정한 처리 속도(tok/s). **0 이면 미지정** — 앱이 실측해서 쓴다.
  /// 값을 넣으면 실측보다 이게 우선한다(앱은 이 필드를 덮어쓰지 않는다).
  final double speedTps;

  /// 앱이 실제 응답에서 잰 속도(tok/s). 사용자 값이 없을 때 쓰이고,
  /// 재시작 후에도 첫 턴부터 맞는 상한을 쓰도록 프리셋에 저장된다. 0 이면 아직 없음.
  final double measuredTps;

  // --- Apple Foundation Models 전용 (connection == appleFoundation 일 때만 쓰인다) ---

  /// 도구를 **프롬프트로 주입**하고 본문에서 호출을 파싱한다([LlmConnection.openaiPrompted]
  /// 와 같은 방식). 온디바이스 모델이 `tools` 를 무시하거나 도구 호출이 안 나올 때 켠다.
  final bool afmPromptedTools;

  /// 기본 가드레일을 느슨하게(`permissiveGuardrails`). 플러그인 README 의 권고대로
  /// **기본 켬** — 기본 가드레일은 평범한 한국어 질문도 종종 막는다.
  final bool afmPermissiveGuardrails;

  /// 연결 확인·첫 요청 전에 모델을 미리 올린다(첫 응답 지연 감소).
  final bool afmPrewarm;

  /// 동시 요청 수 상한(`maxConcurrentRequests`). 0 이면 엔진 기본값.
  final int afmMaxConcurrent;

  /// 컨텍스트가 넘칠 때 엔진이 앞 대화를 잘라내게 한다(`trimHistory`).
  final bool afmTrimHistory;

  /// 모델의 컨텍스트 창(토큰). 0 = 모름(제한 없이 보낸다).
  /// Apple 온디바이스는 설정 화면이 기기에서 읽어 채운다([effectiveContextWindow] 참고).
  final int contextWindow;

  /// 작은 컨텍스트(≤16K)면 도구·프롬프트·보조 주입을 자동으로 줄여 창에 맞춘다(`ContextFit`).
  final bool autoFitContext;

  /// 실제로 쓸 컨텍스트 창. Apple 온디바이스가 아직 감지 전(0)이면 가장 작은 4096 으로 본다
  /// (macOS/iOS 26 의 창. 27 의 큰 변형은 감지되면 그 값을 쓴다).
  int get effectiveContextWindow =>
      contextWindow > 0 ? contextWindow : (connection == LlmConnection.appleFoundation ? 4096 : 0);

  /// 첫 응답 대기 시간. `0` 이하면 **제한 없음**(null).
  Duration? get firstResponseTimeout => firstResponseTimeoutSec > 0
      ? Duration(seconds: firstResponseTimeoutSec)
      : null;

  /// 저장된 값만으로 정한 속도(세션 실측은 `WorkspaceController` 가 얹는다).
  /// 사용자 지정 → 저장된 실측 → 기본값 순.
  double get storedTps => speedTps > 0
      ? speedTps
      : (measuredTps > 0 ? measuredTps : kDefaultTokPerSec);

  /// 이 설정만으로 생성을 시작할 수 있는가.
  ///
  /// Apple 온디바이스는 주소·키·모델 이름이 필요 없다(기기에 하나뿐이다) — **연결을
  /// 고른 것만으로 설정된 것**이다. 실제 사용 가능 여부(기기 지원·Apple Intelligence
  /// 켜짐)는 연결 확인이 알려 준다.
  bool get isConfigured => connection == LlmConnection.appleFoundation
      ? true
      : baseUrl.isNotEmpty && model.isNotEmpty;

  /// 화면·기록에 쓰는 모델 이름. Apple 온디바이스는 고정 이름을 돌려준다.
  String get effectiveModel =>
      connection == LlmConnection.appleFoundation ? appleModel : model;

  LlmConfig copyWith({
    LlmConnection? connection,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? multimodal,
    String? reasoningEffort,
    bool? parseTextToolCalls,
    int? firstResponseTimeoutSec,
    int? responseTokenBudget,
    double? speedTps,
    double? measuredTps,
    bool? afmPromptedTools,
    bool? afmPermissiveGuardrails,
    bool? afmPrewarm,
    int? afmMaxConcurrent,
    bool? afmTrimHistory,
    int? contextWindow,
    bool? autoFitContext,
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
        responseTokenBudget: responseTokenBudget ?? this.responseTokenBudget,
        speedTps: speedTps ?? this.speedTps,
        measuredTps: measuredTps ?? this.measuredTps,
        afmPromptedTools: afmPromptedTools ?? this.afmPromptedTools,
        afmPermissiveGuardrails:
            afmPermissiveGuardrails ?? this.afmPermissiveGuardrails,
        afmPrewarm: afmPrewarm ?? this.afmPrewarm,
        afmMaxConcurrent: afmMaxConcurrent ?? this.afmMaxConcurrent,
        afmTrimHistory: afmTrimHistory ?? this.afmTrimHistory,
        contextWindow: contextWindow ?? this.contextWindow,
        autoFitContext: autoFitContext ?? this.autoFitContext,
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
        'responseTokenBudget': responseTokenBudget,
        'speedTps': speedTps,
        'measuredTps': measuredTps,
        'afmPromptedTools': afmPromptedTools,
        'afmPermissiveGuardrails': afmPermissiveGuardrails,
        'afmPrewarm': afmPrewarm,
        'afmMaxConcurrent': afmMaxConcurrent,
        'afmTrimHistory': afmTrimHistory,
        'contextWindow': contextWindow,
        'autoFitContext': autoFitContext,
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
        responseTokenBudget: switch (json['responseTokenBudget']) {
          final num v => v.toInt() < 0 ? 0 : v.toInt(),
          _ => defaultResponseTokenBudget,
        },
        speedTps: _positive(json['speedTps']),
        measuredTps: _positive(json['measuredTps']),
        afmPromptedTools: (json['afmPromptedTools'] as bool?) ?? false,
        afmPermissiveGuardrails:
            (json['afmPermissiveGuardrails'] as bool?) ?? true,
        afmPrewarm: (json['afmPrewarm'] as bool?) ?? true,
        afmMaxConcurrent: switch (json['afmMaxConcurrent']) {
          final num v => v.toInt() < 0 ? 0 : v.toInt(),
          _ => 0,
        },
        afmTrimHistory: (json['afmTrimHistory'] as bool?) ?? true,
        contextWindow: switch (json['contextWindow']) {
          final num v => v.toInt() < 0 ? 0 : v.toInt(),
          _ => 0,
        },
        autoFitContext: (json['autoFitContext'] as bool?) ?? true,
      );

  /// 0 이상의 실수로 읽는다(없거나 이상하면 0 = 미지정).
  static double _positive(Object? raw) {
    if (raw is num) {
      final v = raw.toDouble();
      return v.isFinite && v > 0 ? v : 0;
    }
    return 0;
  }
}
