import 'dart:async';
import 'dart:io';

import 'package:collabo_core/collabo_core.dart' show CollaboRuntime;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../browser/browser_controller.dart';
import '../conversation/conversation_store.dart';
import '../data/app_database.dart';
import '../files/file_viewer.dart';
import '../llm/llm_config.dart';
import '../llm/llm_preset.dart';
import '../llm/stream_budget.dart';
import '../llm/system_prompt.dart';
import '../process/background_process_registry.dart';
import '../process/process_manager.dart';
import '../process/python_environment.dart';
import '../sandbox/project_sandbox.dart';
import '../tools/tool_assets.dart';
import '../tools/tool_executor.dart';
import '../tools/tool_source.dart';
import '../ui/app_theme.dart';
import '../viewers/viewer_assets.dart';
import '../webview/web_bridge.dart';
import 'project_session.dart';
import '../viewers/viewer_rule.dart';
import '../viewers/viewer_source.dart';

/// 앱 전역 상태의 중심. 메인 DB, **열려 있는 프로젝트들**, LLM 설정, 도구·뷰어
/// 설정, 최근 프로젝트 목록을 한곳에서 묶는다.
///
/// > ★ **프로젝트에 딸린 것은 여기 없다.** 대화 DB·백그라운드 명령·venv·브리지는
/// > [ProjectSession] 의 것이고, 이 클래스는 그 목록([sessions])과 지금 보고 있는
/// > 것([activeSession])만 안다. 예전에는 전부 여기 한 벌씩 있어서, 다른 프로젝트를
/// > 열면 돌고 있던 생성과 기록이 통째로 덮여 사라졌다.
class WorkspaceController extends ChangeNotifier {
  AppDatabase? _appDb;

  /// 웹 검색 탭들(사용자와 에이전트가 같이 쓴다). 탭 하나가 웹뷰 하나다.
  ///
  /// **프로젝트와 무관하게 앱에 하나뿐이다** — 열린 프로젝트가 여럿이어도 탭 목록과
  /// 쿠키는 하나로 공유한다. 프로젝트마다 다른 것은 파이썬이 말을 거는 통로뿐이고,
  /// 그건 각 세션이 자기 `.collabo/browser` 로 가진다.
  late final BrowserController _browser =
      BrowserController(onActivateRequested: () => _browserWanted?.call());

  /// 도구가 탭을 열었을 때 화면을 웹 검색 쪽으로 돌리는 콜백([AppLayout] 이 건다).
  VoidCallback? _browserWanted;

  /// **열려 있는 프로젝트들.** 연 순서를 유지한다(= 좌측 메뉴의 표시 순서).
  final List<ProjectSession> _sessions = [];

  /// 지금 보고 있는 프로젝트 경로. 비어 있으면 열린 프로젝트가 없다.
  String _activePath = '';

  /// 지난 실행에서 열려 있던 경로들. [restoreOpenProjects] 가 비우며 처리한다.
  List<String> _pendingRestore = const [];
  String _pendingActive = '';

  /// 프로젝트별 venv 사용 여부(전역 정책, 기본 꺼짐). 켜면 각 프로젝트의
  /// `<project>/.collabo/venv` 에 venv 를 자동 생성해 그걸로 실행한다.
  bool _useVenv = false;

  /// 도구 실행 환경: [toolRuntimeSandbox] | [toolRuntimeSystem]. 저장값이 없으면
  /// 런타임이 있을 때 샌드박스, 없으면 시스템 파이썬([init]).
  String _toolRuntime = toolRuntimeSystem;

  /// 이 앱에 동봉된 collaboCore 런타임(없으면 null — 그 플랫폼 런타임을 안 넣었다).
  CollaboRuntime? _sandboxRuntime;
  String _sandboxRuntimeError = '';

  List<RecentProject> _recentProjects = const [];

  /// 테마 모드. 기본값은 라이트. (설정으로 관리, 메인 DB 에 영구 저장)
  ThemeMode _themeMode = ThemeMode.light;

  /// LLM 연결 프리셋 목록. (설정 창에서 관리, 메인 DB 에 영구 저장)
  /// 항상 최소 1개를 유지한다(없으면 빈 기본 프리셋을 만든다).
  List<LlmPreset> _presets = const [];

  /// 기본 프리셋 id. 프로젝트/도구가 따로 지정하지 않으면 이걸 쓴다.
  String _defaultPresetId = '';

  /// 도구별 모델 매핑(도구 이름 → 프리셋 id). 값이 비어 있으면 기본 프리셋.
  /// 현재 대상: 'run_subagent', 'verify_work'.
  Map<String, String> _toolModels = const {};

  /// 프로젝트별 대화 모델 매핑(프로젝트 경로 → 프리셋 id). 없으면 기본 프리셋.
  Map<String, String> _projectModels = const {};

  /// 고정 기본 도구 모듈(Python) 스크립트 경로들. init 에서 추출.
  /// 첫 번째가 대표(어댑터 디렉토리·준비 상태 판정 기준).
  List<String> _baseToolModulePaths = const [];

  /// 사용자가 추가한 도구 소스(일반 CLI / MCP). (설정에 저장, tools 로 확장)
  List<ToolSource> _toolSources = const [];

  /// 에이전트에게 **넘기지 않을** 도구들(`toolKey(소스 id, 원래 이름)`).
  ///
  /// 소스는 추가된 채로 두고 노출만 막는 장치다 — 지우면 설정(경로·MCP 명령)까지
  /// 사라지지만, 꺼 두면 언제든 다시 켤 수 있다. 실제 배제는
  /// [ToolRegistry.load] 가 한 곳에서 한다(목록에서 빠지므로 부를 수도 없다).
  Set<String> _disabledTools = const {};

  /// 사용자가 추가한 파일 뷰어(JS 익스텐션). (설정에 저장, 웹뷰가 로드)
  List<ViewerSource> _viewerSources = const [];

  /// 뷰어별 사용자 설정(뷰어 id → 확장자/사용 여부 덮어쓰기). 메인 DB 에 저장.
  /// 여기 없는 뷰어는 플러그인이 선언한 기본값을 쓴다.
  Map<String, ViewerRule> _viewerRules = const {};

  /// 웹이 보고한 등록된 뷰어 목록(번들 + 사용자).
  ///
  /// 뷰어의 정체와 기본값은 웹에만 있어서 이 보고가 유일한 출처다. 그런데 **웹뷰는
  /// 프로젝트가 열려 있을 때만 존재**하므로(`AppLayout`), 프로젝트 없이 설정을 열면
  /// 보고해 줄 웹이 없다. 그래서 마지막 보고를 메인 DB 에 캐시해 두고 그걸 쓴다.
  List<ViewerInfo> _registeredViewers = const [];

  /// 사용자가 정한 뷰어 우선순위(앞이 이긴다). 같은 확장자를 여러 뷰어가 담당할
  /// 때 누가 자동 선택될지를 결정한다. 비어 있으면 등록 순서를 따른다.
  List<String> _viewerOrder = const [];

  /// 앱에 담겨 오는 예제 뷰어(기본으로 붙지 않는다). init 에서 에셋 목록을 읽는다.
  List<ViewerExample> _viewerExamples = const [];

  /// 사용자가 선택한 Python 인터프리터 경로.
  String _pythonInterpreterPath = '';

  /// 언어 설정 코드: 'system' | 'ko' | 'en'. 기본 시스템.
  String _localeCode = 'system';

  /// 시스템 프롬프트(사용자 편집 가능). 비어 있으면 기본값 사용.
  String _systemPrompt = '';

  /// 최근에 새 프로젝트/프로젝트 열기에서 쓴 상위(워크스페이스) 경로. 다음에 기본값으로.
  String _lastWorkspaceDir = '';

  /// 사전 평가(트리아지) 사용 여부. 사용자 요청을 서브에이전트가 먼저 한 줄로
  /// 평가해 메인 컨텍스트에 넣는다. 기본 켜짐. (설정 → 프롬프트에서 토글)
  bool _preAssessment = true;

  /// 프로젝트 상태 요약(폴더 구조 + 최근 파일 변경 이력)을 에이전트 컨텍스트에
  /// 주입할지. 이미 해 놓은 작업을 다시 시도하느라 낭비하는 걸 줄인다. 기본 켜짐.
  /// (설정 → 프롬프트에서 토글)
  bool _projectState = true;

