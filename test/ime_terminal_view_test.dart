import 'package:collabo_ide/src/ui/ime_terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 한글 조합 입력이 **쪼개지지 않고** 확정 글자만 터미널로 가는지.
///
/// 엔진이 보내는 입력 상태(updateEditingValue)를 macOS 한글 IME 의 실제 순서대로 흉내 낸다.
/// 핵심은 "한" 확정과 "ㄱ" 조합 시작이 **같은 키에서** 온다는 것 — 그 사이에 입력 상태를
/// 비우면(xterm 기본 입력기) macOS 는 조합을 버린다(discardMarkedText).
void main() {
  late Terminal terminal;
  late StringBuffer out;
  late FocusNode focus;

  Future<void> pumpView(WidgetTester tester, {bool readOnly = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 300,
          child: ImeTerminalView(
            terminal,
            focusNode: focus,
            autofocus: true,
            theme: TerminalThemes.defaultTheme,
            readOnly: readOnly,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  setUp(() {
    out = StringBuffer();
    terminal = Terminal(onOutput: out.write);
    focus = FocusNode();
  });
  tearDown(() => focus.dispose());

  TextEditingValue composing(String text, int start) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: start, end: text.length),
      );
  TextEditingValue committed(String text) =>
      TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));

  List<Map<String, dynamic>> setStates(WidgetTester tester) => [
        for (final c in tester.testTextInput.log)
          if (c.method == 'TextInput.setEditingState') (c.arguments as Map).cast<String, dynamic>(),
      ];

  testWidgets('macOS 순서의 "한글" — 쪼개지지 않고, 조합 중엔 입력 상태를 건드리지 않는다', (tester) async {
    await pumpView(tester);
    expect(tester.testTextInput.isVisible, isTrue, reason: '초점을 받으면 입력 연결이 붙는다');
    tester.testTextInput.log.clear();

    final ti = tester.testTextInput;
    ti.updateEditingValue(composing('ㅎ', 0));
    ti.updateEditingValue(composing('하', 0));
    ti.updateEditingValue(composing('한', 0));
    await tester.pump();
    expect(out.toString(), '', reason: '조합 중엔 아무것도 안 보낸다');
    expect(find.byKey(const ValueKey('ime-composing')), findsOneWidget, reason: '조합 글자는 따로 그린다');

    // ㄱ 키: IME 가 "한" 을 확정하고(insertText) 같은 키에서 "ㄱ" 조합을 시작한다(setMarkedText).
    ti.updateEditingValue(committed('한'));
    ti.updateEditingValue(composing('한ㄱ', 1));
    ti.updateEditingValue(composing('한그', 1));
    ti.updateEditingValue(composing('한글', 1));
    expect(out.toString(), '한', reason: '확정된 "한" 만 먼저 간다');
    ti.updateEditingValue(committed('한글'));
    await tester.pump();

    expect(out.toString(), '한', reason: '끝 한글 한 글자는 다음 글자나 터미널 키가 올 때까지 잡아 둔다');
    expect(setStates(tester), isEmpty,
        reason: '조합이 이어지는 동안 입력 상태를 되돌리면 macOS 가 조합을 버린다');
    expect(tester.widget<Text>(find.byKey(const ValueKey('ime-composing'))).data, '글',
        reason: '잡아 둔 글자는 커서 자리에 보인다');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(out.toString(), '한글\r', reason: '두 번 가거나 자모로 쪼개지면 안 된다 — Enter 앞에 잡은 글자부터');
    expect(find.byKey(const ValueKey('ime-composing')), findsNothing);
  });

  testWidgets('표시(marked) 없이 넣고 바꿔 치우는 IME — 초성이 먼저 가지 않는다(cat 에서 본 것)', (tester) async {
    await pumpView(tester);
    final ti = tester.testTextInput;
    // 조합 구간 없이 "확정" 처럼 오다가 다음 키에서 끝 글자가 바뀐다.
    for (final s in ['ㅎ', '하', '한', '한ㄱ', '한그', '한글']) {
      ti.updateEditingValue(committed(s));
    }
    await tester.pump();
    expect(out.toString(), '한', reason: '자모("ㅎ")나 지우기(DEL)가 가면 커널 줄 규칙(cat)에서 깨진다');

    // 잡아 둔 끝 글자를 Backspace 로 고치면 IME 몫 — 터미널엔 아무것도 안 간다.
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    ti.updateEditingValue(committed('한그'));
    expect(out.toString(), '한');

    // 한글 뒤에 다른 글자가 오면 앞 글자는 확정이다.
    ti.updateEditingValue(committed('한그 a'));
    expect(out.toString(), '한그 a');
    expect(out.toString(), isNot(contains('\x7f')));
  });

  testWidgets('Enter(터미널 키)는 xterm 이 보내고, 그때 입력 상태를 비운다', (tester) async {
    await pumpView(tester);
    tester.testTextInput.updateEditingValue(committed('ls'));
    tester.testTextInput.log.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(out.toString(), 'ls\r');
    final states = setStates(tester);
    expect(states, isNotEmpty);
    expect(states.last['text'], '', reason: '다음 입력은 빈 상태에서 시작한다');

    // 비운 뒤의 입력도 차이만 간다.
    tester.testTextInput.updateEditingValue(committed('a'));
    expect(out.toString(), 'ls\ra');
  });

  testWidgets('조합 중 Backspace 는 IME 몫 — 조합을 지우면 터미널엔 아무것도 안 간다', (tester) async {
    await pumpView(tester);
    final ti = tester.testTextInput;
    ti.updateEditingValue(composing('한', 0));
    await tester.pump();
    ti.log.clear();

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(out.toString(), '', reason: '조합 중 키는 xterm 이 보내지 않는다');
    ti.updateEditingValue(composing('하', 0));
    ti.updateEditingValue(committed(''));
    await tester.pump();

    expect(out.toString(), '');
    expect(setStates(tester), isEmpty);
  });

  testWidgets('글자 키는 IME 로 넘긴다(두 번 가지 않게) · Ctrl 조합은 터미널로', (tester) async {
    await pumpView(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a');
    expect(out.toString(), '', reason: '영문도 IME 의 확정 글자로 온다 — 키 이벤트로 또 보내면 "aa"');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(out.toString(), '\x03', reason: 'Ctrl+C 는 xterm 이 ETX 로');
  });

  testWidgets('macOS: 조합 중 Enter → 확정 뒤 줄바꿈 동작(performAction) 하나로 끝난다', (tester) async {
    await pumpView(tester);
    final ti = tester.testTextInput;
    ti.updateEditingValue(composing('한', 0));
    ti.updateEditingValue(committed('한'));
    await ti.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(out.toString(), '한\r');
  });

  testWidgets('IME 가 확정 글자를 고치면 그만큼 지우고 다시 보낸다', (tester) async {
    await pumpView(tester);
    final ti = tester.testTextInput;
    ti.updateEditingValue(committed('ab'));
    ti.updateEditingValue(committed('ac'));
    expect(out.toString(), 'ab\x7fc');
  });

  testWidgets('읽기 전용이면 입력 연결을 붙이지 않는다', (tester) async {
    await pumpView(tester, readOnly: true);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  });
}
