import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../conversation/conversation_store.dart';
import '../data/app_database.dart';
import '../llm/llm_config.dart';
import '../llm/system_prompt.dart';
import '../process/process_manager.dart';
import '../process/python_environment.dart';
import '../tools/tool_assets.dart';
import '../tools/tool_source.dart';
import '../ui/app_theme.dart';

/// 앱 전역 상태의 중심. 메인 DB, 현재 프로젝트, 프로젝트 대화 DB,
/// 런쳐 프로세스 매니저, LLM 설정, 최근 프로젝트 목록을 한곳에서 묶는다.
class WorkspaceController extends ChangeNotifier {
  AppDatabase? _appDb;
  ProcessManager? _processManager;
  PythonEnvironment? _pythonEnv;

  String? _projectPath;
  ConversationStore? _conversation;
  int? _activeConversationId;
  List<RecentProject> _recentProjects = const [];

  /// 테마 모드. 기본값은 라이트. (설정으로 관리, 메인 DB 에 영구 저장)
  ThemeMode _themeMode = ThemeMode.light;

  /// LLM 연결 설정. (설정 창에서 관리, 메인 DB 에 영구 저장)
  LlmConfig _llmConfig = const LlmConfig();

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
  static const String _llmSettingKey = 'llm';
  static const String _toolModulesKey = 'tool_modules';
  static const String _pythonKey = 'python_interpreter';
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
  List<RecentProject> get recentProjects => _recentProjects;
  ThemeMode get themeMode => _themeMode;
  LlmConfig get llmConfig => _llmConfig;

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
      !_llmConfig.isConfigured &&
      _pythonInterpreterPath.isEmpty &&
      _recentProjects.isEmpty;

  /// 추출된 도구 모듈/어댑터 디렉토리(cli_adapter.py, mcp_adapter.py 위치).
  String? get toolAdaptersDir =>
      _baseToolModulePath != null ? p.dirname(_baseToolModulePath!) : null;

  /// 선택된 Python 인터프리터 경로(미설정이면 null).
  String? get pythonInterpreter =>
      _pythonInterpreterPath.isEmpty ? null : _pythonInterpreterPath;
  bool get pythonInstalled => _pythonEnv?.isInstalled ?? false;
  PythonEnvironment? get pythonEnv => _pythonEnv;

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
    final llmJson = await _appDb!.getSetting(_llmSettingKey);
    if (llmJson is Map) {
      _llmConfig = LlmConfig.fromJson(Map<String, Object?>.from(llmJson));
    }
    final tm = await _appDb!.getSetting(_toolModulesKey);
    if (tm is List) _toolSources = _parseSources(tm);
    _pythonInterpreterPath =
        (await _appDb!.getSetting(_pythonKey) as String?) ?? '';
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

  /// 사용할 Python 인터프리터를 선택/저장한다.
  Future<void> setPythonInterpreter(String path) async {
    _pythonInterpreterPath = path;
    final env = PythonEnvironment(path);
    _pythonEnv = env;
    _processManager?.updateEnvironment(env);
    notifyListeners();
    await _appDb?.setSetting(_pythonKey, path);
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

  /// LLM 설정을 변경하고 메인 DB 에 저장한다.
  Future<void> setLlmConfig(LlmConfig config) async {
    _llmConfig = config;
    notifyListeners();
    await _appDb?.setSetting(_llmSettingKey, config.toJson());
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

    // 활성(메인) 대화 확보: 최근 메인 대화가 있으면 재사용, 없으면 새로 생성.
    final mains = await store.listMainConversations();
    _activeConversationId =
        mains.isNotEmpty ? mains.first.id : await store.createConversation(title: '대화');

    await _appDb?.touchRecentProject(path);
    _recentProjects = await _appDb?.recentProjects() ?? const [];
    notifyListeners();
  }

  @override
  void dispose() {
    _conversation?.close();
    _processManager?.dispose();
    _appDb?.close();
    super.dispose();
  }
}
