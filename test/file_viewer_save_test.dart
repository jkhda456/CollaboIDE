import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/files/file_viewer.dart';
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
  late ProjectSession session;
  late FileViewerController viewer;

  /// 웹이 보내는 저장 요청. 결과가 올 때까지 기다린다.
  ///
  /// 저장은 실제 파일 IO 를 여러 번 지난다(존재 확인 → realpath → 쓰기). 큐를 한 번만
  /// 돌리면 그 전에 돌아와 가끔 빈손이었다 — 답이 올 때까지(최대 ~1초) 돈다.
  Future<Map<String, Object?>?> save(String path, String content) async {
    view.posted.clear();
    view.emit(jsonEncode({'type': 'file.save', 'path': path, 'content': content}));
    for (var i = 0; i < 100; i++) {
      await pumpEventQueue();
      final m = _lastSaved(view.posted);
      if (m != null) return m;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return null;
  }

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_save_');
    project = Directory(p.join(tmp.path, 'proj'));
    await project.create();
    view = _FakeWebView();
    wc = WorkspaceController();
    session = await ProjectSession.open(
      project.path,
      browser: BrowserController(),
      firstConversationTitle: 'test',
    );
    // 사용자가 직접 누른 저장은 뷰어 웹뷰(viewer.html)의 요청이다 → 파일 뷰어 컨트롤러가 받는다.
    viewer = FileViewerController(wc, session.files, viewerStager: (_) async => const []);
    session.viewer = viewer;
    await viewer.attachView(view);
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('프로젝트 안의 파일을 저장한다', () async {
    final f = File(p.join(project.path, 'note.md'));
    await f.writeAsString('old');

    final result = await save(f.path, '새 내용\n둘째 줄');

    expect(result?['ok'], true);
    expect(await f.readAsString(), '새 내용\n둘째 줄');
  });

  test('프로젝트 밖 경로는 거부하고 파일을 건드리지 않는다', () async {
    final outside = File(p.join(tmp.path, 'outside.md'));
    await outside.writeAsString('원본');

    final result = await save(outside.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await outside.readAsString(), '원본', reason: '쓰기는 되돌릴 수 없다');
  });

  test('형제 prefix 경로(proj-evil)도 프로젝트 밖으로 본다', () async {
    final sibling = Directory(p.join(tmp.path, 'proj-evil'));
    await sibling.create();
    final f = File(p.join(sibling.path, 'note.md'));
    await f.writeAsString('원본');

    final result = await save(f.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await f.readAsString(), '원본');
  });

  test('없는 파일은 만들지 않는다 (뷰어는 열려 있는 파일만 저장한다)', () async {
    final missing = p.join(project.path, 'nope.md');

    final result = await save(missing, 'x');

    expect(result?['ok'], false);
    expect(File(missing).existsSync(), isFalse);
  });

  // 예전에는 "프로젝트가 열려 있지 않으면 거부한다" 를 여기서 봤다. 뷰어가
  // 세션의 것이 된 뒤로는 프로젝트 없는 뷰어를 만들 수 없어 그 경우가 사라졌다.
  // 대신 **다른 프로젝트의 파일**은 여전히 남이라는 것을 본다 — 여러 프로젝트가
  // 동시에 열려 있으므로 이쪽이 실제로 일어나는 상황이다.
  test('다른 프로젝트의 파일은 저장하지 않는다', () async {
    final other = Directory(p.join(tmp.path, 'other'));
    await other.create();
    final f = File(p.join(other.path, 'note.md'));
    await f.writeAsString('원본');

    final result = await save(f.path, '덮어쓰기');

    expect(result?['ok'], false);
    expect(await f.readAsString(), '원본');
  });
}
