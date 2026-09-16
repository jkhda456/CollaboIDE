import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/agent/agent_loop.dart';
import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/fs/file_service.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 웹으로 나간 메시지를 모아 두는 가짜 웹뷰.
class _FakeWebView implements PlatformWebView {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();
  final List<Map<String, Object?>> posted = [];

  @override
  Future<void> initialize() async {}

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  Stream<void> get pageFinished => Stream<void>.empty();

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<void> postMessage(String json) async {
    posted.add(jsonDecode(json) as Map<String, Object?>);
  }

  @override
  Future<void> executeScript(String script) async {}

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  bool get needsWheelWorkaround => false;

  void emit(Object message) => _messages.add(message);

  List<String> get types => [for (final m in posted) '${m['type']}'];

  @override
  Future<void> dispose() async {
    await _messages.close();
  }
}

/// 네트워크를 타지 않는 LLM provider 스텁.
class _StubProvider implements LlmProvider {
  @override
  Future<LlmTestResult> test(LlmConfig cfg) async =>
      const LlmTestResult(true, 'ok');

  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) =>
      Stream<LlmEvent>.empty();

  @override
  void dispose() {}
}

/// 루프를 브리지에서 떼어낸 뒤에도 **경계가 맞는지** 보는 테스트.
///
/// 확인하는 것은 셋이다.
/// 1. 루프가 내보낸 이벤트가 브리지를 통해 그대로 웹에 도착한다.
/// 2. 화면이 떨어져 있으면 조용히 버려지고, **루프는 그래도 돈다**.
/// 3. 다시 붙으면 [WebBridge.pushAll] 이 현재 상태를 통째로 다시 만든다.
void main() {
  late Directory tmp;
  late WorkspaceController wc;
  late ProjectSession session;
  late WebBridge bridge;
  late _FakeWebView view;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_loop_');
    wc = WorkspaceController();
    session = await ProjectSession.open(
      tmp.path,
      browser: BrowserController(),
      firstConversationTitle: 'test',
    );
    view = _FakeWebView();
    bridge = WebBridge(wc, session,
        llmClient: _StubProvider(), viewerStager: (_) async => const []);
    session.bridge = bridge;
    await bridge.start();
    await bridge.attachView(view);
    view.posted.clear();
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('루프의 이벤트는 브리지를 지나 웹으로 간다', () async {
    // 중지는 "중지할 게 없어도 반드시 응답한다" 는 루프의 가장 짧은 발화 경로다.
    bridge.loop.stop();
    await pumpEventQueue();

    expect(view.types, contains('chat.stopped'));
  });

  test('화면이 떨어져 있으면 버리고, 루프는 그대로 산다', () async {
    await bridge.detachView();
    view.posted.clear();

    bridge.loop.stop();
    await pumpEventQueue();

    expect(view.posted, isEmpty, reason: '붙어 있지 않은 화면으로는 나가지 않는다');
    // 루프 자체는 죽지 않았다 — 다시 붙이면 계속 말한다.
    await bridge.attachView(view);
    view.posted.clear();
    bridge.loop.stop();
    await pumpEventQueue();
    expect(view.types, contains('chat.stopped'));
  });

  test('다시 붙으면 현재 상태를 통째로 다시 보낸다', () async {
    await bridge.detachView();
    await bridge.attachView(view);
    await pumpEventQueue();

    // 증분이 아니라 전체 — 프로젝트·계획·기록·헤더·큐가 한 번에 나간다.
    expect(
      view.types,
      containsAll(<String>[
        'project.changed',
        'chat.plan',
        'chat.history',
        'chat.meta',
        'chat.queue',
      ]),
    );
  });

  test('호출 내역은 루프가 들고 브리지는 그대로 내준다', () {
    // 네이티브 창(`app_layout.dart`)은 `session.bridge!.toolCalls` 로 집는다 —
    // 루프로 옮긴 뒤에도 같은 객체여야 창에 실제 호출이 보인다.
    expect(identical(bridge.toolCalls, bridge.loop.toolCalls), isTrue);
  });

  test('브리지의 생성 여부는 루프의 것을 그대로 읽는다', () {
    expect(bridge.isGenerating, bridge.loop.isGenerating);
    expect(session.isBusy, isFalse);
  });

  test('웹의 chat.* 메시지는 루프로 넘어간다', () async {
    // 브리지는 대화 메시지를 직접 처리하지 않는다 — 라우팅만 한다.
    view.emit(jsonEncode({'type': 'chat.stop'}));
    await pumpEventQueue();

    expect(view.types, contains('chat.stopped'));
  });

  test('AgentLoop 은 브리지 없이도 만들 수 있다', () async {
    // 화면(브리지)을 전제하지 않는다는 것이 분리의 요점이다.
    final loop = AgentLoop(wc, session,
        fileService: FileService(), llmClient: _StubProvider());
    final seen = <String>[];
    final sub = loop.events.listen((m) => seen.add('${m['type']}'));
    await loop.start();
    loop.stop();
    await pumpEventQueue();

    expect(seen, contains('chat.stopped'));
    await sub.cancel();
    await loop.dispose();
  });
}
