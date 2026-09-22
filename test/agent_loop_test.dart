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
        llmClient: _StubProvider());
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

  group('시작점과 계획(PLAYBOOK)', () {
    File playbook() => File('${tmp.path}/.collabo/PLAYBOOK.md');
    Directory archive() => Directory('${tmp.path}/.collabo/playbook-archive');

    Future<void> seedPlan() async {
      playbook()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('# PLAYBOOK\n\n## GOAL\n- [ASSUMED] 옛 목표\n\n## PLAN\n- [TODO] 남은 일\n');
      // 루프가 들고 있는 계획도 디스크와 맞춘다(생성 때마다 다시 읽는 것과 같다).
      await bridge.loop.reloadPlaybook();
    }

    Future<List<String>> pipelines() async => [
          for (final m in await session.conversation.messages(session.activeConversationId!))
            m.pipeline ?? '',
        ];

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('시작점을 만들면 계획도 비우고 옛 계획은 보관한다', () async {
      await seedPlan();
      view.posted.clear();

      view.emit(jsonEncode({'type': 'chat.checkpoint.create', 'compress': false, 'content': ''}));
      await settle();

      expect(await pipelines(), contains('checkpoint'));
      expect(playbook().existsSync(), isFalse);
      expect(archive().listSync(), hasLength(1));
      final plan = view.posted.lastWhere((m) => m['type'] == 'chat.plan');
      expect(plan['plan'], isNull, reason: '계획 카드가 사라져야 한다');
      expect(plan['path'], isNull, reason: '"계획 파일 열기" 버튼도');
      // 알림은 기록을 다시 그린 뒤에 와야 지워지지 않는다.
      final types = view.types;
      expect(types.lastIndexOf('chat.notice'), greaterThan(types.lastIndexOf('chat.history')));
      // 문구는 웹이 지금 언어로 바꾼다 — 키와 자리 값이 같이 가야 한다.
      final notice = view.posted.lastWhere((m) => m['type'] == 'chat.notice');
      expect(notice['key'], 'noticePlanCleared');
      expect((notice['args'] as Map)['path'], startsWith('.collabo/playbook-archive/'));
    });

    test('계획만 초기화 — 시작점은 만들지 않는다', () async {
      await seedPlan();
      final before = await pipelines();

      view.emit(jsonEncode({'type': 'chat.plan.reset'}));
      await settle();

      expect(await pipelines(), before, reason: '대화는 그대로');
      expect(playbook().existsSync(), isFalse);
      expect(archive().listSync(), hasLength(1));
      expect(view.types, contains('chat.notice'));
    });

    test('비울 계획이 없어도 조용히 끝나지 않고 알려 준다', () async {
      view.emit(jsonEncode({'type': 'chat.plan.reset'}));
      await settle();
      final notice = view.posted.lastWhere((m) => m['type'] == 'chat.notice');
      expect('${notice['text']}', contains('no plan'));
      expect(notice['key'], 'noticeNoPlan');
      expect(archive().existsSync(), isFalse);
    });
  });

  group('호출 내역 — 배지와 창이 같은 것을 센다', () {
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    Future<void> seed(String name, DateTime at, {bool finished = true}) async {
      final store = session.conversation;
      final seq = await store.insertToolCall(
        conversationId: session.activeConversationId!,
        callId: 't_$name',
        scope: 'main',
        name: name,
        args: '{}',
        startedAt: at,
      );
      if (finished) {
        await store.finishToolCall(seq,
            ok: true, result: '{"ok":true}', summary: 'ok', finishedAt: at);
      }
    }

    int lastCount() =>
        view.posted.lastWhere((m) => m['type'] == 'activity.count')['count'] as int;

    test('다시 열면(화면이 다시 붙으면) 저장된 내역이 창과 배지에 같이 돌아온다', () async {
      final past = DateTime.now().subtract(const Duration(seconds: 5));
      await seed('read_file', past);
      await seed('edit_file', past);
      // 앱이 꺼질 때 돌던 호출 — 영원히 도는 것처럼 보이면 안 된다.
      await seed('run_command', past, finished: false);

      await bridge.detachView();
      await bridge.attachView(view);
      await settle();

      final log = bridge.loop.toolCalls;
      expect(log.length, 3);
      expect(lastCount(), 3, reason: '배지는 창과 같은 숫자');
      expect(log.records.first.name, 'run_command', reason: '최신이 앞');
      expect(log.records.first.running, isFalse);
      expect(log.records.first.ok, isFalse);
      expect(log.records.last.result, '{"ok":true}', reason: '결과 원문도 남는다');
    });

    test('시작점을 만들면 0 부터 — 되돌리면 앞의 내역이 돌아온다', () async {
      await seed('read_file', DateTime.now().subtract(const Duration(seconds: 5)));
      await bridge.detachView();
      await bridge.attachView(view);
      await settle();
      expect(lastCount(), 1);

      view.emit(jsonEncode({'type': 'chat.checkpoint.create', 'compress': false, 'content': ''}));
      await settle();
      expect(bridge.loop.toolCalls.length, 0);
      expect(lastCount(), 0);

      // 시작점 뒤의 호출은 센다.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await seed('write_file', DateTime.now());
      await bridge.detachView();
      await bridge.attachView(view);
      await settle();
      expect(lastCount(), 1);
      expect(bridge.loop.toolCalls.records.single.name, 'write_file');

      final cp = (await session.conversation.messages(session.activeConversationId!))
          .lastWhere((m) => m.pipeline == 'checkpoint');
      view.emit(jsonEncode({'type': 'chat.checkpoint.revert', 'id': cp.id}));
      await settle();
      expect(lastCount(), 2, reason: '시작점을 지우면 그 앞도 다시 보인다');
    });
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
