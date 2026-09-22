import 'dart:async';
import 'dart:io';

import 'package:collabo_core/collabo_core.dart' show CollaboRuntime;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../browser/browser_channel.dart';
import '../browser/browser_controller.dart';
import '../conversation/conversation_store.dart';
import '../files/file_viewer.dart';
import '../files/project_files.dart';
import '../process/background_process_registry.dart';
import '../process/process_manager.dart';
import '../process/python_environment.dart';
import '../sandbox/project_sandbox.dart';
import '../webview/web_bridge.dart';

/// 프로젝트별 venv 준비 상태.
enum VenvStatus { idle, creating, ready, error }

/// **열려 있는 프로젝트 하나.** 그 프로젝트에만 속한 것을 전부 들고 있다.
///
/// 예전에는 이 모든 것이 [WorkspaceController] 에 **한 벌씩만** 있었다. 그래서
/// 다른 프로젝트를 열면 대화 DB 가 닫히고 그 자리를 덮어썼고, 돌고 있던 생성
/// 루프는 웹뷰 패널이 사라지면서 같이 죽었다 — 통신 속도 실측, 도구 호출 내역,
/// 큐, 감독자 궤적이 조각조각 사라졌다. 프로젝트마다 이 객체를 하나씩 두고
/// **열린 채로 살려 두는 것**이 그 문제들의 공통 해법이다.
///
/// > ⚠️ **웹뷰는 여기 없다.** 브리지([bridge])는 세션의 것이고, 화면의
/// > `WebViewPanel` 은 자기 웹뷰를 브리지에 **붙였다 뗐다** 할 뿐이다. 루프의
/// > 수명이 위젯 수명에 매이면 안 된다는 것이 이 구조의 요점이다.
class ProjectSession extends ChangeNotifier {
  ProjectSession._(this.path, this.conversation, BrowserController browser)
      : browserChannel = BrowserChannel(browser) {
    backgroundProcesses.addListener(notifyListeners);
    backgroundProcesses.attachProject(path);
    browserChannel.attachProject(path);
  }

  /// 프로젝트를 열고 세션을 만든다. 대화 DB 를 열고 활성 대화를 확보한다.
  ///
  /// [firstConversationTitle] 은 대화가 하나도 없을 때 만들 대화의 제목이다
  /// (예전에는 여기 한국어가 박혀 있었다 — 호출측이 l10n 으로 넘긴다).
  static Future<ProjectSession> open(
    String path, {
    required BrowserController browser,
    required String firstConversationTitle,
  }) async {
    final store = await ConversationStore.openForProject(path);
    // 지난 실행의 샌드박스는 이미 없다 — 그 안에서 돌던 기록이 running 으로 남지 않게.
    ProjectSandbox.sweepStaleIn(path);
    final session = ProjectSession._(path, store, browser);
    // 트리를 읽고 감시를 시작한다 — 화면이 붙기 전에도 필요하다(에이전트가 먼저 일한다).
    await session.files.start();
    // 활성(메인) 대화 확보: 최근 메인 대화가 있으면 재사용, 없으면 새로 만든다.
    final mains = await store.listMainConversations();
    session.activeConversationId = mains.isNotEmpty
        ? mains.first.id
        : await store.createConversation(title: firstConversationTitle);
    return session;
  }

  /// 프로젝트 루트. 세션의 **정체**이므로 바뀌지 않는다.
  final String path;

  /// 이 프로젝트의 대화 DB(`<project>/.collabo/conversation.db`).
  final ConversationStore conversation;

  /// 이 프로젝트의 백그라운드 명령(`.collabo/proc`).
  final BackgroundProcessRegistry backgroundProcesses =
      BackgroundProcessRegistry();

  /// 이 프로젝트의 웹 검색 파일 통로(`.collabo/browser`).
  ///
  /// **브라우저 탭 자체는 전역**이다(앱에 하나뿐인 [BrowserController]). 프로젝트마다
  /// 다른 것은 파이썬 도구가 말을 거는 창구뿐이다 — 각 프로젝트의 도구는 자기
  /// `.collabo/browser` 에 요청을 쓰고, 기록도 그 프로젝트 폴더에 남는다.
  final BrowserChannel browserChannel;

