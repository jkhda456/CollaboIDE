import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../conversation/conversation_store.dart';
import '../data/app_database.dart';
import '../llm/llm_config.dart';
import '../llm/llm_preset.dart';
import '../llm/system_prompt.dart';
import '../process/background_process_registry.dart';
import '../process/process_manager.dart';
import '../process/python_environment.dart';
import '../tools/tool_assets.dart';
import '../tools/tool_source.dart';
import '../ui/app_theme.dart';

/// 프로젝트별 venv 준비 상태.
enum VenvStatus { idle, creating, ready, error }

/// 앱 전역 상태의 중심. 메인 DB, 현재 프로젝트, 프로젝트 대화 DB,
/// 런쳐 프로세스 매니저, LLM 설정, 최근 프로젝트 목록을 한곳에서 묶는다.
class WorkspaceController extends ChangeNotifier {
  AppDatabase? _appDb;
  ProcessManager? _processManager;
  PythonEnvironment? _pythonEnv;

  /// 백그라운드 명령(run_command) 레지스트리 — `.collabo/proc` 를 읽어 추적한다.
  final BackgroundProcessRegistry _backgroundProcesses =
      BackgroundProcessRegistry();

  String? _projectPath;

  /// 프로젝트별 venv 사용 여부(전역 정책, 기본 켜짐). venv 인스턴스는 각 프로젝트의
  /// `<project>/.collabo/venv` 에 자동 생성된다.
  bool _useVenv = true;
  VenvStatus _venvStatus = VenvStatus.idle;
  String _venvError = '';
  ConversationStore? _conversation;
  int? _activeConversationId;
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

  /// 고정 기본 도구 모듈(Python) 스크립트 경로. init 에서 추출.
  String? _baseToolModulePath;

  /// 사용자가 추가한 도구 소스(일반 CLI / MCP). (설정에 저장, tools 로 확장)
  List<ToolSource> _toolSources = const [];

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

  /// 초기 설정 마법사 완료(또는 건너뜀) 여부. 메인 DB 에 영구 저장.
  bool _setupDone = false;

  /// init() 완료 여부. 첫 실행 판단은 DB 로드가 끝난 뒤에만 한다.
  bool _initialized = false;

  static const String _themeSettingKey = 'theme_mode';
  static const String _llmSettingKey = 'llm'; // 레거시(단일 설정) — 마이그레이션 원본
  static const String _presetsKey = 'llm_presets';
  static const String _defaultPresetKey = 'llm_default_preset';
  static const String _toolModelsKey = 'llm_tool_models';
  static const String _projectModelsKey = 'llm_project_models';
  static const String _toolModulesKey = 'tool_modules';
  static const String _pythonKey = 'python_interpreter';
  static const String _useVenvKey = 'python_use_venv';

  /// 프로젝트 폴더 안에서 venv 를 두는 상대 경로.
  static const List<String> _venvSubdir = ['.collabo', 'venv'];
  static const String _localeKey = 'locale';
  static const String _systemPromptKey = 'system_prompt';
  static const String _setupDoneKey = 'setup_done';
  static const String _workspaceDirKey = 'workspace_dir';
  static const String _preAssessmentKey = 'pre_assessment';

  String? get projectPath => _projectPath;
  bool get hasProject => _projectPath != null;
  ConversationStore? get conversation => _conversation;
  int? get activeConversationId => _activeConversationId;
  ProcessManager? get processManager => _processManager;

