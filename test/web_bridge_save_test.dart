import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:collabo_ide/src/llm/llm_provider.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

Map<String, Object?>? _lastSaved(List<Map<String, Object?>> posted) {
  for (final m in posted.reversed) {
    if (m['type'] == 'file.saved') return m;
  }
  return null;
}

void main() {
  late Directory tmp;
  late Directory project;
  late _FakeWebView view;
  late WorkspaceController wc;
  late WebBridge bridge;

  /// 웹이 보내는 저장 요청. 결과가 올 때까지 이벤트 큐를 돌린다.
  Future<Map<String, Object?>?> save(String path, String content) async {
    view.posted.clear();
    view.emit(jsonEncode({'type': 'file.save', 'path': path, 'content': content}));
    await pumpEventQueue();
    return _lastSaved(view.posted);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_save_');
    project = Directory(p.join(tmp.path, 'proj'));
    await project.create();
    view = _FakeWebView();
    wc = WorkspaceController();
    bridge = WebBridge(
      view,
      wc,
      llmClient: _StubProvider(),
      viewerStager: (_) async => const [],
    )..start();
  });

  tearDown(() async {
    await bridge.dispose();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('프로젝트 안의 파일을 저장한다', () async {
    final f = File(p.join(project.path, 'note.md'));
    await f.writeAsString('old');
    await bridge.setProject(project.path);

    final result = await save(f.path, '새 내용\n둘째 줄');

    expect(result?['ok'], true);
    expect(await f.readAsString(), '새 내용\n둘째 줄');
  });

  test('프로젝트 밖 경로는 거부하고 파일을 건드리지 않는다', () async {
    final outside = File(p.join(tmp.path, 'outside.md'));
    await outside.writeAsString('원본');
    await bridge.setProject(project.path);

    final result = await save(outside.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await outside.readAsString(), '원본', reason: '쓰기는 되돌릴 수 없다');
  });

  test('형제 prefix 경로(proj-evil)도 프로젝트 밖으로 본다', () async {
    final sibling = Directory(p.join(tmp.path, 'proj-evil'));
    await sibling.create();
    final f = File(p.join(sibling.path, 'note.md'));
    await f.writeAsString('원본');
    await bridge.setProject(project.path);

    final result = await save(f.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await f.readAsString(), '원본');
  });

  test('없는 파일은 만들지 않는다 (뷰어는 열려 있는 파일만 저장한다)', () async {
    await bridge.setProject(project.path);
    final missing = p.join(project.path, 'nope.md');

    final result = await save(missing, 'x');

    expect(result?['ok'], false);
    expect(File(missing).existsSync(), isFalse);
  });

  test('프로젝트가 열려 있지 않으면 거부한다', () async {
    final f = File(p.join(project.path, 'note.md'));
    await f.writeAsString('원본');

    final result = await save(f.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await f.readAsString(), '원본');
  });
}