  /// 지금 보고 있는 메인 대화 id.
  int? activeConversationId;

  /// 이 프로젝트의 파일 트리(네이티브 트리의 모델 + 파일 조작 창구 + 감시).
  late final ProjectFiles files = ProjectFiles(path);

  /// 파일 뷰어(네이티브 틀 + 뷰어 웹뷰). 세션을 만들 때 [WorkspaceController] 가 채운다
  /// (뷰어 설정·사용자 뷰어가 컨트롤러에 있다).
  FileViewerController? viewer;

  /// 우측 패널(트리 + 뷰어)을 보이는가. 대화 헤더의 토글 버튼이 바꾼다.
  final ValueNotifier<bool> sidePanelVisible = ValueNotifier(true);

  void toggleSidePanel() => sidePanelVisible.value = !sidePanelVisible.value;

  /// 파일을 뷰어로 연다 — 패널이 접혀 있으면 펴고, 트리에서 그 파일이 보이게 펼친다.
  /// (대화 쪽의 계획 파일 열기, 트리 머리의 계획 버튼 등이 부른다.)
  void openInViewer(String filePath) {
    sidePanelVisible.value = true;
    files.reveal(filePath);
    viewer?.open(filePath);
  }

  /// 이 프로젝트의 웹 브리지(트리/뷰어 창구 + **에이전트 루프의 소유자**).
  ///
  /// 루프 자체는 `bridge.loop`([AgentLoop])이고 브리지는 그 이벤트를 웹으로
  /// 실어 나르기만 한다 — 화면이 붙지 않아도 루프는 돈다.
  /// 세션이 만들어질 때 [WorkspaceController] 가 채우고, 세션을 닫을 때만 버려진다.
  WebBridge? bridge;

  /// 런쳐 프로세스 매니저. venv 가 프로젝트별이라 이것도 프로젝트별이다.
  ProcessManager? processManager;

  PythonEnvironment? pythonEnv;
  VenvStatus venvStatus = VenvStatus.idle;
  String venvError = '';

  /// 이 프로젝트의 리눅스 머신(도구 실행 환경이 샌드박스일 때). 처음 필요할 때 만든다.
  ProjectSandbox? _sandbox;
  ProjectSandbox? get sandbox => _sandbox;

  /// 샌드박스를 (없으면 만들어) 준다. 부팅은 첫 도구 실행 때 한다([ProjectSandbox.ready]).
  ProjectSandbox sandboxFor(CollaboRuntime runtime, {required String toolsDir}) {
    final existing = _sandbox;
    if (existing != null) return existing;
    final box = ProjectSandbox(projectPath: path, toolsDir: toolsDir, runtime: runtime);
    box.addListener(notifyListeners);
    // 진행 상태 화면의 "종료" 가 샌드박스 프로세스를 게스트 안에서 끝내게 한다.
    backgroundProcesses.sandboxKiller =
        (proc) => box.killGroup(proc.pid!, terminal: proc.isTerminal);
    _sandbox = box;
    return box;
  }

  /// 지금 이 프로젝트에서 생성이 돌고 있는지(좌측 메뉴 표시 + 닫기 확인).
  bool get isBusy => bridge?.isGenerating ?? false;

  /// 브리지가 생성을 시작·종료할 때 부른다.
  ///
  /// [isBusy] 는 브리지 안의 플래그를 읽는 값이라, **바뀌었다고 아무도 말해 주지
  /// 않으면** 좌측 메뉴가 다시 그려지지 않는다(스피너가 끝난 뒤에도 돌던 이유다).
  /// `notifyListeners` 는 `@protected` 라 바깥에서 못 부르므로 이 창구를 둔다.
  void notifyBusyChanged() => notifyListeners();

