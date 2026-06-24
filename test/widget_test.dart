// 좌측 네비게이션 메뉴 위젯 테스트.
// (전체 AppLayout 은 path_provider/webview 플러그인에 의존하므로 단위 위젯만 검증.)

import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/ui/left_nav.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Row(children: [child])),
    );

void main() {
  testWidgets('좌측 메뉴에 새 프로젝트/프로젝트 열기/설정 항목이 있다', (tester) async {
    await tester.pumpWidget(_host(
      LeftNav(onNewProject: () {}, onOpenProject: () {}, onOpenSettings: () {}),
    ));

    expect(find.byIcon(Icons.create_new_folder), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
  });

  testWidgets('최근 프로젝트가 표시되고 클릭 시 콜백이 호출된다', (tester) async {
    String? opened;
    await tester.pumpWidget(_host(
      LeftNav(
        onNewProject: () {},
        onOpenProject: () {},
        onOpenSettings: () {},
        recentProjects: const [r'C:\work\alpha', r'C:\work\beta'],
        onOpenRecent: (p) => opened = p,
      ),
    ));

    // 최근 프로젝트는 폴더명 첫 글자 모노그램으로 표시된다(alpha→A, beta→B).
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);

    await tester.tap(find.text('A'));
    expect(opened, r'C:\work\alpha');
  });

  testWidgets('실행 중 프로세스가 있으면 sync 아이콘으로 표시된다', (tester) async {
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
}