  /// 계획 메모리(`.collabo/PLAYBOOK.md`) 사용 여부. 켜면 목표·계획 도구 3종이
  /// 모델에게 열리고, 매 턴 컨텍스트에 지금 계획이 실린다. 기본 켜짐.
  /// (설정 → 프롬프트에서 토글)
  bool _planMemory = true;

  /// 감독자(정체 탐지 + 에스컬레이션 사다리 + 종료 차단) 사용 여부. 기본 켜짐.
  /// 끄면 예전 동작 — 반복 상한에 닿을 때까지 아무도 개입하지 않는다.
  /// (설정 → 프롬프트에서 토글)
  bool _supervisor = true;

  /// `web_search` 가 기본으로 쓸 검색엔진 이름('google' | 'duckduckgo' | 확장).
  ///
  /// **판정은 파이썬이 한다** — 여기 있는 값은 그대로 `COLLABO_SEARCH_ENGINE`
  /// 으로 넘어가고, 모르는 이름이면 파이썬이 기본값으로 되돌린다. 그래야 엔진을
  /// 늘릴 때 Dart 의 목록을 같이 고치지 않아도 된다(노트 §12 "두 곳" 회피).
  String _searchEngine = 'google';

  /// 브라우저 탭의 User-Agent 덮어쓰기. 비면 플랫폼 기본을 쓴다(권장).
  String _browserUserAgent = '';

  /// 초기 설정 마법사 완료(또는 건너뜀) 여부. 메인 DB 에 영구 저장.
  bool _setupDone = false;

  /// init() 완료 여부. 첫 실행 판단은 DB 로드가 끝난 뒤에만 한다.
  bool _initialized = false;

  /// [init] 이 끝났는지. `main.dart` 가 `init()` 을 **기다리지 않으므로** 화면은
  /// 초기화보다 먼저 뜬다 — 설정에 기대는 일은 이 값을 보고 미뤄야 한다.
  bool get initialized => _initialized;

  static const String _themeSettingKey = 'theme_mode';
  static const String _llmSettingKey = 'llm'; // 레거시(단일 설정) — 마이그레이션 원본
  static const String _presetsKey = 'llm_presets';
  static const String _defaultPresetKey = 'llm_default_preset';
  static const String _toolModelsKey = 'llm_tool_models';
  static const String _projectModelsKey = 'llm_project_models';
  static const String _toolModulesKey = 'tool_modules';
  static const String _disabledToolsKey = 'tool_disabled';
  static const String _viewerSourcesKey = 'viewer_sources';
  static const String _viewerRulesKey = 'viewer_rules';
  static const String _viewerOrderKey = 'viewer_order';
  /// 웹이 마지막으로 보고한 뷰어 목록(캐시 — 원본은 웹 레지스트리).
  static const String _viewerRegistryKey = 'viewer_registry';
  static const String _pythonKey = 'python_interpreter';
  static const String _useVenvKey = 'python_use_venv';
  static const String _toolRuntimeKey = 'tool_runtime';

  /// 도구를 collaboCore 샌드박스(WASM 리눅스)의 파이썬으로 실행한다.
  static const String toolRuntimeSandbox = 'sandbox';

  /// 도구를 시스템(또는 venv) 파이썬으로 실행한다 — 예전 방식.
  static const String toolRuntimeSystem = 'system';

  /// 마지막 창 크기 설정 키(main.dart 가 부팅 시 직접 읽어 복원한다).
  static const String windowSizeKey = 'window_size';
  static const String _localeKey = 'locale';
  static const String _systemPromptKey = 'system_prompt';
  static const String _setupDoneKey = 'setup_done';
  static const String _workspaceDirKey = 'workspace_dir';
  static const String _preAssessmentKey = 'pre_assessment';
  static const String _projectStateKey = 'project_state';
  static const String _planMemoryKey = 'plan_memory';
  static const String _supervisorKey = 'supervisor';
  static const String _searchEngineKey = 'web_search_engine';
  static const String _browserUserAgentKey = 'web_user_agent';

  /// 열어 둔 프로젝트 경로 목록과 그중 보고 있던 것.
  ///
  /// **최근 목록(MRU)과 다른 것이다.** MRU 는 "예전에 열었던 것" 이고 이쪽은
  /// "지금 열려 있는 것" 이다 — 앱을 닫았다 켜도 열어 둔 상태가 그대로여야 한다.
  static const String _openProjectsKey = 'open_projects';
  static const String _activeProjectKey = 'active_project';

  /// 열려 있는 프로젝트들(연 순서).
  List<ProjectSession> get sessions => List.unmodifiable(_sessions);

  /// 지금 보고 있는 프로젝트. 없으면 null.
  ProjectSession? get activeSession => sessionFor(_activePath);

  /// 경로로 열린 세션을 찾는다(안 열려 있으면 null).
  ProjectSession? sessionFor(String path) {
    for (final s in _sessions) {
      if (s.path == path) return s;
    }
    return null;
  }

  bool isOpen(String path) => sessionFor(path) != null;

  /// 생성이 돌고 있는 프로젝트 수(좌측 메뉴 배지).
  int get busySessionCount => _sessions.where((s) => s.isBusy).length;

  // --- 아래 넷은 **활성 세션으로 위임**한다. 설정 창과 기존 호출부가 "지금 보고
  //     있는 프로젝트" 를 묻는 흔한 질문이라 그대로 남겨 두었다. 특정 프로젝트를
  //     가리켜야 하는 곳(브리지 등)은 세션을 직접 들고 있어야 한다.
  String? get projectPath => activeSession?.path;
  bool get hasProject => activeSession != null;
  ConversationStore? get conversation => activeSession?.conversation;
  int? get activeConversationId => activeSession?.activeConversationId;

  ProcessManager? get processManager => activeSession?.processManager;

  /// 활성 프로젝트의 백그라운드 명령 레지스트리(프로세스 뷰어가 사용).
  ///
  /// 좌측 메뉴의 활동 배지는 **열린 전부**를 세야 하므로 [runningProcessCount] 를 쓴다.
  BackgroundProcessRegistry? get backgroundProcesses =>
      activeSession?.backgroundProcesses;

  /// 열린 **모든** 프로젝트에서 돌고 있는 백그라운드 명령 수.
  int get runningProcessCount {
    var n = 0;
    for (final s in _sessions) {
      n += s.backgroundProcesses.runningCount;
    }
    return n;
  }

  /// 웹 검색 탭(패널이 그리고, 파일 통로가 부린다).
  BrowserController get browser => _browser;

  /// 도구가 탭을 열면 화면을 웹 검색으로 돌려 달라는 요청을 받는다.
  /// [AppLayout] 이 한 번 걸어 두고 끝이다.
  set onBrowserWanted(VoidCallback? cb) => _browserWanted = cb;

  String get searchEngine => _searchEngine;
  String get browserUserAgent => _browserUserAgent;

  /// **모든** 도구 실행에 실리는 환경변수. [ToolRunner.baseEnv] 로 간다.
  Map<String, String> get toolEnv => {
        'COLLABO_LANG': langCode,
        'COLLABO_SEARCH_ENGINE': _searchEngine,
      };
  List<RecentProject> get recentProjects => _recentProjects;
  ThemeMode get themeMode => _themeMode;

  /// 전체 프리셋 목록(읽기 전용).
  List<LlmPreset> get llmPresets => List.unmodifiable(_presets);

  /// 기본 프리셋 id.
  String get defaultPresetId => _defaultPresetId;

  /// 기본 프리셋(없으면 첫 프리셋, 그것도 없으면 빈 프리셋).
  LlmPreset get defaultPreset => _presetById(_defaultPresetId) ??
      (_presets.isNotEmpty
          ? _presets.first
          : LlmPreset(id: '', name: '', config: const LlmConfig()));

  /// 기본 프리셋의 연결 설정(기존 단일 설정 소비처 호환용).
  LlmConfig get llmConfig => defaultPreset.config;