  /// 폴더 이름(좌측 메뉴·탭 라벨).
  String get name {
    final parts = path.replaceAll('\\', '/').split('/')
      ..removeWhere((s) => s.isEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  /// 프로젝트 폴더 안에서 venv 를 두는 상대 경로.
  static const List<String> venvSubdir = ['.collabo', 'venv'];

  /// 이 프로젝트에 적용될 venv 경로(정책이 꺼져 있으면 null).
  String? venvPathFor({required bool useVenv}) =>
      useVenv ? p.join(path, venvSubdir[0], venvSubdir[1]) : null;

  /// base 인터프리터 + venv 정책으로 파이썬 환경을 다시 만든다.
  ///
  /// 전역 설정(인터프리터 경로·venv 사용 여부)이 바뀌면 **열린 세션 전부**가
  /// 이걸 다시 받는다 — 한 프로젝트만 갱신하면 나머지는 옛 인터프리터로 돈다.
  void rebuildPythonEnv(String interpreterPath, {required bool useVenv}) {
    final env = PythonEnvironment(interpreterPath,
        venvPath: venvPathFor(useVenv: useVenv));
    pythonEnv = env;
    if (processManager == null) {
      processManager = ProcessManager(env);
    } else {
      processManager!.updateEnvironment(env);
    }
    notifyListeners();
  }

  /// 실제 도구 실행에 쓰는 파이썬(venv 준비 시 venv, 아니면 base). 미설정이면 null.
  String? get effectivePython {
    final e = pythonEnv;
    if (e == null || !e.isInstalled) return null;
    return e.executablePath;
  }

  /// 이 프로젝트의 venv 를 (없으면) 만든다. 상태를 갱신하며 알린다.
  Future<void> ensureVenv() async {
    final env = pythonEnv;
    if (env == null || env.venvPath == null) {
      venvStatus = VenvStatus.idle;
      venvError = '';
      notifyListeners();
      return;
    }
    if (env.venvReady) {
      venvStatus = VenvStatus.ready;
      venvError = '';
      notifyListeners();
      return;
    }
    if (!env.isInstalled) return; // base 미설정: 인터프리터 지정 시 다시 시도된다.
    venvStatus = VenvStatus.creating;
    venvError = '';
    notifyListeners();
    final r = await env.ensureVenv();
    // 도중에 설정이 바뀌었으면 결과를 버린다(경합 방지).
    if (!identical(env, pythonEnv)) return;
    if (r.ok) {
      venvStatus = VenvStatus.ready;
      venvError = '';
    } else {
      venvStatus = VenvStatus.error;
      venvError = r.error ?? 'Failed to create venv.';
    }
    notifyListeners();
  }

  /// venv 를 지우고 다시 만든다(설정의 "재생성" 버튼).
  Future<void> recreateVenv({required bool useVenv}) async {
    final vp = venvPathFor(useVenv: useVenv);
    if (vp == null) return;
    try {
      final dir = Directory(vp);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      venvStatus = VenvStatus.error;
      venvError = '$e';
      notifyListeners();
      return;
    }
    await ensureVenv();
  }

  var _closed = false;

  /// 세션을 닫고 가진 것을 전부 버린다. **두 번 불러도 안전하다**
  /// (닫기 → dispose 순서로 들어오는 경로가 있다).
  ///
  /// **돌고 있는 생성이 있으면 먼저 끊는다** — 안 그러면 닫힌 DB 에 쓰려다
  /// 터진다. 사용자에게 물어볼지는 호출측(UI)이 [isBusy] 로 판단한다.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    bridge?.stopGeneration();
    await bridge?.dispose();
    bridge = null;
    viewer?.dispose();
    viewer = null;
    files.dispose();
    sidePanelVisible.dispose();
    browserChannel.dispose();
    backgroundProcesses.removeListener(notifyListeners);
    backgroundProcesses.dispose();
    processManager?.dispose();
    final box = _sandbox;
    _sandbox = null;
    box?.removeListener(notifyListeners);
    await box?.close();
    await conversation.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
