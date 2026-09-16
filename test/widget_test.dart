// 좌측 네비게이션 메뉴 위젯 테스트.
// (전체 AppLayout 은 path_provider/webview 플러그인에 의존하므로 단위 위젯만 검증.)

import 'dart:io';

import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/ui/left_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Row(children: [child])),
    );

void main() {
  setUpAll(initSqliteFfi);

  /// 실제 세션을 만든다 — 좌측 메뉴는 열린 프로젝트만 그리므로 가짜로 대신할 수 없다.
  Future<List<ProjectSession>> openSessions(List<String> names) async {
    final tmp = await Directory.systemTemp.createTemp('collabo_nav_');
    final browser = BrowserController();
    final out = <ProjectSession>[];
    for (final name in names) {
      final dir = Directory(p.join(tmp.path, name));
      await dir.create(recursive: true);
      out.add(await ProjectSession.open(dir.path,
          browser: browser, firstConversationTitle: 'test'));
    }
    addTearDown(() async {
      for (final s in out) {
        await s.close();
      }
      browser.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    return out;
  }

  testWidgets('좌측 메뉴에 새 프로젝트/프로젝트 열기/설정 항목이 있다', (tester) async {
    await tester.pumpWidget(_host(
      LeftNav(onNewProject: () {}, onOpenProject: () {}, onOpenSettings: () {}),
    ));

    expect(find.byIcon(Icons.create_new_folder), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('열린 프로젝트가 표시되고 누르면 그 경로로 콜백이 온다', (tester) async {
    final sessions = await openSessions(['alpha', 'beta']);
    String? selected;
    await tester.pumpWidget(_host(
      LeftNav(
        onNewProject: () {},
        onOpenProject: () {},
        onOpenSettings: () {},
        openProjects: sessions,
        activeProject: sessions.first.path,
        onSelectProject: (path) => selected = path,
      ),
    ));

    // 폴더명 첫 글자 모노그램으로 표시된다(alpha→A, beta→B).
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);

    await tester.tap(find.text('B'));
    expect(selected, sessions[1].path);
  });

  testWidgets('닫기 버튼은 그 세션을 그대로 넘긴다', (tester) async {
    final sessions = await openSessions(['alpha', 'beta']);
    ProjectSession? closed;
    await tester.pumpWidget(_host(
      LeftNav(
        onNewProject: () {},
        onOpenProject: () {},
        onOpenSettings: () {},
        openProjects: sessions,
        activeProject: sessions.first.path,
        onCloseProject: (s) => closed = s,
      ),
    ));

    // 접힌 상태에서도 닫기 버튼은 보인다(라벨만 숨는다).
    await tester.tap(find.byIcon(Icons.close).first);
    expect(closed, isNotNull);
    expect(closed!.path, sessions.first.path);
  });

  /// ★ 좌측 메뉴에는 **열린 것만** 나온다. 최근(MRU) 목록을 여기 두면 닫은
  /// 프로젝트가 아래 줄로 내려간 것처럼 보여, 열린 것과 구분할 수 없다.
  testWidgets('열린 프로젝트가 없으면 목록도 비어 있다', (tester) async {
    await tester.pumpWidget(_host(
      LeftNav(onNewProject: () {}, onOpenProject: () {}, onOpenSettings: () {}),
    ));

    expect(find.byType(ProjectMonogram), findsNothing);
  });

  testWidgets('실행 중 프로세스가 있으면 sync 아이콘과 개수가 보인다', (tester) async {
    await tester.pumpWidget(_host(
      LeftNav(
        onNewProject: () {},
        onOpenProject: () {},
        onOpenSettings: () {},
        runningProcessCount: 3,
      ),
    ));

    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  /// 설정 위 항목은 전부 화면 토글이다 — 진행 상태도 이제 모달이 아니다.
  testWidgets('진행 상태와 웹 검색은 화면 토글로 동작한다', (tester) async {
    var processes = 0;
    var browser = 0;
    await tester.pumpWidget(_host(
      LeftNav(
        onNewProject: () {},
        onOpenProject: () {},
        onOpenSettings: () {},
        onToggleProcesses: () => processes++,
        onToggleBrowser: () => browser++,
      ),
    ));

    await tester.tap(find.byIcon(Icons.sync_disabled));
    await tester.tap(find.byIcon(Icons.travel_explore));
    expect(processes, 1);
    expect(browser, 1);
  });

  test('폴더 이름은 구분자를 가리지 않는다', () {
    expect(projectBasename(r'C:\work\alpha'), 'alpha');
    expect(projectBasename('/home/me/beta/'), 'beta');
    expect(projectBasename('solo'), 'solo');
  });
}