  /// 백그라운드 명령 레지스트리(좌측 활동 배지 + 프로세스 뷰어가 사용).
  BackgroundProcessRegistry get backgroundProcesses => _backgroundProcesses;
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
    final path = projectPath ?? _projectPath;
    if (path != null) {
      final id = _projectModels[path];
      if (id != null && id.isNotEmpty) {
        final p = _presetById(id);
        if (p != null) return p.config;
      }
    }
    return defaultPreset.config;
  }

  /// 도구(run_subagent/verify_work)에 쓸 연결 설정.
  /// 도구에 지정된 프리셋이 있으면 그것을, 없으면 기본 프리셋을 쓴다.
  LlmConfig configForTool(String toolName) {
    final id = _toolModels[toolName];
    if (id != null && id.isNotEmpty) {
      final p = _presetById(id);
      if (p != null) return p.config;
    }
    return defaultPreset.config;
  }

  /// 도구에 지정된 프리셋 id('' = 기본 사용).
  String presetIdForTool(String toolName) => _toolModels[toolName] ?? '';

  /// 프로젝트에 지정된 프리셋 id('' = 기본 사용).
  String presetIdForProject([String? projectPath]) {
    final path = projectPath ?? _projectPath;
    if (path == null) return '';
    return _projectModels[path] ?? '';
  }

  /// 현재 시스템 프롬프트(미설정이면 기본값).
  String get systemPrompt =>
      _systemPrompt.trim().isEmpty ? kDefaultSystemPrompt : _systemPrompt;

  /// 사용자가 저장한 원본(편집 화면 표시용; 비어 있으면 기본값을 보여준다).
  String get systemPromptRaw =>
      _systemPrompt.isEmpty ? kDefaultSystemPrompt : _systemPrompt;
  String? get baseToolModulePath => _baseToolModulePath;
  List<ToolSource> get toolSources => _toolSources;

  /// 첫 실행(데이터가 전혀 준비되지 않음) 여부 → 초기 설정 마법사 표시 조건.
  /// 초기화 완료 후, 설정 미완료 + LLM 미설정 + Python 미선택 + 최근 프로젝트 없음.
  bool get needsFirstRunSetup =>
      _initialized &&
      !_setupDone &&
      !llmConfig.isConfigured &&
      _pythonInterpreterPath.isEmpty &&
      _recentProjects.isEmpty;

  /// 추출된 도구 모듈/어댑터 디렉토리(cli_adapter.py, mcp_adapter.py 위치).
  String? get toolAdaptersDir =>
      _baseToolModulePath != null ? p.dirname(_baseToolModulePath!) : null;

  /// 선택된 base Python 인터프리터 경로(미설정이면 null).
  String? get pythonInterpreter =>
      _pythonInterpreterPath.isEmpty ? null : _pythonInterpreterPath;

  /// 실제 스크립트/도구 실행에 쓰는 **실효 파이썬**(venv 준비 시 venv, 아니면 base).
  /// 미설정이면 null. 상태확인(env_check)·pip 도 이걸 써야 tools 와 동일 환경을
  /// 대상으로 한다(base 로 설치하면 Homebrew/시스템 파이썬의 PEP 668 로 막힌다).
  String? get effectivePython {
    final e = _pythonEnv;
    if (e == null || !e.isInstalled) return null;
    return e.executablePath;
  }

  bool get pythonInstalled => _pythonEnv?.isInstalled ?? false;
  PythonEnvironment? get pythonEnv => _pythonEnv;

  /// 프로젝트별 venv 사용 여부(전역 정책).
  bool get useVenv => _useVenv;

  /// 현재 프로젝트의 venv 준비 상태.
  VenvStatus get venvStatus => _venvStatus;

  /// venv 생성 실패 메시지(없으면 빈 문자열).
  String get venvError => _venvError;

  /// 현재 프로젝트에 적용될 venv 경로(미사용/프로젝트 없음이면 null).
  String? get venvPath => _effectiveVenvPath();

  String? _effectiveVenvPath() {
    final root = _projectPath;
    if (!_useVenv || root == null || root.isEmpty) return null;
    return p.join(root, _venvSubdir[0], _venvSubdir[1]);
  }

  /// 현재 base 인터프리터 + 프로젝트 venv 경로로 Python 환경/프로세스 매니저를 재구성한다.
  void _rebuildPythonEnv() {
    final env =
        PythonEnvironment(_pythonInterpreterPath, venvPath: _effectiveVenvPath());
    _pythonEnv = env;
    _processManager?.updateEnvironment(env);
  }

  /// 현재 프로젝트의 venv 를 (없으면) 생성한다. 상태를 갱신하며 알림.
  /// venv 미사용/프로젝트 없음/base 미설정이면 조용히 넘어간다.
  Future<void> _ensureVenv() async {
    final env = _pythonEnv;
    if (env == null || env.venvPath == null) {
      _venvStatus = VenvStatus.idle;
      _venvError = '';
      notifyListeners();
      return;
    }
    if (env.venvReady) {
      _venvStatus = VenvStatus.ready;
      _venvError = '';
      notifyListeners();
      return;
    }
    if (!env.isInstalled) return; // base 미설정: 인터프리터 지정 시 다시 시도됨.
    _venvStatus = VenvStatus.creating;
    _venvError = '';
    notifyListeners();
    final r = await env.ensureVenv();
    // 도중에 프로젝트/설정이 바뀌었으면 결과를 버린다(경합 방지).
    if (!identical(env, _pythonEnv)) return;
    if (r.ok) {
      _venvStatus = VenvStatus.ready;
      _venvError = '';
    } else {
      _venvStatus = VenvStatus.error;
      _venvError = r.error ?? 'Failed to create venv.';
    }
    notifyListeners();
  }

  /// 프로젝트별 venv 사용 여부를 변경/저장한다(설정 → 도구 → Python).
  Future<void> setUseVenv(bool value) async {
    if (value == _useVenv) return;
    _useVenv = value;
    _rebuildPythonEnv();
    notifyListeners();
    await _appDb?.setSetting(_useVenvKey, value);
    await _ensureVenv();
  }

  /// 현재 프로젝트의 venv 를 삭제 후 재생성한다(설정의 "재생성" 버튼).
  Future<void> recreateVenv() async {
    final vp = _effectiveVenvPath();
    if (vp == null) return;
    try {
      final dir = Directory(vp);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    _rebuildPythonEnv(); // venvReady 캐시 없음 — 안전하게 재구성.
    await _ensureVenv();
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
    // 레지스트리 변경(프로세스 시작/종료)을 컨트롤러 알림으로 포워드 —
    // AppLayout 은 컨트롤러만 listen 하므로 배지/뷰어가 실시간 갱신된다.
    _backgroundProcesses.addListener(notifyListeners);
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
    _pythonInterpreterPath =
        (await _appDb!.getSetting(_pythonKey) as String?) ?? '';
    _useVenv = (await _appDb!.getSetting(_useVenvKey) as bool?) ?? true;
    _localeCode = (await _appDb!.getSetting(_localeKey) as String?) ?? 'system';
    _systemPrompt = (await _appDb!.getSetting(_systemPromptKey) as String?) ?? '';
    _setupDone = (await _appDb!.getSetting(_setupDoneKey) as bool?) ?? false;
    _lastWorkspaceDir =
        (await _appDb!.getSetting(_workspaceDirKey) as String?) ?? '';
    _preAssessment =
        (await _appDb!.getSetting(_preAssessmentKey) as bool?) ?? true;

    final env = PythonEnvironment(_pythonInterpreterPath);
    _pythonEnv = env;
    _processManager = ProcessManager(env);
    _baseToolModulePath = await ToolAssets.extractBaseModule();
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

  /// 사전 평가(트리아지) 사용 여부.
  bool get preAssessment => _preAssessment;

  /// 사전 평가 사용 여부를 변경/저장한다(설정 → 프롬프트 토글).
  Future<void> setPreAssessment(bool value) async {
    if (value == _preAssessment) return;
    _preAssessment = value;
    notifyListeners();
    await _appDb?.setSetting(_preAssessmentKey, value);
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
    _rebuildPythonEnv();
    notifyListeners();
    await _appDb?.setSetting(_pythonKey, path);
    await _ensureVenv();
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
    notifyListeners();
    await _saveSources();
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

  /// 프로젝트를 연다: 이전 대화 DB 닫기 → 새 대화 DB 열기 → 활성 대화 확보 → MRU 갱신.
  Future<void> openProject(String path) async {
    await _conversation?.close();
    final store = await ConversationStore.openForProject(path);
    _conversation = store;
    _projectPath = path;
    _backgroundProcesses.attachProject(path);

    // 새 프로젝트의 venv 경로로 Python 환경 재구성 + (필요 시) venv 백그라운드 생성.
    _venvStatus = VenvStatus.idle;
    _venvError = '';
    _rebuildPythonEnv();

    // 활성(메인) 대화 확보: 최근 메인 대화가 있으면 재사용, 없으면 새로 생성.
    final mains = await store.listMainConversations();
    _activeConversationId =
        mains.isNotEmpty ? mains.first.id : await store.createConversation(title: '대화');

    await _appDb?.touchRecentProject(path);
    _recentProjects = await _appDb?.recentProjects() ?? const [];
    notifyListeners();

    // venv 생성은 시간이 걸릴 수 있어 프로젝트 열기를 막지 않고 백그라운드로.
    unawaited(_ensureVenv());
  }

  @override
  void dispose() {
    _backgroundProcesses.removeListener(notifyListeners);
    _backgroundProcesses.dispose();
    _conversation?.close();
    _processManager?.dispose();
    _appDb?.close();
    super.dispose();
  }
}
