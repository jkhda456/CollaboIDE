// 샌드박스 화면: 떠 있는 머신의 root 셸 터미널에 실제로 키를 치고 답을 본다.
// 런타임이 필요하다(COLLABO_CORE_RUNTIME, 없으면 리포의 collabo_core_runtime/).
import 'dart:io';

import 'package:collabo_core/collabo_core.dart';
import 'package:collabo_ide/l10n/app_localizations.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/sandbox/project_sandbox.dart';
import 'package:collabo_ide/src/ui/sandbox_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xterm/xterm.dart' show TerminalView;

CollaboRuntime? _runtime() {
  try {
    return CollaboRuntime.locate(
        directory: Platform.environment['COLLABO_CORE_RUNTIME'] ??
            Directory('collabo_core_runtime').absolute.path);
  } catch (_) {
    return null;
  }
}

Widget _app(WorkspaceController wc) => MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SandboxPanel(workspace: wc)),
    );

void main() {
  setUpAll(initSqliteFfi);

  testWidgets('런타임이 없으면 도구를 쓸 수 없다고 알린다', (tester) async {
    // 런타임을 못 찾은 상태(debugUseSandbox 를 부르지 않았다) — 만들 머신이 없다.
    final wc = WorkspaceController();
    await tester.pumpWidget(_app(wc));
    expect(find.textContaining('샌드박스 런타임이 앱에 들어 있지 않습니다'), findsOneWidget);
    expect(find.textContaining('열린 프로젝트가 없습니다'), findsOneWidget);
  });

  final runtime = _runtime();

  testWidgets('샌드박스 모드면 프로젝트가 없어도 시스템 머신이 목록 맨 위에 있다', (tester) async {
    final tools = Directory('assets/python').absolute.path;
    final wc = WorkspaceController()
      ..debugUseSandbox(runtime: runtime!, baseModules: [p.join(tools, 'collabo_tools.py')]);
    await tester.pumpWidget(_app(wc));
    await tester.pump();

    // 앱에 하나 고정 — 프로젝트 머신을 대신 켜지 않는다(설정 창이 그랬다).
    expect(find.text('시스템 샌드박스'), findsWidgets);
    expect(find.textContaining('열린 프로젝트가 없습니다'), findsNothing);
    expect(find.textContaining('프로젝트에 속하지 않는 도구 작업'), findsOneWidget,
        reason: '고른 것이 없으면 시스템 머신을 보여 준다');
    expect(wc.systemSandboxRunning, isFalse, reason: '화면을 여는 것만으로 부팅하지는 않는다');

    await tester.runAsync(() => wc.stopSystemSandbox());
    wc.dispose();
  }, skip: runtime == null); // collabo_core_runtime 없음

  testWidgets('떠 있는 머신의 root 셸에 명령을 보내고 답을 본다', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('collabo-sbxpanel-');
    File(p.join(tmp.path, 'marker.txt')).writeAsStringSync('hi');
    final tools = Directory('assets/python').absolute.path;
    final wc = WorkspaceController()
      ..debugUseSandbox(runtime: runtime!, baseModules: [p.join(tools, 'collabo_tools.py')]);
    await tester.runAsync(() => wc.openProject(tmp.path));
    final session = wc.sessions.single;

    await tester.pumpWidget(_app(wc));
    await tester.pump();
    // 화면을 연 것만으로 머신 자리가 생기고, 아직 부팅은 안 했다.
    final box = session.sandbox!;
    expect(box.state, SandboxState.idle);
    expect(find.text('시작'), findsOneWidget);
    expect(find.textContaining('/work  ←'), findsOneWidget);

    // 프로세스 I/O 는 위젯 시험의 가짜 시계에서 안 돈다 — 부팅은 실제 시간에서.
    await tester.runAsync(() => box.start());
    await tester.pump();
    expect(box.isRunning, isTrue);
    expect(find.text('다시 시작'), findsOneWidget);

    Future<void> waitFor(bool Function() ok, String what) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(ok(), isTrue, reason: 'timed out: $what\n---\n${box.console.text}');
    }

    // 진짜 터미널이다 — 입력창이 따로 없고, 터미널에 초점을 두고 치면 셸이 받는다.
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    tester.testTextInput.enterText(r'cat /work/marker.txt; echo; echo sbx-$((6*7))');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(() => RegExp(r'^sbx-42\s*$', multiLine: true).hasMatch(box.console.text),
        'the shell to answer');
    expect(RegExp(r'^hi\s*$', multiLine: true).hasMatch(box.console.text), isTrue);
    // 입력한 줄도 **같은 화면에** 셸의 에코로 찍혀 있다(입력과 출력이 한 흐름).
    expect(box.console.text, contains(r'echo sbx-$((6*7))'));

    // 화면 크기가 머신 콘솔 크기로 갔다 — 셸이 아는 열 수가 화면과 같다.
    final cols = box.console.size!.$1;
    await tester.tap(find.byType(TerminalView));
    tester.testTextInput.enterText('stty size');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(() => RegExp('^\\d+ $cols\\s*\$', multiLine: true).hasMatch(box.console.text),
        'stty to report the terminal size');

    Future<void> ctrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    Future<void> typeLine(String text) async {
      tester.testTextInput.enterText(text);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    }

    // ★ Ctrl-C 가 **도는 명령을 끊는다**(셸에 제어 터미널이 있어야 SIGINT 가 간다).
    await typeLine('sleep 30');
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    final sw = Stopwatch()..start();
    await ctrl(LogicalKeyboardKey.keyC);
    await typeLine('echo after-ctrl-c');
    await waitFor(() => RegExp(r'^after-ctrl-c\s*$', multiLine: true).hasMatch(box.console.text),
        'Ctrl-C to interrupt sleep');
    expect(sw.elapsed, lessThan(const Duration(seconds: 15)), reason: 'sleep 30 을 끝까지 기다렸다');

    // Ctrl-A 는 셸의 것(줄 처음으로) — 전체 선택 단축키가 가로채면 안 된다.
    // "echo ctrl-a-leaked" 를 치고 줄 처음에 # 을 넣으면 주석이 되어 아무것도 안 찍힌다.
    tester.testTextInput.enterText('echo ctrl-a-leaked');
    await tester.pump();
    await ctrl(LogicalKeyboardKey.keyA);
    await typeLine('#');
    await typeLine('echo mark-after-comment');
    await waitFor(() => RegExp(r'^mark-after-comment\s*$', multiLine: true).hasMatch(box.console.text),
        'the shell to come back');
    expect(RegExp(r'^ctrl-a-leaked\s*$', multiLine: true).hasMatch(box.console.text), isFalse,
        reason: 'Ctrl-A 가 셸에 안 가서 # 이 줄 끝에 붙었다');

    // 중지는 물어본다(그 안의 명령·터미널이 같이 끝나므로). 취소하면 그대로.
    await tester.tap(find.text('중지'));
    await tester.pumpAndSettle();
    expect(find.text('샌드박스 중지'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(box.isRunning, isTrue);

    await tester.runAsync(() => box.stop());
    await tester.pump();
    expect(box.state, SandboxState.idle);
    expect(box.console.text, contains('── stopped'));

    await tester.runAsync(() => wc.closeProject(tmp.path));
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  }, skip: runtime == null, timeout: const Timeout(Duration(minutes: 3)));
}
