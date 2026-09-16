import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
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

/// 트리 우클릭 메뉴(새 파일/새 폴더/이름 변경/삭제)와 드래그 이동의 **가드**를 본다.
///
/// 핵심 규칙은 "프로젝트 안이고 `.collabo` 가 아닌 것만 건드린다" 이다.
/// 통과하면 실제로 반영되는지, 막히면 **디스크가 그대로인지** 양쪽을 확인한다.
void main() {
  late Directory tmp;
  late Directory project;
  late _FakeWebView view;
  late WorkspaceController wc;
  late ProjectSession session;
  late WebBridge bridge;

  /// 웹이 보내는 메시지 하나를 흘려 넣고 결과가 나올 때까지 큐를 돌린다.
  Future<void> emit(Map<String, Object?> msg) async {
    view.posted.clear();
    view.emit(jsonEncode(msg));
    await pumpEventQueue();
  }

  Map<String, Object?>? lastOfType(String type) {
    for (final m in view.posted.reversed) {
      if (m['type'] == type) return m;
    }
    return null;
  }

  bool errored() => lastOfType('fs.error') != null;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_fs_');
    project = Directory(p.join(tmp.path, 'proj'));
    await project.create();
    view = _FakeWebView();
    wc = WorkspaceController();
    // 브리지는 이제 **세션의 것**이다 — 프로젝트를 열어 세션을 만들고, 웹뷰는
    // 거기에 붙인다(`setProject` 로 갈아타던 방식은 없어졌다).
    session = await ProjectSession.open(
      project.path,
      browser: BrowserController(),
      firstConversationTitle: 'test',
    );
    bridge = WebBridge(
      wc,
      session,
      llmClient: _StubProvider(),
      viewerStager: (_) async => const [],
    );
    session.bridge = bridge;
    await bridge.start();
    await bridge.attachView(view);
  });

  tearDown(() async {
    await session.close();
    await view.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('새로 만들기', () {
    test('폴더 안에 파일을 만들고 fs.created 로 알린다', () async {

      await emit({
        'type': 'fs.create',
        'parent': project.path,
        'name': 'note.md',
        'dir': false,
      });

      expect(lastOfType('fs.created')?['isDir'], false);
      expect(File(p.join(project.path, 'note.md')).existsSync(), isTrue);
    });

    test('폴더도 만든다', () async {

      await emit({
        'type': 'fs.create',
        'parent': project.path,
        'name': 'src',
        'dir': true,
      });

      expect(lastOfType('fs.created')?['isDir'], true);
      expect(Directory(p.join(project.path, 'src')).existsSync(), isTrue);
    });

    test('이미 있는 이름은 덮어쓰지 않는다', () async {
      final f = File(p.join(project.path, 'note.md'));
      await f.writeAsString('원본');

      await emit({
        'type': 'fs.create',
        'parent': project.path,
        'name': 'note.md',
        'dir': false,
      });

      expect(errored(), isTrue);
      expect(await f.readAsString(), '원본');
    });

    test('이름 규칙(경로 구분자·예약어)을 어기면 만들지 않는다', () async {

      for (final name in ['a/b', '..', 'CON', 'end.', '']) {
        await emit({
          'type': 'fs.create',
          'parent': project.path,
          'name': name,
          'dir': false,
        });
        expect(errored(), isTrue, reason: '이름 "$name" 은 막혀야 한다');
      }
      // 어느 것도 만들어지지 않았다(하위 폴더 생성 시도 포함).
      expect(project.listSync(), isEmpty);
    });

    test('프로젝트 밖 폴더에는 만들지 않는다', () async {

      await emit({
        'type': 'fs.create',
        'parent': tmp.path,
        'name': 'evil.txt',
        'dir': false,
      });

      expect(errored(), isTrue);
      expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
    });

    // 예전에는 "프로젝트가 열려 있지 않으면 거부한다" 를 여기서 봤다. 브리지가
    // 세션의 것이 된 뒤로는 **프로젝트 없는 브리지가 존재할 수 없어서** 그 경우를
    // 만들 수 없다. `_resolveUserPath` 의 null 가드는 fail-safe 로 남겨 두었다.
    test('브리지는 자기 프로젝트를 들고 있다', () async {
      await emit({
        'type': 'fs.create',
        'parent': project.path,
        'name': 'note.md',
        'dir': false,
      });

      expect(errored(), isFalse);
      expect(File(p.join(project.path, 'note.md')).existsSync(), isTrue);
    });
  });

  group('이름 변경', () {
    test('같은 폴더 안에서 이름을 바꾸고 fs.renamed 로 알린다', () async {
      final f = File(p.join(project.path, 'old.md'));
      await f.writeAsString('내용');

      await emit({'type': 'fs.rename', 'path': f.path, 'name': 'new.md'});

      expect(lastOfType('fs.renamed')?['to'], p.join(project.path, 'new.md'));
      expect(f.existsSync(), isFalse);
      expect(await File(p.join(project.path, 'new.md')).readAsString(), '내용');
    });

    test('이미 있는 이름으로는 바꾸지 않는다', () async {
      final a = File(p.join(project.path, 'a.md'));
      final b = File(p.join(project.path, 'b.md'));
      await a.writeAsString('A');
      await b.writeAsString('B');

      await emit({'type': 'fs.rename', 'path': a.path, 'name': 'b.md'});

      expect(errored(), isTrue);
      expect(await a.readAsString(), 'A');
      expect(await b.readAsString(), 'B');
    });

    test('프로젝트 루트 자신은 바꿀 수 없다', () async {

      await emit({'type': 'fs.rename', 'path': project.path, 'name': 'other'});

      expect(errored(), isTrue);
      expect(project.existsSync(), isTrue);
    });
  });

  group('삭제', () {
    test('파일을 지우고 fs.deleted 로 알린다', () async {
      final f = File(p.join(project.path, 'note.md'));
      await f.writeAsString('내용');

      await emit({'type': 'fs.delete', 'path': f.path});

      expect(lastOfType('fs.deleted')?['path'], f.path);
      expect(f.existsSync(), isFalse);
    });

    test('폴더는 안에 든 것까지 지운다', () async {
      final dir = Directory(p.join(project.path, 'src'));
      await dir.create();
      await File(p.join(dir.path, 'main.dart')).writeAsString('void main() {}');

      await emit({'type': 'fs.delete', 'path': dir.path});

      expect(dir.existsSync(), isFalse);
    });

    test('프로젝트 루트는 지울 수 없다', () async {

      await emit({'type': 'fs.delete', 'path': project.path});

      expect(errored(), isTrue);
      expect(project.existsSync(), isTrue);
    });

    test('프로젝트 밖은 지울 수 없다', () async {
      final outside = File(p.join(tmp.path, 'outside.md'));
      await outside.writeAsString('원본');

      await emit({'type': 'fs.delete', 'path': outside.path});

      expect(errored(), isTrue);
      expect(outside.existsSync(), isTrue);
    });

    test('형제 prefix 경로(proj-evil)도 프로젝트 밖으로 본다', () async {
      final sibling = Directory(p.join(tmp.path, 'proj-evil'));
      await sibling.create();

      await emit({'type': 'fs.delete', 'path': sibling.path});

      expect(errored(), isTrue);
      expect(sibling.existsSync(), isTrue);
    });
  });

  group('.collabo 는 앱이 관리한다', () {
    late Directory collabo;

    setUp(() async {
      collabo = Directory(p.join(project.path, '.collabo'));
      await collabo.create();
      await File(p.join(collabo.path, 'conversation.db')).writeAsString('db');
    });

    test('폴더 자체를 지울 수 없다', () async {
      await emit({'type': 'fs.delete', 'path': collabo.path});

      expect(errored(), isTrue);
      expect(collabo.existsSync(), isTrue);
    });

    test('안에 든 파일도 지울 수 없다', () async {
      final db = File(p.join(collabo.path, 'conversation.db'));

      await emit({'type': 'fs.delete', 'path': db.path});

      expect(errored(), isTrue);
      expect(db.existsSync(), isTrue);
    });

    test('이름도 바꿀 수 없다', () async {
      await emit({'type': 'fs.rename', 'path': collabo.path, 'name': 'x'});

      expect(errored(), isTrue);
      expect(collabo.existsSync(), isTrue);
    });

    test('드래그로 옮길 수도 없다', () async {
      final dst = Directory(p.join(project.path, 'sub'));
      await dst.create();

      await emit({'type': 'fs.move', 'src': collabo.path, 'dst': dst.path});

      expect(errored(), isTrue);
      expect(collabo.existsSync(), isTrue);
      expect(Directory(p.join(dst.path, '.collabo')).existsSync(), isFalse);
    });
  });
}
