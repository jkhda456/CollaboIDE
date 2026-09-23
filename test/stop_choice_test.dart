// 중지: **지금까지 한 것을 남길지** 고를 수 있다.
//
// 예전에는 중지가 무조건 요청 직전으로 되돌려, 도구가 절반쯤 해 둔 작업의 기록이 통째로
// 사라졌다. 이제 웹이 진행 여부를 보고 앱 창(`stop_choice_dialog.dart`)이 물어본 뒤
// `loop.stop(keep: …)` 을 부른다. 여기서는 그 두 갈래의 **결과**를 본다.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/conversation/models.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeWebView implements PlatformWebView {
  final StreamController<dynamic> _messages = StreamController<dynamic>.broadcast();
  final List<Map<String, Object?>> posted = [];

  @override
  Future<void> initialize() async {}
  @override
  Stream<dynamic> get messages => _messages.stream;
  @override
  Stream<void> get pageFinished => const Stream<void>.empty();
  @override
  Future<void> loadUrl(String url) async {}
  @override
  Future<void> postMessage(String json) async =>
      posted.add(jsonDecode(json) as Map<String, Object?>);
  @override
  Future<void> executeScript(String script) async {}
  @override
  Widget buildView() => const SizedBox.shrink();
  @override
  bool get needsWheelWorkaround => false;
  void emit(Object message) => _messages.add(message);
  List<String> get types => [for (final m in posted) '${m['type']}'];
  @override
  Future<void> dispose() async => _messages.close();
}

/// 본문을 조금 흘린 뒤 **끝내지 않는** provider — 중지를 누르는 상황 그대로다.
///
/// `async*` 로 만들면 안 된다: 중지는 구독을 취소하는데, 영원히 기다리는 generator 는
/// 취소가 끝나지 않아 시험만 멈춘다(실제 HTTP 스트림은 취소된다).
class _HangingProvider implements LlmProvider {
  final started = Completer<void>();

  /// 중지가 스트림을 실제로 끊었는가.
  var cancelled = false;

  @override
  Future<LlmTestResult> test(LlmConfig cfg) async => const LlmTestResult(true, 'ok');

  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) {
    final ctrl = StreamController<LlmEvent>();
    ctrl.onListen = () {
      ctrl.add(LlmContent('절반쯤 쓴 답'));
      if (!started.isCompleted) started.complete();
    };
    ctrl.onCancel = () => cancelled = true;
    return ctrl.stream;
  }

  @override
  void dispose() {}
}

void main() {
  setUpAll(initSqliteFfi);

  late Directory tmp;
  late WorkspaceController wc;
  late ProjectSession session;
  late WebBridge bridge;
  late _FakeWebView view;
  late _HangingProvider provider;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_stop_');
    wc = WorkspaceController();
    // 연결이 설정돼 있어야 생성이 실제로 시작된다(미설정이면 곧바로 오류로 끝난다).
    await wc.addPreset(
        name: 'test', config: const LlmConfig(baseUrl: 'http://localhost/v1', model: 'm'));
    // 사전 평가(트리아지)도 모델을 부른다 — 켜 두면 본 턴 전에 이 provider 에 걸린다.
    await wc.setPreAssessment(false);
    session = await ProjectSession.open(tmp.path,
        browser: BrowserController(), firstConversationTitle: 'test');
    view = _FakeWebView();
    provider = _HangingProvider();
    bridge = WebBridge(wc, session, llmClient: provider);
    session.bridge = bridge;
    await bridge.start();
    await bridge.attachView(view);
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<List<Message>> messages() async =>
      session.conversation.messages(session.activeConversationId!);

  /// 요청을 보내고 모델이 답을 흘리기 시작할 때까지 기다린다.
  Future<void> startGenerating() async {
    view.emit(jsonEncode({'type': 'chat.send', 'text': '고쳐줘'}));
    await provider.started.future.timeout(const Duration(seconds: 10));
    await pumpEventQueue();
  }

  /// 중지가 끝날 때까지(생성 플래그가 내려갈 때까지) 돈다.
  Future<void> settle() async {
    for (var i = 0; i < 60; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!bridge.loop.isGenerating) break;
    }
    await pumpEventQueue();
  }

  test('전부 취소(기본): 요청 직전으로 되돌린다', () async {
    await startGenerating();
    bridge.loop.stop();
    await settle();

    final roles = [for (final m in await messages()) m.role];
    expect(roles, [MessageRole.user], reason: '사용자 메시지만 남는다');
    expect(view.types, contains('chat.stopped'));
    expect(provider.cancelled, isTrue, reason: '모델 스트림도 곧바로 끊는다');
  });

  test('여기까지 남기기: 흘러온 답을 그 자리까지 저장한다', () async {
    await startGenerating();
    bridge.loop.stop(keep: true);
    await settle();

    final msgs = await messages();
    expect([for (final m in msgs) m.role], [MessageRole.user, MessageRole.assistant]);
    expect(msgs.last.content, '절반쯤 쓴 답');
    expect(view.types, contains('chat.stopped'));
    // 왜 답이 중간에 끊겼는지 대화에 한 줄 남는다.
    final notice = view.posted.lastWhere((m) => m['type'] == 'chat.notice');
    expect(notice['key'], 'noticeStoppedKept');
  });

  test('중지 선택은 앱 창이 맡는다 — 웹의 chat.stop.ask 는 콜백으로만 간다', () async {
    // 라우팅만 본다(창 자체는 app_layout 이 띄운다). 웹이 직접 멈추지 않는다는 것이 요점.
    var asked = 0;
    final v2 = _FakeWebView();
    final b = WebBridge(wc, session, llmClient: provider, onStopChoice: () => asked++);
    await b.attachView(v2);
    v2.emit(jsonEncode({'type': 'chat.stop.ask'}));
    await pumpEventQueue();

    expect(asked, 1);
    expect(v2.types, isNot(contains('chat.stopped')), reason: '고르기 전에는 멈추지 않는다');
    await b.dispose();
    await v2.dispose();
  });
}
