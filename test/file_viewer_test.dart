import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/files/file_viewer.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _FakeWebView implements PlatformWebView {
  final StreamController<dynamic> _messages = StreamController<dynamic>.broadcast();
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
  Future<void> postMessage(String json) async => posted.add(jsonDecode(json) as Map<String, Object?>);
  @override
  Future<void> executeScript(String script) async {}
  @override
  Widget buildView() => const SizedBox.shrink();
  @override
  bool get needsWheelWorkaround => false;

  void emit(Map<String, Object?> m) => _messages.add(jsonEncode(m));
  List<Map<String, Object?>> ofType(String t) => [for (final m in posted) if (m['type'] == t) m];

  @override
  Future<void> dispose() async => _messages.close();
}

class _StubProvider implements LlmProvider {
  @override
  Future<LlmTestResult> test(LlmConfig cfg) async => const LlmTestResult(true, 'ok');
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

/// 파일 뷰어 — 네이티브 틀([FileViewerController])과 뷰어 웹뷰(viewer.html) 사이의 계약,
/// 그리고 대화 페이지가 파일을 열어 달라고 할 때의 경로(대화 브리지 → 세션 → 뷰어).
void main() {
  late Directory tmp;
  late WorkspaceController wc;
  late ProjectSession session;
  late FileViewerController viewer;
  late _FakeWebView view;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_viewer_');
    wc = WorkspaceController();
    session = await ProjectSession.open(tmp.path, browser: BrowserController(), firstConversationTitle: 't');
    viewer = FileViewerController(wc, session.files, viewerStager: (_) async => const []);
    session.viewer = viewer;
    view = _FakeWebView();
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('열기는 웹에 viewer.open 을 보내고, 틀은 읽는 중으로 바뀐다', () async {
    await viewer.attachView(view);
    final f = p.join(tmp.path, 'a.md');
    viewer.open(f);
    await pumpEventQueue();
    expect(view.ofType('viewer.open').single['path'], f);
    expect(viewer.path, f);
    expect(viewer.loading, isTrue);
  });

  test('웹뷰가 없을 때 연 파일은 웹이 준비되면(ready) 다시 연다', () async {
    final f = p.join(tmp.path, 'a.md');
    viewer.open(f); // 화면이 아직 없다 — 조용히 버려진다
    await viewer.attachView(view);
    view.posted.clear();
    view.emit({'type': 'ready'});
    await pumpEventQueue();
    expect(view.ofType('viewer.open').single['path'], f);
  });

  test('웹의 viewer.state 로 틀을 그린다 — 늦게 온 다른 파일의 보고는 버린다', () async {
    await viewer.attachView(view);
    final a = p.join(tmp.path, 'a.md'), b = p.join(tmp.path, 'b.md');
    viewer.open(b);
    view.emit({
      'type': 'viewer.state',
      'path': a, // 앞서 열던 파일의 늦은 보고
      'viewerId': 'text',
      'viewers': [
        {'id': 'text', 'label': 'Text'},
      ],
    });
    await pumpEventQueue();
    expect(viewer.path, b);
    expect(viewer.viewers, isEmpty);

    view.emit({
      'type': 'viewer.state',
      'path': b,
      'viewerId': 'markdown',
      'viewers': [
        {'id': 'markdown', 'label': 'Markdown'},
        {'id': 'text', 'label': 'Text'},
      ],
      'notice': '대용량 파일: 앞부분만 표시합니다 (3.0 MB)',
      'loading': false,
    });
    await pumpEventQueue();
    expect(viewer.viewerLabel, 'Markdown');
    expect(viewer.viewers.map((v) => v.id), ['markdown', 'text']);
    expect(viewer.notice, contains('3.0 MB'));
    expect(viewer.loading, isFalse);
  });

  test('드롭다운으로 고른 뷰어로 다시 연다', () async {
    await viewer.attachView(view);
    final f = p.join(tmp.path, 'a.md');
    viewer.open(f);
    view.posted.clear();
    viewer.open(f, viewerId: 'text');
    await pumpEventQueue();
    expect(view.ofType('viewer.open').single['viewerId'], 'text');
  });

  test('파일 변경은 웹으로 넘긴다(보고 있는 파일이면 웹이 다시 읽는다)', () async {
    await viewer.attachView(view);
    await session.files.create(tmp.path, 'x.txt', dir: false);
    await settle();
    final changes = view.ofType('fs.change');
    expect(changes, isNotEmpty);
    expect((changes.last['files'] as List).map((f) => p.basename('$f')), contains('x.txt'));
  });

  test('만든 파일은 바로 열고, 이름을 바꾸면 따라가고, 지우면 닫는다', () async {
    await viewer.attachView(view);
    final made = await session.files.create(tmp.path, 'draft.md', dir: false);
    await settle();
    expect(viewer.path, made, reason: '만든 파일은 바로 열어 편집할 수 있게');

    final renamed = await session.files.rename(made!, 'final.md');
    await settle();
    expect(viewer.path, renamed);

    await session.files.delete(renamed!);
    await settle();
    expect(viewer.path, isNull);
    expect(view.ofType('viewer.clear'), isNotEmpty);
  });

  test('폴더째 옮기면 그 안에서 보던 파일도 따라간다', () async {
    await viewer.attachView(view);
    final dir = Directory(p.join(tmp.path, 'docs'))..createSync();
    final f = File(p.join(dir.path, 'a.md'))..writeAsStringSync('x');
    Directory(p.join(tmp.path, 'archive')).createSync();
    viewer.open(f.path);
    await session.files.move(dir.path, p.join(tmp.path, 'archive'));
    await settle();
    expect(viewer.path, p.join(tmp.path, 'archive', 'docs', 'a.md'));
  });

  test('웹에서 온 Esc 는 전체화면을 푼다', () async {
    await viewer.attachView(view);
    viewer.setFullscreen(true);
    view.emit({'type': 'viewer.escape'});
    await pumpEventQueue();
    expect(viewer.fullscreen, isFalse);
  });

  group('대화 페이지에서', () {
    late WebBridge bridge;
    late _FakeWebView chat;

    setUp(() async {
      chat = _FakeWebView();
      bridge = WebBridge(wc, session, llmClient: _StubProvider());
      session.bridge = bridge;
      await bridge.start();
      await bridge.attachView(chat);
      await viewer.attachView(view);
    });

    tearDown(() => chat.dispose());

    test('file.open 은 네이티브 뷰어로 간다 — 패널을 펴고 트리에서 보이게 한다', () async {
      final nested = Directory(p.join(tmp.path, '.collabo'))..createSync();
      final plan = File(p.join(nested.path, 'PLAYBOOK.md'))..writeAsStringSync('# PLAYBOOK');
      session.sidePanelVisible.value = false;
      chat.emit({'type': 'file.open', 'path': plan.path});
      await pumpEventQueue();
      expect(session.sidePanelVisible.value, isTrue);
      expect(viewer.path, plan.path);
      expect(session.files.isExpanded(nested.path), isTrue);
      expect(session.files.selected, plan.path);
      expect(view.ofType('viewer.open').last['path'], plan.path);
    });

    test('헤더의 우측 패널 토글', () async {
      expect(session.sidePanelVisible.value, isTrue);
      chat.emit({'type': 'layout.toggleRight'});
      await pumpEventQueue();
      expect(session.sidePanelVisible.value, isFalse);
    });

    test('대화 페이지에는 트리·뷰어 메시지가 더는 가지 않는다', () async {
      chat.posted.clear();
      await session.files.create(tmp.path, 'y.txt', dir: false);
      await settle();
      expect(chat.ofType('fs.change'), isEmpty);
      expect(chat.ofType('dir.children'), isEmpty);
    });
  });
}