  LlmPreset? _presetById(String id) {
    for (final p in _presets) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 현재(또는 지정) 프로젝트의 대화에 쓸 연결 설정.
  /// 프로젝트가 고른 프리셋이 있으면 그것을, 없으면 기본 프리셋을 쓴다.
  LlmConfig configForConversation([String? projectPath]) {
    // 빈 경로(열린 프로젝트 없음)는 매핑에 없으므로 기본 프리셋으로 떨어진다.
    final id = _projectModels[projectPath ?? _activePath];
    if (id != null && id.isNotEmpty) {
      final p = _presetById(id);
      if (p != null) return p.config;
    }
    return defaultPreset.config;
  }

  /// 도구(run_subagent/verify_work)에 쓸 연결 설정.
  ///
  /// 해석 순서: **도구별 지정 프리셋 → 프로젝트 대화 모델(헤더 드롭다운) → 기본 프리셋**.
  /// 즉 도구에 따로 지정하지 않았으면 그 프로젝트에서 **지금 대화 중인 모델**을 그대로
  /// 쓴다. 헤더에서 모델을 바꾸면 서브에이전트/검증도 같이 따라오게 하기 위함이다
  /// (예전에는 전역 기본 프리셋으로 떨어져, 사전 평가·압축은 대화 모델을 쓰는데
  ///  정작 실제 작업만 다른 모델로 도는 불일치가 있었다).
  ///
  /// [projectPath] 를 주면 그 프로젝트 기준으로 해석한다(기본은 현재 프로젝트).
  LlmConfig configForTool(String toolName, [String? projectPath]) {
    final id = _toolModels[toolName];
    if (id != null && id.isNotEmpty) {
      final p = _presetById(id);
      if (p != null) return p.config;
    }
    return configForConversation(projectPath);
  }

  /// 대화가 실제로 쓰는 프리셋 id(**빈 문자열이 아니라 해석된 값**).
  /// 속도 실측을 프리셋별로 모으려면 "기본 사용" 이 아니라 실제 id 가 필요하다.
  String resolvedPresetIdForConversation([String? projectPath]) {
    final id = _projectModels[projectPath ?? _activePath];
    if (id != null && id.isNotEmpty && _presetById(id) != null) return id;
    return defaultPreset.id;
  }

  /// 도구가 실제로 쓰는 프리셋 id. 해석 순서는 [configForTool] 과 같다.
  String resolvedPresetIdForTool(String toolName, [String? projectPath]) {
    final id = _toolModels[toolName];
    if (id != null && id.isNotEmpty && _presetById(id) != null) return id;
    return resolvedPresetIdForConversation(projectPath);
  }

  /// 프리셋별 실측 속도계(세션 한정). 신뢰 조건을 넘으면 프리셋에도 저장한다.
  final Map<String, SpeedMeter> _speedMeters = {};

  /// 이 프리셋에 적용할 처리 속도(tok/s).
  ///
  /// 해석 순서: **사용자 지정 → 이번 세션 실측 → 저장된 실측 → 기본값(100)**.
  /// 사용자가 값을 넣었으면 앱은 그걸 덮지 않는다.
  double effectiveTps(String presetId) {
    final cfg = _presetById(presetId)?.config ?? const LlmConfig();
    if (cfg.speedTps > 0) return cfg.speedTps;
    final live = _speedMeters[presetId]?.tps;
    if (live != null) return live;
    return cfg.storedTps; // 저장된 실측 → 기본값
  }

  /// 이 프리셋의 스트리밍 시간 상한(널이면 무제한).
  Duration? streamingLimitFor(String presetId) {
    final cfg = _presetById(presetId)?.config;
    if (cfg == null) return null;
    return budgetToTime(cfg.responseTokenBudget, effectiveTps(presetId));
  }

  /// 상한에 걸렸을 때 보여 줄 근거 문구.
  String budgetReasonFor(String presetId, Duration limit) {
    final cfg = _presetById(presetId)?.config ?? const LlmConfig();
    final userSet = cfg.speedTps > 0;
    return budgetReason(
      limit: limit,
      tokenBudget: cfg.responseTokenBudget,
      tokPerSec: effectiveTps(presetId),
      source: userSet ? 'you set' : 'measured',
    );
  }

  /// 응답 하나의 실측치를 더한다. 표본 규칙과 신뢰 조건은 [SpeedMeter] 가 판단한다.
  ///
  /// 사용자가 속도를 직접 지정한 프리셋은 **재지 않는다** — 그 값을 쓰기로 한 것이고,
  /// 매 턴 DB 를 건드릴 이유도 없다.
  Future<void> observeSpeed(String presetId,
      {required int completionTokens, required int elapsedMs}) async {
    final preset = _presetById(presetId);
    if (preset == null || preset.config.speedTps > 0) return;
    final meter = _speedMeters.putIfAbsent(presetId, SpeedMeter.new);
    if (!meter.add(
        completionTokens: completionTokens, elapsedMs: elapsedMs)) {
      return; // 표본으로 안 쓰는 라운드
    }
    final tps = meter.tps;
    if (tps == null) return; // 아직 믿을 만큼 안 모였다
    // 매 턴 DB 를 쓰지 않는다 — 저장분과 10% 넘게 벌어질 때만 갱신한다.
    final saved = preset.config.measuredTps;
    if (saved > 0 && (tps - saved).abs() / saved < 0.10) return;
    await updatePreset(presetId,
        config: preset.config.copyWith(measuredTps: tps));
  }

  /// 도구에 지정된 프리셋 id('' = 기본 사용).
  String presetIdForTool(String toolName) => _toolModels[toolName] ?? '';

  /// 프로젝트에 지정된 프리셋 id('' = 기본 사용).
  String presetIdForProject([String? projectPath]) =>
      _projectModels[projectPath ?? _activePath] ?? '';

  /// 현재 시스템 프롬프트(미설정이면 기본값).
  String get systemPrompt =>
      _systemPrompt.trim().isEmpty ? kDefaultSystemPrompt : _systemPrompt;

  /// 사용자가 저장한 원본(편집 화면 표시용; 비어 있으면 기본값을 보여준다).
  String get systemPromptRaw =>
      _systemPrompt.isEmpty ? kDefaultSystemPrompt : _systemPrompt;
  /// 대표 기본 모듈 경로(없으면 null).
  String? get baseToolModulePath =>
      _baseToolModulePaths.isEmpty ? null : _baseToolModulePaths.first;

  /// 고정 기본 모듈 전체(파일 작업 + 문서 편집 …).
  List<String> get baseToolModulePaths => List.unmodifiable(_baseToolModulePaths);
  List<ToolSource> get toolSources => _toolSources;

  /// 사용자가 추가한 파일 뷰어 목록(설정 → 뷰어).
  List<ViewerSource> get viewerSources => _viewerSources;

  /// 뷰어별 사용자 설정(없는 뷰어는 기본값).
  Map<String, ViewerRule> get viewerRules => Map.unmodifiable(_viewerRules);

  /// 뷰어 하나의 설정(미설정이면 기본값 규칙).
  ViewerRule viewerRuleFor(String viewerId) =>
      _viewerRules[viewerId] ?? const ViewerRule();

  /// 웹이 보고한 등록된 뷰어 목록(보고된 순서 그대로).
  List<ViewerInfo> get registeredViewers => _registeredViewers;

  /// 사용자가 정한 뷰어 우선순위(앞이 이긴다). 비어 있으면 등록 순서를 따른다.
  List<String> get viewerOrder => List.unmodifiable(_viewerOrder);

  /// 앱에 담긴 예제 뷰어 중 **아직 추가하지 않은** 것(설정에서 "추가" 로 얹는다).
  List<ViewerExample> get availableViewerExamples => [
        for (final e in _viewerExamples)
          if (!_viewerSources
              .any((s) => p.basename(s.path) == e.fileName)) e,
      ];

  /// 우선순위가 적용된 뷰어 목록(설정 화면의 표시 순서 = 실제 선택 순서).
  List<ViewerInfo> get orderedViewers =>
      sortViewersByOrder(_registeredViewers, _viewerOrder);

  /// 뷰어에 실제로 적용되는 확장자(override 가 있으면 그것, 없으면 선언값).
  List<String> effectiveExtensionsFor(ViewerInfo info) =>
      _viewerRules[info.id]?.extensions ?? info.defaultExtensions;

  /// 첫 실행(데이터가 전혀 준비되지 않음) 여부 → 초기 설정 마법사 표시 조건.
  /// 초기화 완료 후, 설정 미완료 + LLM 미설정 + Python 미선택 + 최근 프로젝트 없음.
  bool get needsFirstRunSetup =>
      _initialized &&
      !_setupDone &&
      !llmConfig.isConfigured &&
      _pythonInterpreterPath.isEmpty &&
      _recentProjects.isEmpty;

  /// 추출된 도구 모듈/어댑터 디렉토리(cli_adapter.py, mcp_adapter.py 위치).
  String? get toolAdaptersDir {
    final base = baseToolModulePath;
    return base != null ? p.dirname(base) : null;
  }

  /// 선택된 base Python 인터프리터 경로(미설정이면 null).
  String? get pythonInterpreter =>
      _pythonInterpreterPath.isEmpty ? null : _pythonInterpreterPath;

  /// 활성 프로젝트의 **실효 파이썬**(venv 준비 시 venv, 아니면 base). 미설정이면 null.
  ///
  /// 상태확인(env_check)·pip 도 이걸 써야 tools 와 동일 환경을 대상으로 한다
  /// (base 로 설치하면 Homebrew/시스템 파이썬의 PEP 668 로 막힌다).
  /// **프로젝트마다 다를 수 있다** — venv 가 프로젝트별이기 때문이다.
  String? get effectivePython => activeSession?.effectivePython;

  bool get pythonInstalled => _pythonInterpreterPath.isNotEmpty &&
      File(_pythonInterpreterPath).existsSync();

  PythonEnvironment? get pythonEnv => activeSession?.pythonEnv;

  /// 그 프로젝트에서 에이전트가 Python 도구를 실제로 실행할 수 있는 상태인지.
  /// (인터프리터 선택 + 그 파일이 존재 + 기본 모듈/어댑터 추출 완료)
  ///
  /// **`AgentLoop._buildToolRegistry` 의 전제조건과 같아야 한다.** false 면 도구가
  /// 하나도 없는 채로 대화만 돌아가므로(서브에이전트가 아무 작업도 못 한다),
  /// 대화 헤더에 설정 안내 버튼을 띄우는 근거로도 쓴다.
  ///
  /// 샌드박스 모드면 시스템 파이썬은 필요 없다 — 런타임만 있으면 된다. 샌드박스를
  /// 골랐는데 런타임이 없으면 **시스템 파이썬으로 몰래 물러서지 않는다**(격리를
  /// 기대한 사용자에게 호스트에서 명령이 도는 것은 놀라운 일이다) → 준비 안 됨.
  bool toolsReadyFor(ProjectSession session) =>
      _baseToolModulePaths.isNotEmpty &&
      toolAdaptersDir != null &&
      (usesSandbox ? _sandboxRuntime != null : session.effectivePython != null);

  /// 저장된 도구 실행 환경 설정값.
  String get toolRuntime => _toolRuntime;

  /// 도구를 샌드박스에서 실행하는가(설정 기준 — 런타임이 없으면 [toolsReady] 가 false).
  bool get usesSandbox => _toolRuntime == toolRuntimeSandbox;

  /// 이 플랫폼용 collaboCore 런타임이 앱에 들어 있는가.
  bool get sandboxAvailable => _sandboxRuntime != null;

  /// 런타임을 못 찾은 이유(설정 화면 표시용).
  String get sandboxRuntimeError => _sandboxRuntimeError;

  /// 도구 실행 환경을 바꾼다(설정 → 도구). 다음 생성부터 적용된다 — 레지스트리는
  /// 생성마다 새로 만든다(`AgentLoop._buildToolRegistry`).
  Future<void> setToolRuntime(String value) async {
    if (value != toolRuntimeSandbox && value != toolRuntimeSystem) return;
    if (value == _toolRuntime) return;
    _toolRuntime = value;
    notifyListeners();
    await _appDb?.setSetting(_toolRuntimeKey, value);
  }

  /// 그 세션의 도구 실행기. [toolsReadyFor] 가 참일 때만 부른다.
  ToolExecutor toolExecutorFor(ProjectSession session) {
    if (usesSandbox) {
      final box = session.sandboxFor(_sandboxRuntime!, toolsDir: toolAdaptersDir!);
      return SandboxToolExecutor(box);
    }
    return HostToolExecutor(session.effectivePython!);
  }

  /// 샌드박스 화면용: 그 세션의 머신. 아직 없으면 **만들 수 있을 때만** 만든다
  /// (샌드박스 모드 + 런타임 + 도구 폴더). 만들기만 하고 부팅은 하지 않는다.
  ProjectSandbox? sandboxOf(ProjectSession session) {
    final existing = session.sandbox;
    if (existing != null) return existing;
    final runtime = _sandboxRuntime;
    final tools = toolAdaptersDir;
    if (!usesSandbox || runtime == null || tools == null) return null;
    return session.sandboxFor(runtime, toolsDir: tools);
  }

  /// 시험용: [init] 없이 샌드박스 모드를 세운다(런타임 + 기본 모듈 경로).
  @visibleForTesting
  void debugUseSandbox({required CollaboRuntime runtime, required List<String> baseModules}) {
    _sandboxRuntime = runtime;
    _baseToolModulePaths = baseModules;
    _toolRuntime = toolRuntimeSandbox;
  }

  /// 지금 떠 있는 머신 수(좌측 메뉴 배지).
  int get runningSandboxCount =>
      _sessions.where((s) => s.sandbox?.isRunning ?? false).length;

  /// 동봉 런타임을 찾는다. 개발 중에는 `COLLABO_CORE_RUNTIME` 으로 가리킬 수 있다
  /// (`CollaboRuntime.locate` 의 순서 그대로).
  void _locateSandboxRuntime() {
    try {
      _sandboxRuntime = CollaboRuntime.locate();
      _sandboxRuntimeError = '';
    } catch (e) {
      _sandboxRuntime = null;
      _sandboxRuntimeError = '$e';
    }
  }

  /// 활성 프로젝트 기준(설정 창이 본다).
  bool get toolsReady {
    final s = activeSession;
    return s != null && toolsReadyFor(s);
  }

  /// 프로젝트별 venv 사용 여부(전역 정책).
  bool get useVenv => _useVenv;

  /// 활성 프로젝트의 venv 준비 상태.
  VenvStatus get venvStatus => activeSession?.venvStatus ?? VenvStatus.idle;

  /// venv 생성 실패 메시지(없으면 빈 문자열).
  String get venvError => activeSession?.venvError ?? '';

  /// 활성 프로젝트에 적용될 venv 경로(미사용/프로젝트 없음이면 null).
  String? get venvPath => activeSession?.venvPathFor(useVenv: _useVenv);

  /// 열린 **모든** 세션의 파이썬 환경을 현재 설정으로 다시 만든다.
  ///
  /// ⚠️ 한 세션만 갱신하면 나머지는 옛 인터프리터로 계속 돈다 — 인터프리터와 venv
  /// 정책은 전역 설정이므로 바뀌면 전부가 따라와야 한다.
  void _rebuildAllPythonEnvs() {
    for (final s in _sessions) {
      s.rebuildPythonEnv(_pythonInterpreterPath, useVenv: _useVenv);
    }
  }

  /// 프로젝트별 venv 사용 여부를 변경/저장한다(설정 → 도구 → Python).
  Future<void> setUseVenv(bool value) async {
    if (value == _useVenv) return;
    _useVenv = value;
    _rebuildAllPythonEnvs();
    notifyListeners();
    await _appDb?.setSetting(_useVenvKey, value);
    for (final s in _sessions) {
      await s.ensureVenv();
    }
  }

  /// 활성 프로젝트의 venv 를 삭제 후 재생성한다(설정의 "재생성" 버튼).
  Future<void> recreateVenv() async {
    final s = activeSession;
    if (s == null) return;
    await s.recreateVenv(useVenv: _useVenv);
  }

  /// 언어 설정 코드('system'|'ko'|'en').
  String get localeCode => _localeCode;

  /// MaterialApp 에 줄 Locale. 'system' 이면 null(플랫폼 따름).
  Locale? get locale => _localeCode == 'system' ? null : Locale(_localeCode);

  /// 실제 적용 언어 코드('ko' | 'en'). 'system' 이면 플랫폼 언어로 환원.
  String get langCode {
    if (_localeCode != 'system') return _localeCode == 'ko' ? 'ko' : 'en';
    return Platform.localeName.toLowerCase().startsWith('ko') ? 'ko' : 'en';
  }

  /// Python 스크립트에 넘길 언어팩 JSON 경로(`<adapters>/lang/<code>.json`).
  String? get pythonLangFile {
    final dir = toolAdaptersDir;
    if (dir == null) return null;
    return p.join(dir, 'lang', '$langCode.json');
  }

  /// 앱 시작 시 1회: 메인 DB 열기, 설정/최근 목록 로드, Python 환경/매니저 준비.
  Future<void> init() async {
    _appDb = await AppDatabase.open();
    _recentProjects = await _appDb!.recentProjects();
    _themeMode =
        AppTheme.modeFromName(await _appDb!.getSetting(_themeSettingKey) as String?);
    await _loadPresets();
    final tmModels = await _appDb!.getSetting(_toolModelsKey);
    if (tmModels is Map) _toolModels = _strMap(tmModels);
    final pmModels = await _appDb!.getSetting(_projectModelsKey);
    if (pmModels is Map) _projectModels = _strMap(pmModels);
    final tm = await _appDb!.getSetting(_toolModulesKey);
    if (tm is List) _toolSources = _parseSources(tm);
    final dt = await _appDb!.getSetting(_disabledToolsKey);
    if (dt is List) _disabledTools = dt.whereType<String>().toSet();
    final vs = await _appDb!.getSetting(_viewerSourcesKey);
    if (vs is List) _viewerSources = _parseViewerSources(vs);
    final vr = await _appDb!.getSetting(_viewerRulesKey);
    if (vr is Map) _viewerRules = _parseViewerRules(vr);
    final vo = await _appDb!.getSetting(_viewerOrderKey);
    if (vo is List) _viewerOrder = vo.whereType<String>().toList();
    final vg = await _appDb!.getSetting(_viewerRegistryKey);
    if (vg is List) _registeredViewers = _parseViewerInfos(vg);
    _pythonInterpreterPath =
        (await _appDb!.getSetting(_pythonKey) as String?) ?? '';
    _useVenv = (await _appDb!.getSetting(_useVenvKey) as bool?) ?? false;
    _locateSandboxRuntime();
    final rt = await _appDb!.getSetting(_toolRuntimeKey);
    _toolRuntime = rt == toolRuntimeSandbox || rt == toolRuntimeSystem
        ? rt as String
        // 고른 적이 없으면: 런타임이 있으면 샌드박스가 기본이다(도구 계층의 목표 위치).
        : (_sandboxRuntime != null ? toolRuntimeSandbox : toolRuntimeSystem);
    _localeCode = (await _appDb!.getSetting(_localeKey) as String?) ?? 'system';
    _systemPrompt = (await _appDb!.getSetting(_systemPromptKey) as String?) ?? '';
    _setupDone = (await _appDb!.getSetting(_setupDoneKey) as bool?) ?? false;
    _lastWorkspaceDir =
        (await _appDb!.getSetting(_workspaceDirKey) as String?) ?? '';
    _preAssessment =
        (await _appDb!.getSetting(_preAssessmentKey) as bool?) ?? true;
    _projectState =
        (await _appDb!.getSetting(_projectStateKey) as bool?) ?? true;
    _planMemory = (await _appDb!.getSetting(_planMemoryKey) as bool?) ?? true;
    _supervisor = (await _appDb!.getSetting(_supervisorKey) as bool?) ?? true;
    _searchEngine =
        (await _appDb!.getSetting(_searchEngineKey) as String?) ?? 'google';
    _browserUserAgent =
        (await _appDb!.getSetting(_browserUserAgentKey) as String?) ?? '';
    _browser.userAgent = _browserUserAgent;
    // 열어 둔 프로젝트는 **경로만** 여기서 읽고 실제 열기는 미룬다 — 새 대화 제목이
    // l10n 이라 화면이 준비된 뒤여야 한다([restoreOpenProjects]).
    final op = await _appDb!.getSetting(_openProjectsKey);
    if (op is List) _pendingRestore = op.whereType<String>().toList();
    _pendingActive = (await _appDb!.getSetting(_activeProjectKey) as String?) ?? '';

    _baseToolModulePaths = await ToolAssets.extractBaseModules();
    _viewerExamples = await ViewerAssets.examples();
    _initialized = true;
    notifyListeners();
  }

  /// 새 프로젝트/열기에서 마지막으로 쓴 상위(워크스페이스) 경로(없으면 null).
  String? get lastWorkspaceDir =>
      _lastWorkspaceDir.isEmpty ? null : _lastWorkspaceDir;

  /// 상위(워크스페이스) 경로를 기억한다(다음 새 프로젝트/열기의 기본값).
  Future<void> setLastWorkspaceDir(String dir) async {
    if (dir.isEmpty || dir == _lastWorkspaceDir) return;
    _lastWorkspaceDir = dir;
    await _appDb?.setSetting(_workspaceDirKey, dir);
  }

  /// 프로젝트 상태 요약 주입 여부.
  bool get projectState => _projectState;

  /// 프로젝트 상태 요약 주입 여부를 변경/저장한다(설정 → 프롬프트 토글).
  Future<void> setProjectState(bool value) async {
    if (value == _projectState) return;
    _projectState = value;
    notifyListeners();
    await _appDb?.setSetting(_projectStateKey, value);
  }

  /// 사전 평가(트리아지) 사용 여부.
  bool get preAssessment => _preAssessment;

  /// 사전 평가 사용 여부를 변경/저장한다(설정 → 프롬프트 토글).
  Future<void> setPreAssessment(bool value) async {
    if (value == _preAssessment) return;
    _preAssessment = value;
    notifyListeners();
    await _appDb?.setSetting(_preAssessmentKey, value);
  }

  /// 계획 메모리(PLAYBOOK) 사용 여부.
  bool get planMemory => _planMemory;

  /// 계획 메모리 사용 여부를 변경/저장한다(설정 → 프롬프트 토글).
  Future<void> setPlanMemory(bool value) async {
    if (value == _planMemory) return;
    _planMemory = value;
    notifyListeners();
    await _appDb?.setSetting(_planMemoryKey, value);
  }

  /// 감독자 사용 여부.
  bool get supervisor => _supervisor;

  /// 감독자 사용 여부를 변경/저장한다(설정 → 프롬프트 토글).
  Future<void> setSupervisor(bool value) async {
    if (value == _supervisor) return;
    _supervisor = value;
    notifyListeners();
    await _appDb?.setSetting(_supervisorKey, value);
  }

  /// 기본 검색엔진을 변경/저장한다(설정 → 도구).
  ///
  /// 값을 검사하지 않는다 — 무엇이 유효한 엔진인지는 파이썬 모듈만 알고, 사용자가
  /// `web_engines/` 에 새로 넣은 이름도 여기 들어올 수 있다.
  Future<void> setSearchEngine(String name) async {
    final value = name.trim();
    if (value.isEmpty || value == _searchEngine) return;
    _searchEngine = value;
    notifyListeners();
    await _appDb?.setSetting(_searchEngineKey, value);
  }

  /// 브라우저 User-Agent 덮어쓰기를 변경/저장한다. 빈 값이면 플랫폼 기본.
  ///
  /// **이미 열려 있는 탭에는 적용되지 않는다** — 웹뷰마다 초기화 때 한 번
  /// 정해지는 값이라, 다음에 여는 탭부터 바뀐다.
  Future<void> setBrowserUserAgent(String value) async {
    final ua = value.trim();
    if (ua == _browserUserAgent) return;
    _browserUserAgent = ua;
    _browser.userAgent = ua;
    notifyListeners();
    await _appDb?.setSetting(_browserUserAgentKey, ua);
  }

  /// 초기 설정 마법사를 완료(또는 건너뜀)로 표시한다(이후 자동 표시 안 함).
  Future<void> markSetupComplete() async {
    if (_setupDone) return;
    _setupDone = true;
    notifyListeners();
    await _appDb?.setSetting(_setupDoneKey, true);
  }

  /// 시스템 프롬프트를 저장한다(빈 문자열이면 기본값으로 되돌아간다).
  Future<void> setSystemPrompt(String prompt) async {
    _systemPrompt = prompt;
    notifyListeners();
    await _appDb?.setSetting(_systemPromptKey, prompt);
  }

  /// 마지막 창 크기를 저장한다(다음 실행에서 복원; 위치는 저장하지 않음).
  Future<void> saveWindowSize(double width, double height) async {
    await _appDb?.setSetting(windowSizeKey, {'w': width, 'h': height});
  }

  /// 언어를 변경/저장한다('system'|'ko'|'en').
  Future<void> setLocaleCode(String code) async {
    if (code == _localeCode) return;
    _localeCode = code;
    notifyListeners();
    await _appDb?.setSetting(_localeKey, code);
  }

  /// 사용할 base Python 인터프리터를 선택/저장한다.
  /// venv 를 쓰는 프로젝트라면, 바뀐 base 로 venv 를 (없으면) 다시 준비한다.
  Future<void> setPythonInterpreter(String path) async {
    _pythonInterpreterPath = path;
    _rebuildAllPythonEnvs();
    notifyListeners();
    await _appDb?.setSetting(_pythonKey, path);
    for (final s in _sessions) {
      await s.ensureVenv();
    }
  }

  static List<ToolSource> _parseSources(List<Object?> raw) {
    final out = <ToolSource>[];
    for (final e in raw) {
      if (e is String) {
        out.add(ToolSource.legacy(e)); // 구버전(문자열 경로) 이주
      } else if (e is Map) {
        out.add(ToolSource.fromJson(e.cast<String, Object?>()));
      }
    }
    return out;
  }

  Future<void> _saveSources() async {
    await _appDb?.setSetting(
      _toolModulesKey,
      _toolSources.map((s) => s.toJson()).toList(),
    );
  }

  /// 도구 소스를 추가/제거하고 메인 DB 에 저장한다.
  Future<void> addToolSource(ToolSource source) async {
    if (_toolSources.any((s) => s.id == source.id)) return;
    _toolSources = [..._toolSources, source];
    notifyListeners();
    await _saveSources();
  }

  Future<void> removeToolSource(ToolSource source) async {
    _toolSources = _toolSources.where((s) => s.id != source.id).toList();
    // 소스가 사라지면 그 도구들의 비활성 표시도 같이 지운다 — 안 그러면 같은
    // 스크립트를 다시 추가했을 때 예전에 꺼 둔 도구가 조용히 꺼진 채로 온다.
    final prefix = '${source.id}::';
    final kept = _disabledTools.where((k) => !k.startsWith(prefix)).toSet();
    final pruned = kept.length != _disabledTools.length;
    if (pruned) _disabledTools = kept;
    notifyListeners();
    await _saveSources();
    if (pruned) await _saveDisabledTools();
  }

  /// 꺼 둔 도구 키 집합(레지스트리에 그대로 넘긴다).
  Set<String> get disabledTools => _disabledTools;

  /// 이 도구를 에이전트에게 넘기는가. [sourceId] 는 [ToolSource.id] 또는
  /// [baseSourceId], [toolName] 은 모듈이 아는 원래 이름이다.
  bool isToolEnabled(String sourceId, String toolName) =>
      !_disabledTools.contains(toolKey(sourceId, toolName));

  /// 도구 여러 개의 활성 상태를 한 번에 바꾼다(모듈 줄의 체크박스가 전체를 넘긴다).
  Future<void> setToolsEnabled(
      String sourceId, Iterable<String> toolNames, bool enabled) async {
    final next = Set<String>.from(_disabledTools);
    // add/remove 가 "실제로 바뀌었나" 를 돌려주므로 그걸 그대로 쓴다
    // (집합 비교 함수는 foundation 에 있는데, 이 파일은 material 만 쓴다).
    var changed = false;
    for (final name in toolNames) {
      final key = toolKey(sourceId, name);
      if (enabled ? next.remove(key) : next.add(key)) changed = true;
    }
    if (!changed) return;
    _disabledTools = next;
    notifyListeners();
    await _saveDisabledTools();
  }

  Future<void> _saveDisabledTools() async {
    // 목록 순서는 의미가 없지만, 저장본이 매번 뒤집히면 눈으로 비교하기 나쁘다.
    await _appDb?.setSetting(_disabledToolsKey, _disabledTools.toList()..sort());
  }

  static List<ViewerSource> _parseViewerSources(List<Object?> raw) {
    final out = <ViewerSource>[];
    for (final e in raw) {
      if (e is String) {
        out.add(ViewerSource.legacy(e)); // 경로 문자열만 저장된 형태
      } else if (e is Map) {
        final v = ViewerSource.fromJson(e.cast<String, Object?>());
        if (v.path.isNotEmpty) out.add(v);
      }
    }
    return out;
  }

  Future<void> _saveViewerSources() async {
    await _appDb?.setSetting(
      _viewerSourcesKey,
      _viewerSources.map((s) => s.toJson()).toList(),
    );
  }

  /// 파일 뷰어(JS)를 추가/제거하고 메인 DB 에 저장한다.
  ///
  /// 실제 로드/해제는 [WebBridge] 가 이 알림을 받아 웹으로 반영한다(앱 재시작
  /// 없이 드롭다운에 나타나거나 사라진다).
  Future<void> addViewerSource(ViewerSource source) async {
    if (source.path.isEmpty) return;
    if (_viewerSources.any((s) => s.id == source.id)) return;
    _viewerSources = [..._viewerSources, source];
    notifyListeners();
    await _saveViewerSources();
  }

  /// 앱에 담긴 예제 뷰어를 추가한다: 파일을 웹 루트로 꺼낸 뒤 사용자 뷰어로 등록.
  /// (사용자가 직접 고른 .js 와 이후 취급이 완전히 같다.)
  Future<void> addViewerExample(ViewerExample example) async {
    final path = await ViewerAssets.materialize(example);
    await addViewerSource(ViewerSource(path: path));
  }

  Future<void> removeViewerSource(ViewerSource source) async {
    _viewerSources = _viewerSources.where((s) => s.id != source.id).toList();
    notifyListeners();
    await _saveViewerSources();
  }

  static Map<String, ViewerRule> _parseViewerRules(Map raw) => {
        for (final e in raw.entries)
          if (e.value is Map)
            e.key.toString():
                ViewerRule.fromJson((e.value as Map).cast<String, Object?>()),
      };

  Future<void> _saveViewerRules() async {
    await _appDb?.setSetting(
      _viewerRulesKey,
      {for (final e in _viewerRules.entries) e.key: e.value.toJson()},
    );
  }

  /// 뷰어의 확장자/사용 여부를 바꾼다. 전부 기본값이 되면 항목 자체를 지운다
  /// (플러그인이 나중에 기본 확장자를 바꿔도 그 값을 따라가도록).
  Future<void> setViewerRule(String viewerId, ViewerRule rule) async {
    if (viewerId.isEmpty) return;
    final next = Map<String, ViewerRule>.from(_viewerRules);
    if (rule.isDefault) {
      if (!next.containsKey(viewerId)) return;
      next.remove(viewerId);
    } else {
      next[viewerId] = rule;
    }
    _viewerRules = next;
    notifyListeners();
    await _saveViewerRules();
  }

  /// 뷰어 설정을 기본값으로 되돌린다.
  Future<void> resetViewerRule(String viewerId) =>
      setViewerRule(viewerId, const ViewerRule());

  /// 뷰어 우선순위를 저장한다(설정 화면에서 끌어 옮긴 결과 = 전체 순서).
  Future<void> setViewerOrder(List<String> ids) async {
    if (_viewerOrder.length == ids.length &&
        _viewerOrder.join(',') == ids.join(',')) {
      return;
    }
    _viewerOrder = List.unmodifiable(ids);
    notifyListeners();
    await _appDb?.setSetting(_viewerOrderKey, ids);
  }

  /// 순서를 기본(등록 순서)으로 되돌린다.
  Future<void> resetViewerOrder() => setViewerOrder(const []);

  static List<ViewerInfo> _parseViewerInfos(List<Object?> raw) => [
        for (final e in raw)
          if (e is Map) ViewerInfo.fromJson(e.cast<String, Object?>()),
      ];

  /// 웹이 보고한 등록 뷰어 목록을 갱신하고 캐시에 남긴다([WebBridge] 가 호출).
  ///
  /// 내용이 같으면 알리지도, 저장하지도 않는다 — 이 알림으로 설정 화면이 다시
  /// 그려지는데, 웹은 뷰어가 바뀔 때마다 보고하므로 같은 목록이 반복해 들어온다.
  ///
  /// **빈 목록은 무시한다.** 뷰어 스크립트가 로드되기 전(기동 직후)에도 보고가 한 번
  /// 오는데, 그걸로 캐시를 날리면 프로젝트 없이 설정을 열었을 때 목록이 사라진다.
  void setRegisteredViewers(List<ViewerInfo> viewers) {
    if (viewers.isEmpty || _sameViewerList(_registeredViewers, viewers)) return;
    _registeredViewers = List.unmodifiable(viewers);
    notifyListeners();
    final db = _appDb;
    if (db != null) {
      unawaited(db.setSetting(
          _viewerRegistryKey, [for (final v in viewers) v.toJson()]));
    }
  }

  static bool _sameViewerList(List<ViewerInfo> a, List<ViewerInfo> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].label != b[i].label ||
          a[i].dataMode != b[i].dataMode ||
          a[i].user != b[i].user ||
          a[i].defaultExtensions.join(',') != b[i].defaultExtensions.join(',')) {
        return false;
      }
    }
    return true;
  }

  /// 테마 모드를 변경하고 메인 DB 에 저장한다(설정 창에서 호출).
  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _appDb?.setSetting(_themeSettingKey, AppTheme.modeToName(mode));
  }

  static Map<String, String> _strMap(Map raw) => {
        for (final e in raw.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };

  /// 프리셋 목록/기본값을 로드한다. 신규 키가 없으면 레거시 단일 설정(`llm`)을
  /// 프리셋 1개로 마이그레이션한다(없으면 빈 기본 프리셋 1개 생성).
  Future<void> _loadPresets() async {
    final raw = await _appDb!.getSetting(_presetsKey);
    if (raw is List && raw.isNotEmpty) {
      _presets = [
        for (final e in raw)
          if (e is Map) LlmPreset.fromJson(e.cast<String, Object?>()),
      ];
    } else {
      // 마이그레이션: 레거시 단일 설정 → 프리셋 1개.
      final legacy = await _appDb!.getSetting(_llmSettingKey);
      final cfg = legacy is Map
          ? LlmConfig.fromJson(Map<String, Object?>.from(legacy))
          : const LlmConfig();
      _presets = [
        LlmPreset(id: LlmPreset.newId(), name: 'Default', config: cfg),
      ];
      await _savePresets();
    }
    if (_presets.isEmpty) {
      _presets = [
        LlmPreset(id: LlmPreset.newId(), name: 'Default', config: const LlmConfig()),
      ];
      await _savePresets();
    }
    _defaultPresetId =
        (await _appDb!.getSetting(_defaultPresetKey) as String?) ?? '';
    // 기본 프리셋 id 가 유효하지 않으면 첫 프리셋으로 보정.
    if (_presetById(_defaultPresetId) == null) {
      _defaultPresetId = _presets.first.id;
      await _appDb!.setSetting(_defaultPresetKey, _defaultPresetId);
    }
  }

  Future<void> _savePresets() async {
    await _appDb?.setSetting(
        _presetsKey, _presets.map((p) => p.toJson()).toList());
  }

  /// 테스트 전용: 주어진 메인 DB 에서 프리셋/매핑만 로드한다(마이그레이션 포함).
  /// Python/도구 추출 등 무거운 초기화 없이 LLM 설정 로직만 검증하기 위함.
  @visibleForTesting
  Future<void> loadLlmForTest(AppDatabase db) async {
    _appDb = db;
    await _loadPresets();
    final tm = await db.getSetting(_toolModelsKey);
    if (tm is Map) _toolModels = _strMap(tm);
    final pm = await db.getSetting(_projectModelsKey);
    if (pm is Map) _projectModels = _strMap(pm);
  }

  /// 테스트 전용: 예제 뷰어 목록을 심는다(실제로는 init 이 에셋에서 읽는다).
  @visibleForTesting
  void setViewerExamplesForTest(List<ViewerExample> examples) {
    _viewerExamples = examples;
  }

  /// 테스트 전용: 주어진 메인 DB 에서 뷰어 목록/설정만 로드한다(마이그레이션 포함).
  @visibleForTesting
  Future<void> loadViewersForTest(AppDatabase db) async {
    _appDb = db;
    final vs = await db.getSetting(_viewerSourcesKey);
    if (vs is List) _viewerSources = _parseViewerSources(vs);
    final vr = await db.getSetting(_viewerRulesKey);
    if (vr is Map) _viewerRules = _parseViewerRules(vr);
    final vo = await db.getSetting(_viewerOrderKey);
    if (vo is List) _viewerOrder = vo.whereType<String>().toList();
    final vg = await db.getSetting(_viewerRegistryKey);
    if (vg is List) _registeredViewers = _parseViewerInfos(vg);
  }

  /// 테스트 전용: 주어진 메인 DB 를 붙이고 열린 프로젝트 목록만 읽는다.
  /// (실제로는 [init] 이 앱 지원 폴더의 DB 에서 읽는다.)
  @visibleForTesting
  Future<void> loadOpenProjectsForTest(AppDatabase db) async {
    _appDb = db;
    final op = await db.getSetting(_openProjectsKey);
    if (op is List) _pendingRestore = op.whereType<String>().toList();
    _pendingActive = (await db.getSetting(_activeProjectKey) as String?) ?? '';
  }

  /// 테스트 전용: 주어진 메인 DB 에서 도구 소스/비활성 목록만 로드한다.
  @visibleForTesting
  Future<void> loadToolsForTest(AppDatabase db) async {
    _appDb = db;
    final tm = await db.getSetting(_toolModulesKey);
    if (tm is List) _toolSources = _parseSources(tm);
    final dt = await db.getSetting(_disabledToolsKey);
    if (dt is List) _disabledTools = dt.whereType<String>().toSet();
  }

  /// 프리셋을 추가한다(반환: 추가된 프리셋). 첫 프리셋이면 기본으로 지정.
  Future<LlmPreset> addPreset({String name = '', LlmConfig? config}) async {
    final preset = LlmPreset(
      id: LlmPreset.newId(),
      name: name,
      config: config ?? const LlmConfig(),
    );
    _presets = [..._presets, preset];
    if (_defaultPresetId.isEmpty) _defaultPresetId = preset.id;
    notifyListeners();
    await _savePresets();
    await _appDb?.setSetting(_defaultPresetKey, _defaultPresetId);
    return preset;
  }

  /// 프리셋의 이름/설정을 갱신한다(id 기준).
  Future<void> updatePreset(String id, {String? name, LlmConfig? config}) async {
    var changed = false;
    _presets = [
      for (final p in _presets)
        if (p.id == id)
          (() {
            changed = true;
            return p.copyWith(name: name, config: config);
          })()
        else
          p,
    ];
    if (!changed) return;
    notifyListeners();
    await _savePresets();
  }

  /// 프리셋을 삭제한다. 마지막 1개는 삭제하지 않는다. 기본/매핑 참조도 정리.
  Future<void> removePreset(String id) async {
    if (_presets.length <= 1) return;
    _presets = _presets.where((p) => p.id != id).toList();
    // 도구/프로젝트 매핑에서 해당 id 참조 제거(→ 기본 프리셋 사용으로 환원).
    _toolModels = {
      for (final e in _toolModels.entries)
        if (e.value != id) e.key: e.value,
    };
    _projectModels = {
      for (final e in _projectModels.entries)
        if (e.value != id) e.key: e.value,
    };
    if (_defaultPresetId == id) _defaultPresetId = _presets.first.id;
    notifyListeners();
    await _savePresets();
    await _appDb?.setSetting(_defaultPresetKey, _defaultPresetId);
    await _appDb?.setSetting(_toolModelsKey, _toolModels);
    await _appDb?.setSetting(_projectModelsKey, _projectModels);
  }

  /// 기본 프리셋을 지정한다.
  Future<void> setDefaultPreset(String id) async {
    if (_presetById(id) == null || id == _defaultPresetId) return;
    _defaultPresetId = id;
    notifyListeners();
    await _appDb?.setSetting(_defaultPresetKey, id);
  }

  /// 도구(run_subagent/verify_work)의 모델 프리셋을 지정한다('' = 기본 사용).
  Future<void> setToolModel(String toolName, String presetId) async {
    final next = Map<String, String>.from(_toolModels);
    if (presetId.isEmpty) {
      next.remove(toolName);
    } else {
      next[toolName] = presetId;
    }
    _toolModels = next;
    notifyListeners();
    await _appDb?.setSetting(_toolModelsKey, _toolModels);
  }

  /// 프로젝트의 대화 모델 프리셋을 지정한다('' = 기본 사용).
  Future<void> setProjectModel(String projectPath, String presetId) async {
    final next = Map<String, String>.from(_projectModels);
    if (presetId.isEmpty) {
      next.remove(projectPath);
    } else {
      next[projectPath] = presetId;
    }
    _projectModels = next;
    notifyListeners();
    await _appDb?.setSetting(_projectModelsKey, _projectModels);
  }

  /// 최근 프로젝트 목록에서만 제거한다(실제 폴더/경로는 삭제하지 않음).
  Future<void> removeRecentProject(String path) async {
    await _appDb?.removeRecentProject(path);
    _recentProjects = await _appDb?.recentProjects() ?? const [];
    notifyListeners();
  }

  /// 새 대화의 기본 제목. `openProject` 를 부르기 전에 UI 가 l10n 값으로 채운다.
  ///
  /// 예전에는 여기 한국어 `'대화'` 가 박혀 있었다(§9-(5)). 컨트롤러에는
  /// `BuildContext` 가 없어 l10n 을 직접 못 읽으므로 바깥에서 넣어 준다.
  String newConversationTitle = 'Conversation';

  /// 세션이 생기거나 사라질 때 알린다. [AppLayout] 이 패널 목록을 맞추는 데 쓴다.
  ///
  /// 브리지를 만드는 데 필요한 UI 콜백(설정 창·도구 호출 내역 열기)도 여기서 받는다 —
  /// 컨트롤러는 위젯을 모르고, 위젯은 세션 수명을 모르기 때문이다.
  void Function(String section)? onOpenSettings;
  void Function(ProjectSession session, String callId)? onOpenActivity;

  /// 프로젝트를 연다. **이미 열려 있으면 그리로 이동만 한다.**
  ///
  /// ★ 예전에는 이 함수가 이전 프로젝트의 대화 DB 를 닫고 그 자리를 덮어썼다.
  /// 지금은 열린 것을 건드리지 않는다 — 돌고 있던 생성, 도구 호출 기록, 큐,
  /// 속도 실측이 그대로 남는다.
  Future<void> openProject(String path) async {
    final existing = sessionFor(path);
    if (existing != null) {
      activateProject(path);
      await _appDb?.touchRecentProject(path);
      _recentProjects = await _appDb?.recentProjects() ?? const [];
      notifyListeners();
      await _saveOpenProjects();
      return;
    }

    final session = await ProjectSession.open(
      path,
      browser: _browser,
      firstConversationTitle: newConversationTitle,
    );
    session.rebuildPythonEnv(_pythonInterpreterPath, useVenv: _useVenv);
    session.bridge = WebBridge(
      this,
      session,
      onOpenSettings: (s) => onOpenSettings?.call(s),
      onOpenActivity: (id) => onOpenActivity?.call(session, id),
    );
    await session.bridge!.start();
    // 파일 뷰어(네이티브 틀 + 뷰어 웹뷰). 뷰어 설정·사용자 뷰어가 이 컨트롤러에 있다.
    session.viewer = FileViewerController(this, session.files);
    // 세션의 변화(프로세스 시작/종료, venv 상태)를 앱 알림으로 올린다 —
    // 좌측 메뉴의 배지와 설정 창이 컨트롤러만 듣기 때문이다.
    session.addListener(notifyListeners);
    _sessions.add(session);
    _activePath = path;

    await _appDb?.touchRecentProject(path);
    _recentProjects = await _appDb?.recentProjects() ?? const [];
    notifyListeners();
    await _saveOpenProjects();

    // venv 생성은 시간이 걸릴 수 있어 프로젝트 열기를 막지 않고 백그라운드로.
    unawaited(session.ensureVenv());
  }

  /// 지난 실행에서 열려 있던 프로젝트들을 다시 연다.
  ///
  /// **[init] 이 아니라 화면이 준비된 뒤에 부른다**([AppLayout]) — 새 대화 제목이
  /// l10n 이고 컨트롤러에는 `BuildContext` 가 없다. 한 번만 실행된다.
  ///
  /// ⚠️ **[initialized] 전에 불리면 아무것도 하지 않고 그냥 돌아온다.**
  /// `main.dart` 가 `init()` 을 기다리지 않으므로 첫 프레임이 초기화보다 먼저 올 수
  /// 있다 — 그때 목록을 소비해 버리면 복원 기회를 영영 잃는다(실제로 그랬다).
  /// 호출측은 초기화가 끝난 뒤 **다시 불러야** 한다.
  ///
  /// 사라진 폴더는 조용히 건너뛰고 저장 목록에서도 지운다. 하나가 실패해도
  /// 나머지는 계속 연다 — 한 프로젝트의 DB 가 깨졌다고 전부 못 열면 안 된다.
  Future<void> restoreOpenProjects() async {
    if (!_initialized && _pendingRestore.isEmpty) return;
    final paths = _pendingRestore;
    final wanted = _pendingActive;
    if (paths.isEmpty) return;
    _pendingRestore = const [];
    _pendingActive = '';
    for (final path in paths) {
      if (isOpen(path)) continue;
      if (!Directory(path).existsSync()) continue;
      try {
        await openProject(path);
      } catch (_) {
        // 그 프로젝트만 건너뛴다.
      }
    }
    if (wanted.isNotEmpty && isOpen(wanted)) {
      _activePath = wanted;
      notifyListeners();
    }
    await _saveOpenProjects();
  }

  /// 열린 목록과 활성 경로를 메인 DB 에 남긴다(열기/닫기/전환 때마다).
  Future<void> _saveOpenProjects() async {
    await _appDb?.setSetting(
        _openProjectsKey, [for (final s in _sessions) s.path]);
    await _appDb?.setSetting(_activeProjectKey, _activePath);
  }

  /// 열린 프로젝트로 화면을 옮긴다(아무것도 닫지 않는다).
  void activateProject(String path) {
    if (_activePath == path || !isOpen(path)) return;
    _activePath = path;
    notifyListeners();
    unawaited(_saveOpenProjects());
  }

  /// 프로젝트를 닫는다. **돌고 있는 생성이 있으면 먼저 끊긴다.**
  ///
  /// 물어보는 것은 UI 의 몫이다([ProjectSession.isBusy] 로 판단). 여기까지 왔으면
  /// 사용자가 이미 동의한 것으로 본다.
  Future<void> closeProject(String path) async {
    final i = _sessions.indexWhere((s) => s.path == path);
    if (i < 0) return;
    final session = _sessions.removeAt(i);
    session.removeListener(notifyListeners);
    if (_activePath == path) {
      // 닫은 자리를 이어받는다 — 없으면 그 앞 프로젝트, 그것도 없으면 빈 화면.
      final next = i < _sessions.length
          ? _sessions[i]
          : (_sessions.isEmpty ? null : _sessions.last);
      _activePath = next?.path ?? '';
    }
    notifyListeners();
    await _saveOpenProjects();
    await session.close();
    session.dispose();
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      s.removeListener(notifyListeners);
      unawaited(s.close());
    }
    _sessions.clear();
    _browser.dispose();
    _appDb?.close();
    super.dispose();
  }
}
