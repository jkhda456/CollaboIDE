import 'dart:io';

import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/conversation/models.dart';
import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// **프로젝트를 여러 개 열어 둘 수 있다**는 것을 잠근다.
///
/// 예전에는 `openProject` 가 이전 대화 DB 를 닫고 그 자리를 덮어썼다. 그래서 다른
/// 프로젝트를 열었다 돌아오면 진행 상황이 조각조각 사라졌고, 돌고 있던 생성 루프는
/// 웹뷰 패널이 사라지면서 같이 죽었다. 여기서 보는 것은 그 반대다 —
/// **여는 것으로 아무것도 닫히지 않는다.**
void main() {
  late Directory tmp;
  late WorkspaceController wc;

  setUpAll(initSqliteFfi);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_sessions_');
    wc = WorkspaceController();
  });

  tearDown(() async {
    wc.dispose();
    // dispose 는 세션 정리를 기다리지 않는다(비동기) — DB 핸들이 닫힐 틈을 준다.
    await pumpEventQueue();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> makeProject(String name) async {
    final dir = Directory(p.join(tmp.path, name));
    await dir.create(recursive: true);
    return dir.path;
  }

  test('두 번째 프로젝트를 열어도 첫 번째가 닫히지 않는다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');

    await wc.openProject(a);
    expect(wc.sessions.map((s) => s.path), [a]);

    await wc.openProject(b);
    expect(wc.sessions.map((s) => s.path), [a, b], reason: '연 순서를 유지한다');
    expect(wc.projectPath, b, reason: '새로 연 쪽이 활성이 된다');
    expect(wc.isOpen(a), isTrue, reason: '★ 예전에는 여기서 a 가 닫혔다');
  });

  test('프로젝트마다 자기 대화 DB 를 들고 있다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);

    final sa = wc.sessionFor(a)!;
    final sb = wc.sessionFor(b)!;
    expect(identical(sa.conversation, sb.conversation), isFalse);
    expect(sa.conversation.dbPath, startsWith(a));
    expect(sb.conversation.dbPath, startsWith(b));
    expect(sa.activeConversationId, isNotNull);
    expect(sb.activeConversationId, isNotNull);

    // 한쪽에 쓴 것이 다른 쪽에 보이지 않는다(덮어쓰기가 없다는 증거).
    await sa.conversation.addMessage(
      conversationId: sa.activeConversationId!,
      role: MessageRole.user,
      content: 'a 에게만',
    );
    final inA = await sa.conversation.messages(sa.activeConversationId!);
    final inB = await sb.conversation.messages(sb.activeConversationId!);
    expect(inA.single.content, 'a 에게만');
    expect(inB, isEmpty);
  });

  test('이미 열린 프로젝트를 다시 열면 이동만 한다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    final first = wc.sessionFor(a)!;
    await wc.openProject(b);

    await wc.openProject(a);

    expect(wc.sessions, hasLength(2), reason: '두 번 열리지 않는다');
    expect(identical(wc.sessionFor(a), first), isTrue,
        reason: '세션을 새로 만들면 그 프로젝트의 진행 상황이 사라진다');
    expect(wc.projectPath, a);
  });

  test('화면 전환은 아무것도 닫지 않는다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);

    wc.activateProject(a);
    expect(wc.projectPath, a);
    expect(wc.sessions, hasLength(2));

    wc.activateProject(b);
    expect(wc.projectPath, b);
    expect(wc.sessions, hasLength(2));
  });

  test('열지 않은 프로젝트로는 이동하지 않는다', () async {
    final a = await makeProject('a');
    await wc.openProject(a);

    wc.activateProject(p.join(tmp.path, 'nope'));

    expect(wc.projectPath, a);
  });

  test('하나를 닫아도 나머지는 그대로다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);
    final sa = wc.sessionFor(a)!;

    await wc.closeProject(b);

    expect(wc.sessions.map((s) => s.path), [a]);
    expect(wc.projectPath, a, reason: '활성이던 것을 닫으면 이웃을 이어받는다');
    // 남은 쪽 DB 는 계속 쓸 수 있어야 한다(닫힌 DB 를 건드리면 여기서 터진다).
    final id = await sa.conversation.createConversation(title: '살아 있음');
    expect(id, greaterThan(0));
  });

  test('마지막 하나를 닫으면 빈 화면으로 돌아간다', () async {
    final a = await makeProject('a');
    await wc.openProject(a);

    await wc.closeProject(a);

    expect(wc.sessions, isEmpty);
    expect(wc.hasProject, isFalse);
    expect(wc.projectPath, isNull);
  });

  test('활성이 아닌 것을 닫으면 보고 있던 화면은 그대로다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);

    await wc.closeProject(a);

    expect(wc.projectPath, b);
    expect(wc.sessions.map((s) => s.path), [b]);
  });

  test('열린 프로젝트마다 브리지가 따로 붙는다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);

    final ba = wc.sessionFor(a)!.bridge;
    final bb = wc.sessionFor(b)!.bridge;
    expect(ba, isNotNull);
    expect(bb, isNotNull);
    expect(identical(ba, bb), isFalse,
        reason: '브리지를 공유하면 한쪽 생성이 다른 쪽 대화에 쓰인다');
    // 화면이 붙기 전에도 살아 있다 — 루프의 수명은 위젯과 무관하다.
    expect(ba!.isGenerating, isFalse);
  });

  test('백그라운드 명령 수는 열린 전부를 합산한다', () async {
    final a = await makeProject('a');
    final b = await makeProject('b');
    await wc.openProject(a);
    await wc.openProject(b);

    // 실행 중인 것이 없으면 0. (레지스트리는 프로젝트마다 따로다.)
    expect(wc.runningProcessCount, 0);
    expect(wc.busySessionCount, 0);
  });

  test('세션 이름은 폴더 이름이다', () async {
    final a = await makeProject('my-app');
    await wc.openProject(a);
    expect(wc.sessionFor(a)!.name, 'my-app');
  });

  // (venv 경로 시험은 2026-09-23 에 없앴다 — 시스템 파이썬·venv 자체가 빠졌다.)

  /// ★ **열어 둔 프로젝트는 앱을 껐다 켜도 그대로다.** 최근(MRU) 목록과 다른
  /// 개념이다 — MRU 는 "예전에 열었던 것", 이쪽은 "지금 열려 있는 것" 이다.
  group('다음 실행에 복원', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
    });

    tearDown(() async {
      await db.close();
    });

    /// 새 컨트롤러를 그 DB 에 붙여, 앱을 다시 켠 것처럼 만든다.
    Future<WorkspaceController> relaunch() async {
      final next = WorkspaceController();
      addTearDown(() async {
        next.dispose();
        await pumpEventQueue();
      });
      await next.loadOpenProjectsForTest(db);
      await next.restoreOpenProjects();
      return next;
    }

    test('열고 닫을 때마다 목록이 저장된다', () async {
      final a = await makeProject('a');
      final b = await makeProject('b');
      await wc.loadOpenProjectsForTest(db);

      await wc.openProject(a);
      await wc.openProject(b);
      expect(await db.getSetting('open_projects'), [a, b]);
      expect(await db.getSetting('active_project'), b);

      wc.activateProject(a);
      await pumpEventQueue();
      expect(await db.getSetting('active_project'), a);

      await wc.closeProject(a);
      expect(await db.getSetting('open_projects'), [b],
          reason: '닫은 것은 목록에서 사라진다 — 최근 목록으로 내려가는 게 아니다');
    });

    test('열어 둔 목록과 보던 프로젝트가 되살아난다', () async {
      final a = await makeProject('a');
      final b = await makeProject('b');
      await db.setSetting('open_projects', [a, b]);
      await db.setSetting('active_project', a);

      final next = await relaunch();

      expect(next.sessions.map((s) => s.path), [a, b], reason: '연 순서까지');
      expect(next.projectPath, a, reason: '보고 있던 것이 활성으로 돌아온다');
    });

    test('사라진 폴더는 건너뛰고 저장 목록에서도 지운다', () async {
      final a = await makeProject('a');
      final gone = p.join(tmp.path, 'gone'); // 만들지 않는다 = 사라진 폴더
      await db.setSetting('open_projects', [a, gone]);
      await db.setSetting('active_project', gone);

      final next = await relaunch();

      expect(next.sessions.map((s) => s.path), [a]);
      expect(next.projectPath, a, reason: '없는 것을 활성으로 두지 않는다');
      // 다음 실행에서 또 시도하지 않도록 정리됐다.
      expect(await db.getSetting('open_projects'), [a]);
    });

    /// ★ 회귀 방지. `main.dart` 는 `init()` 을 기다리지 않으므로 첫 프레임이
    /// 설정 로드보다 먼저 온다. 그때 복원이 목록을 소비해 버리면 기회를 영영
    /// 잃는다 — 앱을 켜면 프로젝트가 하나도 안 열려 있던 원인이 이것이었다.
    test('초기화 전에 불려도 복원 기회를 잃지 않는다', () async {
      final a = await makeProject('a');
      await db.setSetting('open_projects', [a]);

      final next = WorkspaceController();
      addTearDown(() async {
        next.dispose();
        await pumpEventQueue();
      });

      // 화면이 먼저 뜬 상황 — 아직 설정이 안 들어왔다.
      await next.restoreOpenProjects();
      expect(next.sessions, isEmpty);

      // 초기화가 끝나 목록이 들어온 뒤 다시 부르면 그때 열린다.
      await next.loadOpenProjectsForTest(db);
      await next.restoreOpenProjects();
      expect(next.sessions.map((s) => s.path), [a]);
    });

    test('복원할 것이 없으면 아무것도 열지 않는다', () async {
      final next = await relaunch();
      expect(next.sessions, isEmpty);
      expect(next.hasProject, isFalse);
    });

    test('복원은 한 번만 한다', () async {
      final a = await makeProject('a');
      await db.setSetting('open_projects', [a]);

      final next = await relaunch();
      await next.closeProject(a);
      await next.restoreOpenProjects(); // 두 번째 호출

      expect(next.sessions, isEmpty, reason: '닫은 것을 다시 열어 버리면 안 된다');
    });
  });

  test('close 를 두 번 불러도 안전하다', () async {
    final a = await makeProject('a');
    await wc.openProject(a);
    final s = wc.sessionFor(a)!;

    await s.close();
    await s.close();

    expect(s.bridge, isNull);
  });
}
