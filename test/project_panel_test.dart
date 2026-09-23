import 'dart:async';
import 'dart:io';

import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/project_session.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/files/file_viewer.dart';
import 'package:collabo_ide/src/ui/file_tree_view.dart';
import 'package:collabo_ide/src/ui/file_viewer_frame.dart';
import 'package:collabo_ide/src/ui/project_panel.dart';
import 'package:collabo_ide/src/webview/platform_web_view.dart';
import 'package:collabo_ide/src/webview/web_view_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 만든 횟수를 세는 가짜 웹뷰(위젯 시험에서는 WebView2 를 못 띄운다).
class _CountingWebView implements PlatformWebView {
  static int created = 0;
  _CountingWebView() {
    created++;
  }
  @override
  Future<void> initialize() async {}
  @override
  Stream<dynamic> get messages => const Stream.empty();
  @override
  Stream<void> get pageFinished => const Stream.empty();
  @override
  Future<void> loadUrl(String url) async {}
  @override
  Future<void> postMessage(String json) async {}
  @override
  Future<void> executeScript(String script) async {}
  @override
  Widget buildView() => const ColoredBox(color: Colors.black12);
  @override
  bool get needsWheelWorkaround => false;
  @override
  Future<void> dispose() async {}
}

/// 우측 패널 배치 — 트리 / 뷰어 / 폭·높이 / 숨기기 / 전체화면.
///
/// 핵심은 **뷰어 웹뷰를 다시 만들지 않는 것**이다: 전체화면이나 숨기기로 다시 만들어지면
/// 페이지가 새로 떠서 보던 파일을 처음부터 다시 그린다(스크롤·편집 초안이 날아간다).
void main() {
  setUpAll(initSqliteFfi);

  late Directory tmp;
  late ProjectSession session;

  setUp(() {
    _CountingWebView.created = 0;
    debugWebViewFactory = _CountingWebView.new;
  });
  tearDown(() => debugWebViewFactory = null);

  Future<void> open(WidgetTester tester, {double width = 1200}) async {
    tmp = Directory.systemTemp.createTempSync('collabo-panel-');
    File('${tmp.path}/a.md').writeAsStringSync('# a');
    session = (await tester.runAsync(() => ProjectSession.open(tmp.path,
        browser: BrowserController(), firstConversationTitle: 't')))!;
    session.viewer = FileViewerController(WorkspaceController(), session.files,
        viewerStager: (_) async => const []);
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ProjectPanel(session: session, themeMode: ThemeMode.light, langCode: 'ko'),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => session.close());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }

  testWidgets('대화 + 우측(트리 위, 뷰어 아래) — 웹뷰는 대화 하나, 뷰어 하나', (tester) async {
    await open(tester);
    expect(find.byType(FileTreeView), findsOneWidget);
    expect(find.byType(FileViewerFrame), findsOneWidget);
    expect(_CountingWebView.created, 2);
    final tree = tester.getRect(find.byType(FileTreeView));
    final frame = tester.getRect(find.byType(FileViewerFrame));
    expect(tree.bottom, lessThanOrEqualTo(frame.top), reason: '트리가 위, 뷰어가 아래');
    expect(frame.width, closeTo(360, 1), reason: '기본 폭');
    await close(tester);
  });

  testWidgets('전체화면: 뷰어가 패널 전체를 덮고, 트리는 빠지고, 웹뷰는 그대로다', (tester) async {
    await open(tester);
    session.viewer!.setFullscreen(true);
    await tester.pump();
    expect(find.byType(FileTreeView), findsNothing);
    expect(tester.getRect(find.byType(FileViewerFrame)).width, closeTo(1200, 1));
    session.viewer!.setFullscreen(false);
    await tester.pump();
    expect(find.byType(FileTreeView), findsOneWidget);
    expect(_CountingWebView.created, 2, reason: '뷰어 웹뷰를 다시 만들면 보던 파일이 처음부터 다시 그려진다');
    await close(tester);
  });

  testWidgets('숨기기: 대화가 넓어지고, 다시 보여도 뷰어 웹뷰는 그대로다', (tester) async {
    await open(tester);
    session.toggleSidePanel();
    await tester.pump();
    expect(find.byType(FileTreeView, skipOffstage: true), findsNothing);
    session.toggleSidePanel();
    await tester.pump();
    expect(find.byType(FileTreeView), findsOneWidget);
    expect(_CountingWebView.created, 2);
    await close(tester);
  });

  testWidgets('폭 조절선을 끌면 우측이 넓어진다(대화 최소 폭은 지킨다)', (tester) async {
    await open(tester);
    final before = tester.getRect(find.byType(FileViewerFrame)).width;
    final splitterX = tester.getRect(find.byType(FileViewerFrame)).left - 3;
    await tester.dragFrom(Offset(splitterX, 400), const Offset(-100, 0));
    await tester.pump();
    // 끌기 판정 여유(slop)만큼은 빠진다.
    expect(tester.getRect(find.byType(FileViewerFrame)).width, greaterThan(before + 60));
    await tester.dragFrom(Offset(splitterX - 100, 400), const Offset(-2000, 0));
    await tester.pump();
    expect(tester.getRect(find.byType(FileViewerFrame)).width, lessThanOrEqualTo(1200 - 320 - 6 + 1));
    await close(tester);
  });

  testWidgets('뷰어 틀 — 파일이 없으면 안내, 열면 파일명과 뷰어 후보', (tester) async {
    await open(tester);
    expect(find.text('선택한 파일이 없습니다'), findsOneWidget);
    session.openInViewer('${tmp.path}${Platform.pathSeparator}a.md');
    await tester.pump();
    expect(find.text('a.md'), findsWidgets);
    await close(tester);
  });

  testWidgets('좁은 화면: 우측은 접힌 채 시작하고, 열면 대화 위를 덮는다(대화 폭은 그대로)', (tester) async {
    await open(tester, width: 400);
    await tester.pump(); // 덮기로 바뀐 뒤 접기(post-frame)
    expect(session.sidePanelVisible.value, isFalse, reason: '휴대폰에서 대화를 가리고 시작하지 않는다');
    final chatWidth = tester.getRect(find.byType(WebViewPanel)).width;
    expect(chatWidth, 400);

    session.openInViewer('${tmp.path}/a.md');
    await tester.pump();
    final side = tester.getRect(find.byType(FileTreeView));
    expect(side.right, 400);
    expect(side.left, greaterThan(0), reason: '왼쪽에 눌러서 닫을 띠가 남는다');
    expect(tester.getRect(find.byType(WebViewPanel)).width, chatWidth, reason: '덮을 뿐 대화 폭은 바뀌지 않는다');
    expect(_CountingWebView.created, 2, reason: '웹뷰를 새로 만들지 않는다');

    // 바깥(어두운 띠)을 누르면 접힌다.
    await tester.tapAt(const Offset(10, 400));
    await tester.pump();
    expect(session.sidePanelVisible.value, isFalse);

    // 다시 열고 트리 머리의 닫기로 접는다.
    session.sidePanelVisible.value = true;
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(FileTreeView), matching: find.byIcon(Icons.close)));
    await tester.pump();
    expect(session.sidePanelVisible.value, isFalse);
    expect(_CountingWebView.created, 2);
    await close(tester);
  });

  testWidgets('좁은 화면: 덮는 패널의 왼쪽 가장자리를 끌어 폭을 바꾼다', (tester) async {
    await open(tester, width: 500);
    await tester.pump();
    session.sidePanelVisible.value = true;
    await tester.pump();
    final before = tester.getRect(find.byType(FileTreeView));
    await tester.dragFrom(Offset(before.left - 3, 400), const Offset(80, 0));
    await tester.pump();
    expect(tester.getRect(find.byType(FileTreeView)).width, lessThan(before.width - 40));
    await close(tester);
  });

  testWidgets('넓어지면 다시 나란히 — 좁을 때 접은 상태는 그대로 둔다', (tester) async {
    await open(tester, width: 400);
    await tester.pump();
    expect(session.sidePanelVisible.value, isFalse);
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    session.sidePanelVisible.value = true;
    await tester.pump();
    expect(tester.getRect(find.byType(WebViewPanel)).right, lessThan(1200 - 200));
    await close(tester);
  });
}
