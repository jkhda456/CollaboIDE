import 'dart:io';

import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/files/file_viewer.dart';
import 'package:collabo_ide/src/ui/file_tree_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 네이티브 트리 화면 — 예전 웹 트리(index.html)가 하던 일을 그대로 하는지.
void main() {
  setUpAll(initSqliteFfi);

  late Directory tmp;
  late ProjectSession session;

  Widget app() => MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SizedBox(width: 360, height: 600, child: FileTreeView(session: session))),
      );

  /// 파일 IO 는 위젯 시험의 가짜 시계에서 저절로 안 끝난다 — 실제 시간을 조금 흘려 완료
  /// 신호가 들어오게 하고(runAsync), pump 로 그 뒤의 마이크로태스크를 돌린다. 디렉토리
  /// 목록처럼 한 동작이 여러 단계의 IO 로 이어지므로 여러 번 돈다.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump();
    }
  }

  Future<void> openProject(WidgetTester tester) async {
    tmp = Directory.systemTemp.createTempSync('collabo-tree-');
    Directory(p.join(tmp.path, 'src')).createSync();
    File(p.join(tmp.path, 'src', 'main.dart')).writeAsStringSync('void main() {}');
    File(p.join(tmp.path, 'README.md')).writeAsStringSync('# hi');
    session = (await tester.runAsync(() => ProjectSession.open(tmp.path,
        browser: BrowserController(), firstConversationTitle: 't')))!;
    session.viewer = FileViewerController(WorkspaceController(), session.files,
        viewerStager: (_) async => const []);
    await tester.pumpWidget(app());
    await settle(tester);
  }

  Future<void> closeProject(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => session.close());
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  Future<void> rightClick(WidgetTester tester, Finder f) async {
    await tester.tap(f, buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
  }

  testWidgets('펼치기 · 파일 열기', (tester) async {
    await openProject(tester);
    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('main.dart'), findsNothing);

    await tester.tap(find.text('src'));
    await settle(tester);
    expect(find.text('main.dart'), findsOneWidget, reason: '폴더를 누르면 펼쳐진다');

    await tester.tap(find.text('README.md'));
    await tester.pump();
    expect(session.viewer!.path, p.join(tmp.path, 'README.md'), reason: '파일을 누르면 뷰어로 연다');
    expect(session.files.selected, p.join(tmp.path, 'README.md'));
    await closeProject(tester);
  });

  testWidgets('우클릭 → 새 파일 (이름 규칙은 입력 즉시 막는다)', (tester) async {
    await openProject(tester);
    await rightClick(tester, find.text('src'));
    expect(find.text('새 파일'), findsOneWidget);
    expect(find.text('이름 변경'), findsOneWidget);
    await tester.tap(find.text('새 파일'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a/b');
    await tester.pump();
    expect(find.textContaining('사용할 수 없는 문자'), findsOneWidget);
    final create = find.widgetWithText(FilledButton, '생성');
    expect(tester.widget<FilledButton>(create).onPressed, isNull, reason: '잘못된 이름이면 만들 수 없다');

    await tester.enterText(find.byType(TextField), 'util.dart');
    await tester.pump();
    await tester.tap(create);
    await tester.pumpAndSettle();
    await settle(tester);
    expect(File(p.join(tmp.path, 'src', 'util.dart')).existsSync(), isTrue);
    expect(find.text('util.dart'), findsOneWidget, reason: '만든 자리(src)가 펼쳐져 보인다');
    expect(session.viewer!.path, p.join(tmp.path, 'src', 'util.dart'), reason: '만든 파일은 바로 연다');
    await closeProject(tester);
  });

  testWidgets('이름 변경 · 삭제(확인을 받는다)', (tester) async {
    await openProject(tester);
    await rightClick(tester, find.text('README.md'));
    await tester.tap(find.text('이름 변경'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'GUIDE.md');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '이름 변경'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('GUIDE.md'), findsOneWidget);
    expect(File(p.join(tmp.path, 'README.md')).existsSync(), isFalse);

    await rightClick(tester, find.text('GUIDE.md'));
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('되돌릴 수 없습니다'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '삭제'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(File(p.join(tmp.path, 'GUIDE.md')).existsSync(), isFalse);
    expect(find.text('GUIDE.md'), findsNothing);
    await closeProject(tester);
  });

  testWidgets('빈 영역 우클릭은 루트 대상 — 만들기만 있다', (tester) async {
    await openProject(tester);
    await tester.tapAt(tester.getBottomLeft(find.byType(FileTreeView)) + const Offset(40, -40),
        buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('새 폴더'), findsOneWidget);
    expect(find.text('이름 변경'), findsNothing);
    await closeProject(tester);
  });

  testWidgets('파일명 검색', (tester) async {
    await openProject(tester);
    await tester.tap(find.byTooltip('파일 이름 검색'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'main');
    await tester.pump(const Duration(milliseconds: 300)); // 입력 디바운스
    await settle(tester);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('src'), findsOneWidget, reason: '결과 아래에 폴더 경로가 보인다');
    await tester.tap(find.byTooltip('취소'));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsOneWidget, reason: '검색을 닫으면 트리로 돌아간다');
    await closeProject(tester);
  });

  testWidgets('실패 이유는 스낵바로 보인다', (tester) async {
    await openProject(tester);
    await tester.runAsync(() => session.files.delete(tmp.path)); // 루트는 못 지운다
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    await closeProject(tester);
  });
}
