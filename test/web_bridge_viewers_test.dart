import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/viewers/viewer_assets.dart';
import 'package:collabo_ide/src/viewers/viewer_rule.dart';
import 'package:collabo_ide/src/viewers/viewer_source.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 웹으로 실행된 스크립트를 모아 두는 가짜 웹뷰.
class _FakeWebView implements PlatformWebView {
  final StreamController<dynamic> _messages =
      StreamController<dynamic>.broadcast();

  /// executeScript 로 주입된 JS 원문.
  final List<String> scripts = [];

  @override
  Future<void> initialize() async {}

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  Stream<void> get pageFinished => Stream<void>.empty();

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<void> postMessage(String json) async {}

  @override
  Future<void> executeScript(String script) async => scripts.add(script);

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

/// 마지막 `collaboSyncUserViewers(...)` 주입의 URL 목록(없으면 null).
/// path_provider 가 없는 테스트에서는 스테이징을 스텁으로 갈아끼우므로,
/// 여기서 보는 건 "웹에 무엇을 넘겼는지" 뿐이다.
List<String>? _lastSyncedUrls(List<String> scripts) {
  final arg = _lastCallArg(scripts, 'collaboSyncUserViewers');
  return arg == null ? null : (arg as List).cast<String>();
}

/// 마지막 `collaboSetViewerRules({rules,order})` 주입의 규칙 맵(없으면 null).
Map<String, Object?>? _lastRules(List<String> scripts) {
  final cfg = _lastViewerCfg(scripts);
  return cfg == null ? null : (cfg['rules'] as Map).cast<String, Object?>();
}

/// 마지막 주입의 우선순위 목록(없으면 null).
List<String>? _lastOrder(List<String> scripts) {
  final cfg = _lastViewerCfg(scripts);
  return cfg == null ? null : (cfg['order'] as List).cast<String>();
}

Map<String, Object?>? _lastViewerCfg(List<String> scripts) {
  final arg = _lastCallArg(scripts, 'collaboSetViewerRules');
  return arg == null ? null : (arg as Map).cast<String, Object?>();
}

/// 주입된 JS 에서 `<name>(<json>)` 의 인자를 꺼낸다.
Object? _lastCallArg(List<String> scripts, String name) {
  for (final s in scripts.reversed) {
    final i = s.indexOf('$name(');
    if (i == -1) continue;
    final start = s.indexOf('(', i);
    final end = s.lastIndexOf(')');
    return jsonDecode(s.substring(start + 1, end));
  }
  return null;
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late _FakeWebView view;
  late WorkspaceController wc;
  late WebBridge bridge;

  /// 스테이징 스텁: 복사 없이 상대 URL 만 만들어 준다(호출 인자도 기록).
  late List<List<ViewerSource>> staged;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_viewers_');
    db = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
    wc = WorkspaceController();
    await wc.loadViewersForTest(db);
    staged = [];
    view = _FakeWebView();
    bridge = WebBridge(
      view,
      wc,
      llmClient: _StubProvider(),
      viewerStager: (sources) async {
        staged.add(sources);
        return [for (final s in sources) './viewers/user/${s.stagedName}'];
      },
    )..start();
    view.scripts.clear();
  });

  tearDown(() async {
    await bridge.dispose();
    await view.dispose();
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('ready 를 받으면 등록된 사용자 뷰어를 웹에 얹는다', () async {
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();
    view.scripts.clear();

    // 페이지가 (다시) 로드되면 등록된 뷰어는 사라진 상태다.
    view.emit(jsonEncode({'type': 'ready'}));
    await pumpEventQueue();

    final urls = _lastSyncedUrls(view.scripts);
    expect(urls, isNotNull, reason: 'ready 후 다시 얹어야 한다');
    expect(urls!.single, startsWith('./viewers/user/image_'));
  });

  test('뷰어를 추가하면 앱 재시작 없이 웹에 반영된다', () async {
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();

    expect(staged.length, 1);
    expect(staged.single.single.path, '/a/image.js');
    expect(_lastSyncedUrls(view.scripts)?.length, 1);
  });

  test('뷰어를 제거하면 빠진 목록이 그대로 전달된다', () async {
    const v = ViewerSource(path: '/a/image.js');
    await wc.addViewerSource(v);
    await pumpEventQueue();
    view.scripts.clear();

    await wc.removeViewerSource(v);
    await pumpEventQueue();

    // 웹이 목록에서 빠진 스크립트를 내린다 — 빈 목록도 반드시 보내야 한다.
    expect(_lastSyncedUrls(view.scripts), isEmpty);
  });

  test('같은 뷰어를 두 번 추가해도 한 번만 반영된다', () async {
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();

    expect(staged.length, 1, reason: '중복은 컨트롤러가 무시한다');
  });

  test('뷰어와 무관한 변경(테마)은 다시 얹지 않는다', () async {
    await wc.setThemeMode(ThemeMode.dark);
    await pumpEventQueue();

    expect(staged, isEmpty, reason: '알림마다 얹으면 파일 복사가 반복된다');
    expect(_lastSyncedUrls(view.scripts), isNull);
  });

  test('dispose 후에는 더 얹지 않는다', () async {
    await bridge.dispose();
    view.scripts.clear();

    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();

    expect(_lastSyncedUrls(view.scripts), isNull);
  });

  test('ready 를 받으면 뷰어 설정도 웹에 적용한다', () async {
    await wc.setViewerRule('markdown', const ViewerRule(enabled: false));
    await pumpEventQueue();
    view.scripts.clear();

    view.emit(jsonEncode({'type': 'ready'}));
    await pumpEventQueue();

    final rules = _lastRules(view.scripts);
    expect(rules, isNotNull, reason: '파일을 열기 전에 규칙이 적용돼 있어야 한다');
    expect((rules!['markdown'] as Map)['enabled'], false);
  });

  test('확장자 override 를 바꾸면 즉시 웹에 반영된다', () async {
    await wc.setViewerRule('text', const ViewerRule(extensions: ['.log']));
    await pumpEventQueue();

    final rules = _lastRules(view.scripts);
    expect((rules!['text'] as Map)['extensions'], ['.log']);
  });

  test('기본값으로 되돌리면 항목이 빠진 규칙이 전달된다', () async {
    await wc.setViewerRule('text', const ViewerRule(extensions: ['.log']));
    await pumpEventQueue();
    view.scripts.clear();

    await wc.resetViewerRule('text');
    await pumpEventQueue();

    // 빈 맵도 반드시 보내야 한다 — 웹이 덮어쓴 값을 되돌릴 근거다.
    expect(_lastRules(view.scripts), isEmpty);
    expect(wc.viewerRules, isEmpty);
  });

  test('규칙만 바뀌면 파일 스테이징은 다시 하지 않는다', () async {
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js'));
    await pumpEventQueue();
    expect(staged.length, 1);

    await wc.setViewerRule('image', const ViewerRule(extensions: ['.png']));
    await pumpEventQueue();

    expect(staged.length, 1, reason: '규칙 변경으로 파일을 다시 복사할 이유가 없다');
    expect(_lastRules(view.scripts), isNotNull);
  });

  test('순서를 바꾸면 우선순위 목록이 웹에 전달된다', () async {
    await wc.setViewerOrder(['markdown-editor', 'markdown', 'text']);
    await pumpEventQueue();

    expect(_lastOrder(view.scripts), ['markdown-editor', 'markdown', 'text']);
  });

  test('순서 초기화는 빈 목록을 보낸다 (등록 순서로 복귀)', () async {
    await wc.setViewerOrder(['markdown-editor', 'markdown']);
    await pumpEventQueue();
    view.scripts.clear();

    await wc.resetViewerOrder();
    await pumpEventQueue();

    expect(_lastOrder(view.scripts), isEmpty);
    expect(wc.viewerOrder, isEmpty);
  });

  test('같은 순서를 다시 저장하면 아무것도 보내지 않는다', () async {
    await wc.setViewerOrder(['a', 'b']);
    await pumpEventQueue();
    view.scripts.clear();

    await wc.setViewerOrder(['a', 'b']);
    await pumpEventQueue();

    expect(_lastViewerCfg(view.scripts), isNull);
  });

  test('웹이 보고한 뷰어 목록을 컨트롤러가 들고 있는다', () async {
    view.emit(jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {
          'id': 'markdown',
          'label': 'Markdown',
          'dataMode': 'text',
          'extensions': ['.md'],
          'user': false,
        },
        {
          'id': 'image',
          'label': 'Image',
          'dataMode': 'hex',
          'extensions': ['.png'],
          'user': true,
        },
      ],
    }));
    await pumpEventQueue();

    final list = wc.registeredViewers;
    expect(list.map((v) => v.id), ['markdown', 'image']);
    expect(list.last.user, isTrue);
    expect(list.last.dataMode, 'hex');
    // 적용 확장자 = override 없으면 선언값.
    expect(wc.effectiveExtensionsFor(list.first), ['.md']);
  });

  test('목록 보고가 규칙 재전송을 유발하지 않는다 (순환 방지)', () async {
    final report = jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {'id': 'text', 'label': 'Text', 'dataMode': 'text', 'extensions': []},
      ],
    });
    view.emit(report);
    await pumpEventQueue();
    view.scripts.clear();

    // 같은 목록을 다시 보고해도 알림/재전송이 없어야 한다.
    view.emit(report);
    await pumpEventQueue();

    expect(_lastRules(view.scripts), isNull);
    expect(_lastSyncedUrls(view.scripts), isNull);
  });

  test('override 가 있으면 적용 확장자가 그것으로 바뀐다', () async {
    view.emit(jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {'id': 'text', 'label': 'Text', 'dataMode': 'text', 'extensions': []},
      ],
    }));
    await pumpEventQueue();
    await wc.setViewerRule('text', const ViewerRule(extensions: ['.dat']));

    expect(wc.effectiveExtensionsFor(wc.registeredViewers.single), ['.dat']);
  });

  test('메인 DB 에 저장되고 다시 읽힌다 (구버전 문자열 포함)', () async {
    await wc.addViewerSource(const ViewerSource(path: '/a/image.js', label: 'Img'));
    await pumpEventQueue();

    final reloaded = WorkspaceController();
    await reloaded.loadViewersForTest(db);
    expect(reloaded.viewerSources.single.path, '/a/image.js');
    expect(reloaded.viewerSources.single.label, 'Img');

    // 경로 문자열만 저장된 형태도 읽어야 한다.
    await db.setSetting('viewer_sources', ['/b/legacy.js']);
    final legacy = WorkspaceController();
    await legacy.loadViewersForTest(db);
    expect(legacy.viewerSources.single.path, '/b/legacy.js');
    // 여기서 dispose 하면 공용 db 를 닫아 버린다 — tearDown 이 정리한다.
  });

  test('뷰어 설정도 메인 DB 에 저장되고 다시 읽힌다', () async {
    await wc.setViewerRule('text', const ViewerRule(extensions: ['.log', '.out']));
    await wc.setViewerRule('markdown', const ViewerRule(enabled: false));
    await wc.setViewerOrder(['markdown-editor', 'text']);
    await pumpEventQueue();

    final reloaded = WorkspaceController();
    await reloaded.loadViewersForTest(db);
    expect(reloaded.viewerRuleFor('text').extensions, ['.log', '.out']);
    expect(reloaded.viewerRuleFor('markdown').enabled, isFalse);
    expect(reloaded.viewerOrder, ['markdown-editor', 'text']);
    // 저장된 적 없는 뷰어는 기본값.
    expect(reloaded.viewerRuleFor('hex').isDefault, isTrue);
  });

  test('설정 화면의 표시 순서 = 사용자 순서 → 등록 순서', () async {
    view.emit(jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {'id': 'markdown', 'label': 'MD', 'dataMode': 'text'},
        {'id': 'editor', 'label': 'Edit', 'dataMode': 'text'},
        {'id': 'text', 'label': 'Text', 'dataMode': 'text'},
      ],
    }));
    await pumpEventQueue();

    // 순서를 정하지 않았으면 웹이 보고한(등록) 순서 그대로.
    expect(wc.orderedViewers.map((v) => v.id), ['markdown', 'editor', 'text']);

    // 일부만 정하면 정한 것이 앞, 나머지는 등록 순서로 뒤에 붙는다.
    await wc.setViewerOrder(['editor']);
    expect(wc.orderedViewers.map((v) => v.id), ['editor', 'markdown', 'text']);
  });

  test('예제 뷰어는 아직 추가하지 않은 것만 권한다', () async {
    wc.setViewerExamplesForTest(const [
      ViewerExample(
        assetKey: 'assets/web/viewers/examples/markdown-editor.js',
        fileName: 'markdown-editor.js',
      ),
    ]);
    expect(wc.availableViewerExamples, hasLength(1));

    // 같은 파일명이 사용자 뷰어로 들어오면(=예제를 추가함) 목록에서 빠진다.
    await wc.addViewerSource(
        const ViewerSource(path: '/support/web/viewers/examples/markdown-editor.js'));
    await pumpEventQueue();

    expect(wc.availableViewerExamples, isEmpty);
  });

  test('보고된 목록은 캐시되어 웹뷰 없이도(프로젝트 미오픈) 쓸 수 있다', () async {
    view.emit(jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {
          'id': 'markdown',
          'label': 'Markdown',
          'dataMode': 'text',
          'extensions': ['.md'],
        },
      ],
    }));
    await pumpEventQueue();

    // 새 세션(웹뷰가 아직/전혀 없는 상태)에서도 목록이 복원돼야 한다 —
    // 웹뷰는 프로젝트가 열려 있을 때만 존재하므로 캐시가 유일한 근거다.
    final reloaded = WorkspaceController();
    await reloaded.loadViewersForTest(db);
    expect(reloaded.registeredViewers.single.id, 'markdown');
    expect(reloaded.registeredViewers.single.defaultExtensions, ['.md']);
  });

  test('빈 보고는 캐시를 지우지 않는다 (기동 직후 빈 보고 방어)', () async {
    view.emit(jsonEncode({
      'type': 'viewers.list',
      'viewers': [
        {'id': 'text', 'label': 'Text', 'dataMode': 'text'},
      ],
    }));
    await pumpEventQueue();

    view.emit(jsonEncode({'type': 'viewers.list', 'viewers': []}));
    await pumpEventQueue();

    expect(wc.registeredViewers.single.id, 'text');
  });
}
