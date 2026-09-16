import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
// ThemeMode 가 material 소속이라 widgets.dart 대신 material.dart 를 쓴다.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 웹으로 나간 메시지를 모아 두는 가짜 웹뷰.
class _FakeWebView implements PlatformWebView {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();

  /// 네이티브 → 웹으로 보낸 메시지(파싱된 JSON).
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

  /// 웹 → 네이티브 메시지를 흘려 보낸다(테스트에서 웹 동작 흉내).
  void emit(Object message) => _messages.add(message);

  @override
  Future<void> dispose() async {
    await _messages.close();
  }
}

/// 네트워크를 타지 않는 LLM provider 스텁(브리지 생성에만 필요).
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

/// 마지막 `chat.meta` 메시지(없으면 null).
Map<String, Object?>? _lastMeta(List<Map<String, Object?>> posted) {
  for (final m in posted.reversed) {
    if (m['type'] == 'chat.meta') return m;
  }
  return null;
}

/// `chat.meta` 의 프리셋 이름 목록.
List<String> _presetNames(Map<String, Object?> meta) => [
      for (final p in (meta['presets'] as List)) (p as Map)['name'] as String,
    ];

void main() {
  late Directory tmp;
  late AppDatabase db;
  late _FakeWebView view;
  late WorkspaceController wc;
  late ProjectSession session;
  late WebBridge bridge;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_meta_');
    db = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
    wc = WorkspaceController();
    await wc.loadLlmForTest(db);
    view = _FakeWebView();
    session = await ProjectSession.open(tmp.path,
        browser: BrowserController(), firstConversationTitle: 'test');
    bridge = WebBridge(wc, session, llmClient: _StubProvider());
    session.bridge = bridge;
    await bridge.start();
    await bridge.attachView(view);
    // 구독 시작 이후의 전송만 보기 위해 초기 상태를 비운다.
    view.posted.clear();
  });

  tearDown(() async {
    await session.close(); // 브리지도 여기서 같이 정리된다.
    await view.dispose();
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('설정에서 프리셋을 추가하면 헤더 메타가 즉시 갱신된다', () async {
    await wc.addPreset(
      name: 'Alt',
      config: const LlmConfig(baseUrl: 'http://alt/v1', model: 'alt'),
    );
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull);
    expect(_presetNames(meta!), contains('Alt'));
  });

  test('프리셋 이름을 바꾸면 헤더 메타가 즉시 갱신된다', () async {
    final alt = await wc.addPreset(name: 'Alt');
    await pumpEventQueue();
    view.posted.clear();

    await wc.updatePreset(alt.id, name: 'Renamed');
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull, reason: '이름만 바뀌어도 웹에 다시 보내야 한다');
    expect(_presetNames(meta!), contains('Renamed'));
    expect(_presetNames(meta), isNot(contains('Alt')));
  });

  test('기본 프리셋을 바꾸면 헤더 메타가 갱신된다', () async {
    final alt = await wc.addPreset(
      name: 'Alt',
      config: const LlmConfig(baseUrl: 'http://alt/v1', model: 'alt'),
    );
    await pumpEventQueue();
    view.posted.clear();

    await wc.setDefaultPreset(alt.id);
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull);
    expect(meta!['defaultPresetId'], alt.id);
    // 프로젝트 지정이 없으면 대화 모델도 기본 프리셋을 따라간다.
    expect(meta['model'], 'alt');
  });

  test('프리셋 삭제도 반영된다', () async {
    final alt = await wc.addPreset(name: 'Alt');
    await pumpEventQueue();
    view.posted.clear();

    await wc.removePreset(alt.id);
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull);
    expect(_presetNames(meta!), isNot(contains('Alt')));
  });

  test('LLM 과 무관한 변경(테마)은 메타를 다시 보내지 않는다', () async {
    await wc.setThemeMode(ThemeMode.dark);
    await pumpEventQueue();

    expect(_lastMeta(view.posted), isNull,
        reason: '알림마다 보내면 토큰 합산 DB 조회가 반복된다');
  });

  test('설정이 비어 있으면 setup 에 누락 항목이 실린다', () async {
    await wc.addPreset(name: 'Alt'); // 알림 → chat.meta
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull);
    // 헤더의 설정 안내 버튼 근거. LLM 미설정 + Python 미설정.
    expect(meta!['setup'], containsAll(<String>['llm', 'python']));
  });

  test('LLM 을 설정하면 setup 에서 llm 이 빠진다', () async {
    await wc.updatePreset(wc.defaultPresetId,
        config: const LlmConfig(baseUrl: 'http://x/v1', model: 'm'));
    await pumpEventQueue();

    final meta = _lastMeta(view.posted);
    expect(meta, isNotNull);
    expect(meta!['setup'], isNot(contains('llm')));
    // Python 은 여전히 미설정이라 안내는 남는다.
    expect(meta['setup'], contains('python'));
  });

  /// ★ 좌측 메뉴의 스피너는 `session.isBusy` 를 본다. 그 값이 바뀌었다고
  /// **아무도 말해 주지 않으면** 메뉴가 다시 그려지지 않아, 생성이 끝났는데도
  /// 스피너가 계속 돌았다(2026-09-13). 시작·종료 양쪽 다 알려야 한다.
  test('생성 시작과 종료를 세션에 알린다', () async {
    var notifications = 0;
    session.addListener(() => notifications++);

    // 시작점 미리보기는 생성 플래그를 세우고 finally 에서 내리는 가장 짧은 경로다.
    view.emit(jsonEncode({'type': 'chat.checkpoint.preview', 'size': 200}));
    await pumpEventQueue();

    expect(session.isBusy, isFalse, reason: '끝났으면 내려가 있어야 한다');
    expect(notifications, greaterThanOrEqualTo(2),
        reason: '켜짐·꺼짐을 둘 다 알려야 스피너가 멎는다 (받은 알림: $notifications)');
  });

  test('웹의 settings.open 은 섹션과 함께 네이티브로 전달된다', () async {
    final v = _FakeWebView();
    String? section;
    final b = WebBridge(wc, session,
        llmClient: _StubProvider(), onOpenSettings: (s) => section = s);
    await b.start();
    await b.attachView(v);

    v.emit(jsonEncode({'type': 'settings.open', 'section': 'tools'}));
    await pumpEventQueue();

    expect(section, 'tools');
    await b.dispose();
    await v.dispose();
  });

  test('dispose 후에는 컨트롤러 변경을 더 보내지 않는다', () async {
    await bridge.dispose();
    view.posted.clear();

    await wc.addPreset(name: 'After dispose');
    await pumpEventQueue();

    expect(_lastMeta(view.posted), isNull);
  });
}
