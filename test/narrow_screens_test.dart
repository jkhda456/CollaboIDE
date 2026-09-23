// 휴대폰 폭(320·390)에서 주요 화면이 넘치지 않는다.
import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/ui/left_nav.dart';
import 'package:collabo_ide/src/ui/new_project_dialog.dart';
import 'package:collabo_ide/src/ui/process_panel.dart';
import 'package:collabo_ide/src/ui/sandbox_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget home) => MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: home),
    );

void main() {
  setUpAll(initSqliteFfi);
  Future<void> at(WidgetTester t, double w) async {
    t.view.physicalSize = Size(w, 800);
    t.view.devicePixelRatio = 1;
  }

  for (final w in [320.0, 390.0]) {
    testWidgets('진행 상태 화면: 폭 $w', (t) async {
      await at(t, w); addTearDown(t.view.reset);
      await t.pumpWidget(_app(ProcessPanel(workspace: WorkspaceController(), visible: true)));
      await t.pump();
      expect(t.takeException(), isNull);
    });
    testWidgets('샌드박스 화면: 폭 $w', (t) async {
      await at(t, w); addTearDown(t.view.reset);
      await t.pumpWidget(_app(SandboxPanel(workspace: WorkspaceController(), visible: true)));
      await t.pump();
      expect(t.takeException(), isNull);
    });
    testWidgets('좌측 메뉴 펼침: 폭 $w', (t) async {
      await at(t, w); addTearDown(t.view.reset);
      final ex = ValueNotifier(true);
      await t.pumpWidget(_app(Row(children: [LeftNav(onNewProject: () {}, onOpenProject: () {}, onOpenSettings: () {}, expanded: ex, collapseAfterTap: true)])));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
    testWidgets('새 프로젝트 대화상자: 폭 $w', (t) async {
      await at(t, w); addTearDown(t.view.reset);
      await t.pumpWidget(_app(Builder(builder: (c) => TextButton(onPressed: () => showNewProjectDialog(c, initialDir: '/tmp'), child: const Text('go')))));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  }
}
