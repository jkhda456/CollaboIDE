// 좁은 화면(휴대폰)에서 설정 대화상자 — 전체화면이 되고 어느 탭도 넘치지 않는다.
import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/ui/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(initSqliteFfi);
  for (final w in [390.0, 700.0]) {
    testWidgets('설정 대화상자: 폭 $w 에서 모든 탭이 넘치지 않는다', (tester) async {
      tester.view.physicalSize = Size(w, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final wc = WorkspaceController();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => showSettingsDialog(c, wc), child: const Text('open'))))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final errors = <String>[];
      for (final tab in ['모델', '프롬프트', '도구', '뷰어', '웹 검색', '모양', '정보']) {
        final f = find.widgetWithText(Tab, tab);
        if (f.evaluate().isEmpty) { errors.add('no tab $tab'); continue; }
        await tester.tap(f.first);
        for (var i = 0; i < 10; i++) { await tester.pump(const Duration(milliseconds: 50)); }
        final e = tester.takeException();
        if (e != null) errors.add('$tab: ${e.toString().split('\n').first}');
      }
      expect(errors, isEmpty);
    });
  }
}
