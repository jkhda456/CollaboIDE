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

  @override
  Future<void> dispose() async {
    await _messages.close();
  }
}

/// 항상 실패하는 provider — API 오류로 재시도가 도는 상황을 만든다.
class _FailingProvider implements LlmProvider {
  int calls = 0;

  @override
  Future<LlmTestResult> test(LlmConfig cfg) async =>
      const LlmTestResult(true, 'ok');

  @override
  Stream<LlmEvent> streamChat({
    required LlmConfig cfg,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
  }) {
    calls++;
    return Stream<LlmEvent>.error(Exception('HTTP 500: upstream exploded'));
  }

  @override
  void dispose() {}
}

void main() {
  late Directory tmp;
  late _FakeWebView view;
  late WorkspaceController wc;
  late ProjectSession session;
  late WebBridge bridge;
  late _FailingProvider provider;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_retry_');
    wc = WorkspaceController();
    session = await ProjectSession.open(
      tmp.path,
      browser: BrowserController(),
      firstConversationTitle: 'test',
    );
    view = _FakeWebView();
    provider = _FailingProvider();
    bridge = WebBridge(wc, session,
        llmClient: provider, viewerStager: (_) async => const []);
    session.bridge = bridge;
    await bridge.start();
    await bridge.attachView(view);
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 첫 호출이 곧바로 실패하는 상황 — 예전에는 정리 기준(첫 assistant 메시지 id)이
  /// 정해지지 않아 부분 기록이 남을 수 있었다.
  ///
  /// 재시도 대기(2~5초)는 실제 시간이라 기다리지 않는다. 정리는 대기 **전에**
  /// 일어나므로 첫 실패 직후를 확인하면 충분하다.
  test('첫 호출이 실패해도 대화에는 사용자 메시지만 남는다', () async {
    view.emit(jsonEncode({'type': 'chat.send', 'text': '문서를 고쳐줘'}));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final msgs =
        await session.conversation.messages(session.activeConversationId!);
    expect(msgs.map((m) => m.role), [MessageRole.user],
        reason: '실패한 시도가 남긴 어시스턴트/도구 기록은 모두 정리돼야 한다');
    expect(msgs.single.content, '문서를 고쳐줘');
    expect(provider.calls, greaterThan(0), reason: '실제로 호출은 있었어야 한다');
  });

  /// 웹은 중지를 누른 순간 버튼을 "중지 중…" 으로 바꾼다 — 응답이 없으면 그대로 갇힌다.
  test('중지할 것이 없어도 chat.stopped 를 돌려준다', () async {
    view.posted.clear();
    view.emit(jsonEncode({'type': 'chat.stop'}));
    await pumpEventQueue();

    expect(view.posted.any((m) => m['type'] == 'chat.stopped'), isTrue,
        reason: '응답이 없으면 웹의 "중지 중…" 이 영원히 남는다');

    // 두 번째 누름도 응답해야 한다(중복 가드가 눌러도 아무 일 없게 만들면 안 된다).
    view.posted.clear();
    view.emit(jsonEncode({'type': 'chat.stop'}));
    await pumpEventQueue();
    expect(view.posted.any((m) => m['type'] == 'chat.stopped'), isTrue);
  });

  test('오류로 끝난 뒤 눌러도 응답이 온다', () async {
    view.emit(jsonEncode({'type': 'chat.send', 'text': 'hi'}));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    view.posted.clear();

    view.emit(jsonEncode({'type': 'chat.stop'}));
    await pumpEventQueue();

    expect(view.posted.any((m) => m['type'] == 'chat.stopped'), isTrue);
  });

  test('실패하면 재시도를 알린다', () async {
    view.emit(jsonEncode({'type': 'chat.send', 'text': 'hi'}));
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final notices = view.posted
        .where((m) => m['type'] == 'chat.notice')
        .map((m) => '${m['text']}')
        .toList();
    expect(notices.any((t) => t.contains('retry')), isTrue,
        reason: '재시도 중임을 사용자에게 알려야 한다: $notices');
  });
}
