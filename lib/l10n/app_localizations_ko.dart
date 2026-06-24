// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class AppLocalizationsKo extends AppLocalizations {
  AppLocalizationsKo([String locale = 'ko']) : super(locale);

  @override
  String get appTitle => 'Collabo IDE';

  @override
  String get settingsTitle => '설정';

  @override
  String get tabModel => '모델';

  @override
  String get tabTools => '도구';

  @override
  String get tabPrompt => '프롬프트';

  @override
  String get tabAppearance => '모양';

  @override
  String get systemPromptDesc =>
      '모든 대화 시작 시 전달되는 시스템 프롬프트(실행 전략)입니다. 비워두면 기본값이 사용됩니다.';

  @override
  String get usePreAssessment => '사전 평가 사용하기';

  @override
  String get usePreAssessmentDesc =>
      '답변 전에 서브에이전트가 마지막 요청을 보고 위임이 필요한지 한 줄 의견을 덧붙입니다.';

  @override
  String get resetDefault => '기본값으로 되돌리기';

  @override
  String get close => '닫기';

  @override
  String get cancel => '취소';

  @override
  String get create => '생성';

  @override
  String get add => '추가';

  @override
  String get remove => '제거';

  @override
  String get save => '저장';

  @override
  String get saved => '저장됨';

  @override
  String get selectButton => '선택';

  @override
  String get theme => '테마';

  @override
  String get themeLight => '라이트';

  @override
  String get themeDark => '다크';

  @override
  String get themeSystem => '시스템 설정 따름';

  @override
  String get language => '언어';

  @override
  String get languageSystem => '시스템';

  @override
  String get navNewProject => '새 프로젝트';

  @override
  String get navOpenProject => '프로젝트 열기';

  @override
  String get noProjectTitle => '열린 프로젝트가 없습니다';

  @override
  String get startNewProject => '새 프로젝트 시작';

  @override
  String get navSettings => '설정';

  @override
  String get navCollapse => '접기';

  @override
  String get activityTitle => '진행 상태';

  @override
  String activityRunningLabel(int count) {
    return '실행 중 ($count)';
  }

  @override
  String activityRunningTooltip(int count) {
    return '실행 중 프로세스: $count';
  }

  @override
  String get activityIdleTooltip => '실행 중 프로세스 없음';

  @override
  String get newProjectTitle => '새 프로젝트';

  @override
  String get selectParentPath => '상위 경로를 선택하세요';

  @override
  String get selectPath => '경로 선택';

  @override
  String get projectNameLabel => '프로젝트 이름 (폴더명)';

  @override
  String createLocation(String path) {
    return '생성 위치: $path';
  }

  @override
  String get pathExists => '같은 이름의 프로젝트(경로)가 이미 존재합니다.';

  @override
  String createFailed(String error) {
    return '폴더 생성 실패: $error';
  }

  @override
  String get nameEmpty => '이름을 입력하세요.';

  @override
  String get nameInvalidChars => '사용할 수 없는 문자가 있습니다: < > : \" / \\ | ? *';

  @override
  String get nameInvalidName => '사용할 수 없는 이름입니다.';

  @override
  String get nameTrailingDot => '이름은 마침표(.)나 공백으로 끝날 수 없습니다.';

  @override
  String get nameReserved => '예약된 이름은 사용할 수 없습니다.';

  @override
  String get connectionMethod => '연결 방식';

  @override
  String get openaiCompatible => 'OpenAI 호환 API';

  @override
  String get modelLabel => '모델';

  @override
  String get testConnection => '연결 상태 확인';

  @override
  String get toolsDescription =>
      'LLM 이 function calling 으로 호출하는 도구입니다. 기본은 고정이며, 일반 Python 스크립트(--help 자동 분석)나 MCP 서버를 추가할 수 있습니다.';

  @override
  String get addTool => '도구 추가';

  @override
  String get addToolCli => '일반 Python 스크립트';

  @override
  String get addToolCliDesc => '--help 를 분석해 도구 JSON 을 자동 생성';

  @override
  String get addToolMcp => 'MCP 도구';

  @override
  String get addToolMcpDesc => '내장 Python 으로 MCP 서버를 제어해 tools 추가';

  @override
  String get mcpAddTitle => 'MCP 도구 추가';

  @override
  String get mcpCommand => '서버 실행 명령';

  @override
  String get mcpCommandHint => '예: npx 또는 python';

  @override
  String get mcpArgs => '인자(공백 구분)';

  @override
  String get mcpArgsHint => '예: -y @modelcontextprotocol/server-filesystem .';

  @override
  String get nameOptional => '이름(선택)';

  @override
  String get toolInspect => '도구 검사';

  @override
  String get pythonNotReadyInspect =>
      'Python 환경이 준비되지 않았습니다. 인터프리터를 선택 후 다시 시도하세요.';

  @override
  String get toolInfoFailed => '도구 정보를 가져오지 못했습니다.';

  @override
  String toolsCount(String name, int count) {
    return '$name 도구 ($count)';
  }

  @override
  String get baseModuleLabel => 'collabo_base (기본)';

  @override
  String get extractPending => '추출 대기 중…';

  @override
  String get viewTools => '도구 보기';

  @override
  String get pythonEnv => 'Python 환경';

  @override
  String get statusCheck => '상태 확인';

  @override
  String get pythonSettings => 'Python 설정';

  @override
  String get pythonNotSetTitle => 'Python 미설정';

  @override
  String get pythonNotSetBody => '먼저 \"Python 설정\"에서 인터프리터를 선택하세요.';

  @override
  String get pythonCheckTitle => 'Python 환경 점검';

  @override
  String get selectPythonPrompt => '사용할 Python 인터프리터를 선택하세요.';

  @override
  String get notSelected => '선택되지 않음';

  @override
  String get selectPython => 'Python 선택';

  @override
  String get pythonVerified => '확인됨';

  @override
  String get pythonMissing => '해당 경로에 인터프리터가 없습니다.';

  @override
  String get pythonMissingQuestion => 'Python 이 없나요? ';

  @override
  String get downloadFromPythonOrg => 'python.org 에서 다운로드';

  @override
  String get allFiles => '모든 파일';

  @override
  String get console => '콘솔';

  @override
  String get consoleStarting => '시작 중…';

  @override
  String get consoleInputHint => '입력 후 Enter (예: y / n)';

  @override
  String get consoleEnded => '프로세스가 종료되었습니다';

  @override
  String consoleProcessExited(int code) {
    return '[프로세스 종료: $code]';
  }

  @override
  String consoleExecFailed(String error) {
    return '실행 실패: $error';
  }

  @override
  String get webviewUnsupported => '이 플랫폼의 웹뷰 백엔드는 아직 연결되지 않았습니다.';

  @override
  String webviewInitFailed(String error) {
    return '웹뷰 초기화 실패\n$error';
  }

  @override
  String get webviewRuntimeMissing =>
      '이 화면을 표시하려면 Microsoft Edge WebView2 런타임이 필요합니다.\n설치 후 앱을 다시 시작하세요.';

  @override
  String get webviewRuntimeDownload => 'WebView2 런타임 다운로드';

  @override
  String get noOpenProject => '열린 프로젝트 없음';

  @override
  String get wizardTitle => '초기 설정';

  @override
  String get wizardIntro =>
      'Collabo IDE 사용 준비를 도와드릴게요. 모든 항목은 나중에 설정에서 바꿀 수 있어요.';

  @override
  String wizardStep(int current, int total) {
    return '$total단계 중 $current단계';
  }

  @override
  String get next => '다음';

  @override
  String get back => '이전';

  @override
  String get finish => '완료';

  @override
  String get skipSetup => '건너뛰기';
}
