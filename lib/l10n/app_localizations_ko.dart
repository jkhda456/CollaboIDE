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
  String get tabViewers => '뷰어';

  @override
  String get tabWeb => '웹 검색';

  @override
  String get tabPrompt => '프롬프트';

  @override
  String get tabAppearance => '모양';

  @override
  String get tabAbout => '정보';

  @override
  String aboutVersion(String version, String build) {
    return '버전 $version (빌드 $build)';
  }

  @override
  String get openSourceTitle => '오픈소스';

  @override
  String get openSourceIntro => '다음 오픈소스 구성요소로 만들었습니다. 전체 라이선스는 아래에서 확인하세요.';

  @override
  String get viewLicenses => '오픈소스 라이선스 전체 보기';

  @override
  String get systemPromptDesc => '대화를 시작할 때마다 전달하는 실행 전략입니다. 비워 두면 기본값을 씁니다.';

  @override
  String get usePreAssessment => '사전 평가 사용하기';

  @override
  String get usePreAssessmentDesc => '답변하기 전에 서브에이전트가 위임이 필요한지 한 줄로 짚어 줍니다.';

  @override
  String get useProjectState => '프로젝트 상태 알려주기';

  @override
  String get useProjectStateDesc =>
      '폴더 구조와 변경된 파일을 함께 알려 주어 같은 작업을 반복하지 않게 합니다.';

  @override
  String get usePlanMemory => '계획 메모리 사용하기';

  @override
  String get usePlanMemoryDesc =>
      '목표와 계획을 .collabo/PLAYBOOK.md 에 남겨, 대화가 줄어들어도 계획이 사라지지 않게 합니다.';

  @override
  String get useSupervisor => '감독자 사용하기';

  @override
  String get useSupervisorDesc =>
      '같은 도구나 오류를 반복하면 단계적으로 개입하고, 계획에 남은 단계가 있는데 끝내려 하면 되돌려보냅니다.';

  @override
  String get planCard => '계획';

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
  String get saved => '저장했습니다';

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
  String get navWebSearch => '웹 검색';

  @override
  String get conversation => '대화';

  @override
  String get closeProject => '프로젝트 닫기';

  @override
  String get recentProjectsTitle => '최근 프로젝트';

  @override
  String get projectBusy => '작업 중입니다';

  @override
  String get closeBusyProjectTitle => '아직 작업이 진행 중입니다';

  @override
  String closeBusyProjectBody(String name) {
    return '$name 에서 생성이 돌고 있습니다. 닫으면 그 작업이 중단됩니다. 다른 프로젝트는 영향을 받지 않습니다.';
  }

  @override
  String get browserBack => '뒤로';

  @override
  String get browserForward => '앞으로';

  @override
  String get browserReload => '새로고침';

  @override
  String get browserStop => '중지';

  @override
  String get browserNewTab => '새 탭';

  @override
  String get browserCloseTab => '탭 닫기';

  @override
  String get browserCloseAll => '모든 탭 닫기';

  @override
  String get browserCloseAgentTabs => '에이전트 탭 모두 닫기';

  @override
  String get browserAddressHint => '검색어나 주소를 입력하세요';

  @override
  String get browserEmpty => '열린 탭이 없습니다';

  @override
  String get browserUnsupported => '이 플랫폼에서는 웹 브라우저를 아직 쓸 수 없습니다.';

  @override
  String get searchEngine => '검색 엔진';

  @override
  String get searchEngineDesc =>
      '에이전트의 web_search 도구와 브라우저 위 주소창이 함께 씁니다. 엔진은 파이썬 모듈 collabo_web.py 에 정의되어 있어 거기서 늘릴 수 있습니다.';

  @override
  String get browserUserAgent => '브라우저 User-Agent';

  @override
  String get browserUserAgentDesc =>
      '비워 두면 플랫폼 기본값을 씁니다. 일반 브라우저가 보내는 값이라 자동화를 막는 사이트에서 가장 잘 동작합니다. 지금부터 여는 탭에 적용됩니다.';

  @override
  String get browserUserAgentHint => '플랫폼 기본값';

  @override
  String get activityTitle => '진행 상태';

  @override
  String activityRunningLabel(int count) {
    return '실행 중 ($count)';
  }

  @override
  String activityRunningTooltip(int count) {
    return '프로세스 $count개가 실행 중입니다';
  }

  @override
  String get activityIdleTooltip => '실행 중인 프로세스가 없습니다';

  @override
  String get activityTitleNative => '도구 호출 내역';

  @override
  String get activityEmptyNative => '아직 도구를 호출하지 않았습니다.';

  @override
  String get activitySelectHint => '호출을 선택하면 인자와 결과 원문을 볼 수 있습니다.';

  @override
  String get activityArgs => '인자';

  @override
  String get activityResult => '결과';

  @override
  String get activityClear => '기록 비우기';

  @override
  String get activityScopeMain => '메인';

  @override
  String get activityScopeSub => '서브에이전트';

  @override
  String get activityScopeVerify => '검증';

  @override
  String get activityScopeDelegate => '위임';

  @override
  String get copy => '복사';

  @override
  String get procTitle => '프로세스';

  @override
  String get procEmpty => '백그라운드 프로세스가 없습니다.';

  @override
  String get procSelectHint => '출력을 보려면 프로세스를 선택하세요.';

  @override
  String get procStatusRunning => '실행 중입니다';

  @override
  String procStatusExited(int code) {
    return '종료했습니다 (코드 $code)';
  }

  @override
  String get procStatusKilled => '중지했습니다';

  @override
  String get procStop => '종료';

  @override
  String get procInputHint => '표준 입력 보내기…';

  @override
  String get procSend => '보내기';

  @override
  String get procStdout => 'stdout';

  @override
  String get procStderr => 'stderr';

  @override
  String get procTerminal => '터미널';

  @override
  String get procTerminalInputHint => '터미널에 입력하세요';

  @override
  String get procNoPty => '가상 터미널을 쓸 수 없어 이 세션에서는 대화형 프로그램이 동작하지 않습니다.';

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
  String get pathExists => '같은 이름의 프로젝트가 이미 있습니다.';

  @override
  String createFailed(String error) {
    return '폴더를 만들지 못했습니다: $error';
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
  String get presetLabel => '프리셋';

  @override
  String get presetNameLabel => '프리셋 이름';

  @override
  String get addPreset => '프리셋 추가';

  @override
  String get deletePreset => '프리셋 삭제';

  @override
  String get newPresetName => '새 프리셋';

  @override
  String get defaultBadge => '기본';

  @override
  String get setAsDefault => '기본으로 지정';

  @override
  String get isDefaultPreset => '기본 프리셋';

  @override
  String get renamePreset => '프리셋 이름 변경';

  @override
  String get selectPreset => '프리셋 선택';

  @override
  String get connectionMethod => '연결 방식';

  @override
  String get openaiCompatible => 'OpenAI 호환 API';

  @override
  String get openaiPrompted => 'OpenAI 호환 (강제 프롬프트)';

  @override
  String get modelLabel => '모델';

  @override
  String get multimodalSupport => '멀티모달 지원';

  @override
  String get multimodalSupportDesc =>
      '대화에서 + 버튼으로 이미지를 첨부할 수 있습니다. 이미지를 읽는 모델에서만 켜세요.';

  @override
  String get parseTextToolCalls => '본문 텍스트에서 도구 호출 파싱';

  @override
  String get parseTextToolCallsDesc =>
      '도구 호출을 본문 텍스트로 흘려보내는 비표준 서버를 위한 폴백입니다. 표준 서버에는 필요 없습니다.';

  @override
  String get reasoningEffort => '추론강도 옵션 붙이기';

  @override
  String get reasoningEffortDesc =>
      '\'안 붙이기\'는 reasoning_effort 를 보내지 않고, 나머지는 그대로 전달합니다. 이 옵션을 아는 모델에서만 쓰세요.';

  @override
  String get reasoningEffortOff => '안 붙이기';

  @override
  String get firstResponseTimeout => '첫 응답(프리필) 대기 시간';

  @override
  String get firstResponseTimeoutDesc =>
      '요청을 보낸 뒤 첫 응답까지만 적용합니다. 0 은 제한 없음이며, 기다리는 동안에도 언제든 중지할 수 있습니다.';

  @override
  String get secondsUnit => '초';

  @override
  String get tokensUnit => '토큰';

  @override
  String get noLimit => '제한 없음';

  @override
  String get responseTokenBudget => '응답 하나의 토큰 예산';

  @override
  String get responseTokenBudgetDesc =>
      '이만큼의 토큰을 뽑을 시간까지 기다립니다. 느린 모델일수록 더 오래 기다리고, 0 은 제한 없음입니다.';

  @override
  String get tokPerSec => '처리 속도 (tok/s)';

  @override
  String get tokPerSecDesc =>
      '비워 두면 실제 응답에서 재서 씁니다. 값을 넣으면 그 값을 씁니다. 지금 이 연결의 응답 상한';

  @override
  String get tokPerSecAuto => '비워 두면 자동으로 측정합니다 (그때까지는 100 tok/s 로 봅니다)';

  @override
  String tokPerSecMeasured(String tps) {
    return '자동으로 측정했습니다: $tps tok/s';
  }

  @override
  String get testConnection => '연결 상태 확인';

  @override
  String get showKey => '키 보기';

  @override
  String get hideKey => '키 숨기기';

  @override
  String get useDefaultModel => '기본 모델 사용';

  @override
  String get toolSubagentLabel => '서브에이전트 (run_subagent)';

  @override
  String get toolVerifyLabel => '검증 (verify_work)';

  @override
  String get toolsDescription =>
      'LLM 이 function calling 으로 부르는 도구입니다. Python 스크립트나 MCP 서버를 추가할 수 있습니다.';

  @override
  String get addTool => '도구 추가';

  @override
  String get addToolCli => '일반 Python 스크립트';

  @override
  String get addToolCliDesc => '--help 를 분석해 도구 JSON 을 자동으로 만듭니다';

  @override
  String get addToolMcp => 'MCP 도구';

  @override
  String get addToolMcpDesc => '내장 Python 으로 MCP 서버를 제어해 도구를 추가합니다';

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
  String get sandboxNotReadyInspect =>
      '도구 실행 환경이 준비되지 않았습니다. 설정 → 도구에서 샌드박스 상태를 확인하세요.';

  @override
  String get toolInfoFailed => '도구 정보를 가져오지 못했습니다.';

  @override
  String toolsCount(String name, int count) {
    return '$name 도구 ($count)';
  }

  @override
  String get extractPending => '도구를 꺼내는 중입니다…';

  @override
  String get viewTools => '도구 보기';

  @override
  String get toolToggleDesc =>
      '체크를 끄면 그 도구를 에이전트에게 넘기지 않습니다. 설정은 남아 있어 언제든 다시 켤 수 있습니다.';

  @override
  String get toolListLoading => '도구 목록을 읽는 중입니다…';

  @override
  String get toolNativeFixed => '앱이 직접 실행하며 끌 수 없습니다';

  @override
  String get viewersDesc => '파일 뷰어를 JS 파일로 확장합니다. 추가하면 보기 방식 드롭다운에 바로 나타납니다.';

  @override
  String get viewerRulesTitle => '확장자 연결';

  @override
  String get viewerRulesDesc =>
      '각 뷰어가 담당할 확장자를 정합니다. 비워 두면 아무도 담당하지 않는 파일에만 쓰이고, 체크를 끄면 그 뷰어를 쓰지 않습니다. 같은 확장자를 여러 뷰어가 담당하면 위에 있는 뷰어가 이깁니다.';

  @override
  String get viewerOrderReset => '순서 초기화';

  @override
  String get viewerReorderTooltip => '끌어서 순서 변경';

  @override
  String get viewerUserFilesTitle => '사용자 뷰어 파일';

  @override
  String get viewerExampleDesc =>
      '앱에 들어 있는 예제 뷰어입니다. 추가하면 사용자 뷰어로 얹히고, 복사해서 고칠 수 있습니다.';

  @override
  String get viewerBuiltinBadge => '기본';

  @override
  String get viewerUserBadge => '사용자';

  @override
  String get viewersWaiting => '뷰어 목록을 불러오는 중입니다…';

  @override
  String get viewersNeedProject => '프로젝트를 한 번 열면 뷰어 목록이 나타납니다.';

  @override
  String get addViewer => '뷰어 추가';

  @override
  String get addViewerFile => 'JS 파일 하나';

  @override
  String get addViewerFileDesc => '뷰어 하나가 담긴 .js 파일을 고릅니다';

  @override
  String get addViewerFolder => '폴더 (viewer.json)';

  @override
  String get addViewerFolderDesc =>
      '여러 파일이나 WASM 으로 된 뷰어입니다. 폴더에 viewer.json 이 있어야 합니다';

  @override
  String get viewersEmpty => '추가한 뷰어가 없습니다. 기본 뷰어만 사용합니다.';

  @override
  String get viewSource => '소스 보기';

  @override
  String get viewerFileMissing => '파일을 찾을 수 없습니다';

  @override
  String get viewerReadFailed => '파일을 읽을 수 없습니다.';

  @override
  String get sandboxUnavailable =>
      '이 플랫폼용 샌드박스 런타임이 앱에 들어 있지 않습니다. 시스템 Python 으로 바꾸기 전까지 도구를 쓸 수 없습니다.';

  @override
  String get sandboxIdle => '도구를 처음 실행할 때 시작합니다';

  @override
  String get sandboxStarting => '샌드박스를 시작하는 중입니다…';

  @override
  String get sandboxRunning => '샌드박스가 실행 중입니다';

  @override
  String sandboxFailed(String error) {
    return '샌드박스 오류: $error';
  }

  @override
  String get navSandboxes => '샌드박스';

  @override
  String navSandboxesRunning(int count) {
    return '$count개 실행 중';
  }

  @override
  String get sandboxNoProjects =>
      '열린 프로젝트가 없습니다. 프로젝트를 열면 그 프로젝트의 샌드박스가 여기 나타납니다.';

  @override
  String get sandboxSystemMachine => '시스템 샌드박스';

  @override
  String get sandboxSystemMachineDesc =>
      '프로젝트에 속하지 않는 도구 작업(설정의 도구 목록 등)을 여기서 합니다. 앱에 한 대만 있습니다.';

  @override
  String get sandboxStart => '시작';

  @override
  String get sandboxRestart => '다시 시작';

  @override
  String get sandboxStop => '중지';

  @override
  String get sandboxStopTitle => '샌드박스 중지';

  @override
  String get sandboxStopBody =>
      '샌드박스를 중지하면 그 안에서 실행 중인 명령과 터미널도 모두 끝납니다. 프로젝트 폴더의 파일은 그대로입니다.';

  @override
  String get sandboxConsole => '콘솔';

  @override
  String get sandboxNetwork => '네트워크';

  @override
  String get sandboxConsoleHint => 'root 셸에 보낼 명령';

  @override
  String get sandboxNotRunning => '샌드박스가 꺼져 있습니다. 시작하면 root 셸을 쓸 수 있습니다.';

  @override
  String get sandboxNetworkEmpty => '아직 네트워크 접근이 없습니다.';

  @override
  String get sandboxMountRo => '읽기 전용';

  @override
  String sandboxUptime(String since) {
    return '$since부터 실행 중';
  }

  @override
  String get newFile => '새 파일';

  @override
  String get newFolder => '새 폴더';

  @override
  String get rename => '이름 변경';

  @override
  String get delete => '삭제';

  @override
  String get deleteWarn => '되돌릴 수 없습니다(휴지통으로 가지 않습니다).';

  @override
  String get deleteFolderWarn => '폴더와 그 안의 모든 내용이 지워집니다. 되돌릴 수 없습니다.';

  @override
  String get copyPath => '전체 경로 복사';

  @override
  String get openWith => '연결 프로그램으로 열기';

  @override
  String get openInExplorer => '탐색기에서 열기';

  @override
  String get openPlaybook => '계획 파일 열기 (.collabo/PLAYBOOK.md)';

  @override
  String get fileSearchPlaceholder => '파일 이름 검색…';

  @override
  String get fileSearchTitle => '파일 이름 검색';

  @override
  String get contentSearchTitle => '파일 내용 검색';

  @override
  String get contentSearchPlaceholder => '파일 내용 검색…';

  @override
  String get fileNone => '선택한 파일이 없습니다';

  @override
  String get copySelection => '선택 영역 복사';

  @override
  String get fullscreenTitle => '전체화면 보기';

  @override
  String get fullscreenExitTitle => '전체화면 종료';

  @override
  String get folderEmpty => '(빈 폴더)';

  @override
  String get noResults => '검색 결과가 없습니다';

  @override
  String get treeLoading => '불러오는 중입니다…';

  @override
  String get viewerModeTitle => '보기 방식';

  @override
  String get statusCheck => '상태 확인';

  @override
  String get notSelected => '인터프리터 경로를 선택하세요';

  @override
  String get allFiles => '모든 파일';

  @override
  String get console => '콘솔';

  @override
  String get consoleStarting => '시작하는 중입니다…';

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
    return '실행하지 못했습니다: $error';
  }

  @override
  String get webviewUnsupported => '이 플랫폼의 웹뷰 백엔드는 아직 연결되지 않았습니다.';

  @override
  String webviewInitFailed(String error) {
    return '웹뷰를 시작하지 못했습니다\n$error';
  }

  @override
  String get webviewRuntimeMissing =>
      '이 화면을 표시하려면 Microsoft Edge WebView2 런타임이 필요합니다.\n설치한 뒤 앱을 다시 시작하세요.';

  @override
  String get webviewRuntimeDownload => 'WebView2 런타임 다운로드';

  @override
  String get noOpenProject => '열린 프로젝트가 없습니다';

  @override
  String get wizardTitle => '초기 설정';

  @override
  String get wizardIntro =>
      'Collabo IDE 사용 준비를 도와드리겠습니다. 모든 항목은 나중에 설정에서 바꿀 수 있습니다.';

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

  @override
  String get stopChoiceTitle => '생성 중지';

  @override
  String get stopChoiceBody => '지금까지 진행된 내용을 어떻게 할까요?';

  @override
  String get stopChoiceNote => '도구가 이미 고친 파일은 어느 쪽을 골라도 그대로입니다.';

  @override
  String get stopKeep => '여기까지 남기기';

  @override
  String get stopDiscard => '전부 취소';

  @override
  String get stopContinue => '계속 진행';

  @override
  String get checkpointTitle => '대화 시작점 만들기';

  @override
  String get checkpointDesc => '지금까지의 대화를 접고 새 시작점을 만듭니다. 이후 AI는 시작점 이후만 봅니다.';

  @override
  String get checkpointPlanNote =>
      '계획(PLAYBOOK)도 함께 비웁니다. 이전 계획은 .collabo/playbook-archive 에 보관됩니다.';

  @override
  String get checkpointCurrentContext => '시작 전 컨텍스트';

  @override
  String get checkpointCompress => '기존 내용을 압축해서 보관';

  @override
  String get checkpointSize => '압축 크기';

  @override
  String get checkpointPreview => '미리보기 생성';

  @override
  String get checkpointGenerating => '만드는 중입니다…';

  @override
  String get checkpointMemory => '지난 기억';

  @override
  String get checkpointCreate => '시작점 만들기';

  @override
  String get checkpointModeCheckpoint => '시작점 만들기';

  @override
  String get checkpointModePlan => '계획만 초기화';

  @override
  String get planResetDesc =>
      '대화는 그대로 두고 계획(PLAYBOOK)만 비웁니다. 이전 계획은 .collabo/playbook-archive 에 보관됩니다.';

  @override
  String get planResetButton => '계획 초기화';

  @override
  String get appleFoundation => 'Apple Foundation Models';

  @override
  String get appleFoundationDesc =>
      '기기 안의 Apple 모델로 실행하며 대화가 기기 밖으로 나가지 않습니다. macOS·iOS 26.4 이상에서 Apple Intelligence 를 켜야 합니다.';

  @override
  String get afmPermissive => '가드레일 느슨하게';

  @override
  String get afmPermissiveDesc => '기본 가드레일이 평범한 한국어 질문도 막는 경우가 있어 권장합니다.';

  @override
  String get afmPromptedTools => '도구를 프롬프트로 주입';

  @override
  String get afmPromptedToolsDesc =>
      '모델이 도구 호출을 내지 않으면 켜세요. 도구 설명을 프롬프트에 넣고 답변 본문에서 호출을 읽습니다.';

  @override
  String get afmPrewarm => '미리 올리기';

  @override
  String get afmPrewarmDesc => '연결을 확인할 때 모델을 미리 올려 첫 응답을 빠르게 합니다.';

  @override
  String get afmTrimHistory => '컨텍스트가 넘치면 앞 대화 자르기';

  @override
  String get afmTrimHistoryDesc => '끄면 컨텍스트를 넘길 때 오류로 알려 줍니다.';

  @override
  String get afmConcurrent => '동시 요청 수';

  @override
  String get afmConcurrentDesc => '비우거나 0 이면 엔진 기본값을 씁니다.';

  @override
  String get folderPickerTitle => '폴더 선택';

  @override
  String get folderPickerUp => '상위 폴더';

  @override
  String get folderPickerEmpty => '하위 폴더가 없습니다';

  @override
  String get folderPickerFilesAppHint =>
      '\'파일\' 앱의 Collabo IDE 폴더에서도 볼 수 있습니다.';

  @override
  String get sandboxUnavailableIOS =>
      'iOS에서는 샌드박스를 실행할 수 없습니다. 채팅과 파일 편집은 쓸 수 있지만 명령을 실행하는 도구는 쓸 수 없습니다.';

  @override
  String get contextWindowLabel => '컨텍스트 크기';

  @override
  String get contextWindowHelp => '모델의 컨텍스트 토큰 수를 입력하세요. 모르면 비워 두세요.';

  @override
  String contextWindowDetected(int tokens) {
    return '$tokens 토큰';
  }

  @override
  String get contextWindowAssumed => '4096 토큰으로 가정합니다';

  @override
  String get autoFitContext => '작은 컨텍스트에 맞추기';

  @override
  String get autoFitContextDesc => '컨텍스트가 16K 이하인 모델에는 핵심 도구와 짧은 프롬프트만 보냅니다.';

  @override
  String fitBudget(int reserve, int input) {
    return '응답에 $reserve 토큰, 입력에 $input 토큰을 씁니다.';
  }

  @override
  String get fitPromptCompact => '기본 프롬프트 대신 짧은 프롬프트를 보냅니다.';

  @override
  String get fitPromptCustom => '직접 작성한 프롬프트를 그대로 보냅니다.';

  @override
  String get fitPromptTooLong => '이 모델에는 프롬프트가 너무 깁니다. 설정 › 프롬프트에서 줄여 주세요.';

  @override
  String get fitTools => '도구 설명을 줄여 최대한 많은 도구를 보냅니다.';

  @override
  String get fitDisabled => '서브에이전트, 검증, 계획, 프로젝트 상태 요약, 사전 평가, 감독자는 쓰지 않습니다.';

  @override
  String get fitRecommendTitle => '더 큰 모델을 권장합니다';

  @override
  String get fitRecommendBody => '긴 작업에는 컨텍스트가 큰 모델을 기본 프리셋으로 지정하세요.';

  @override
  String get afmModelVersion => '모델 버전';
}
