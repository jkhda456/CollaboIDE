// 샌드박스 터미널 모델(xterm.dart Terminal)과 머신 사이의 배선.
// 출력: 원시 바이트 → 에뮬레이터(이스케이프 처리). 입력: 키 → 바이트열 → 머신. 크기 → 머신.
import 'dart:convert';

import 'package:collabo_ide/src/sandbox/sandbox_console.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// 버퍼의 줄(오른쪽 공백 제거, 끝의 빈 줄 제거).
List<String> _lines(SandboxConsole c) {
  final lines = c.text.split('\n').map((l) => l.trimRight()).toList();
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

SandboxConsole _feed(List<Object> chunks) {
  final c = SandboxConsole();
  for (final ch in chunks) {
    c.addBytes(ch is String ? utf8.encode(ch) : ch as List<int>);
  }
  return c;
}

void main() {
  group('출력 — 이스케이프는 에뮬레이터가 처리한다', () {
    test('CRLF 는 줄바꿈', () {
      expect(_lines(_feed(['abc\r\ndef'])), ['abc', 'def']);
    });

    test('색·지우기 제어열은 글자로 남지 않는다', () {
      expect(_lines(_feed(['\x1b[1;32mroot@collabo\x1b[0m:~# \x1b[K'])), ['root@collabo:~#']);
    });

    test('CR 로 줄 처음에 돌아가 덮어쓴다 (진행 표시)', () {
      expect(_lines(_feed(['progress 10%\rprogress 50%\r\n'])), ['progress 50%']);
    });

    test('커서 이동으로 고쳐 쓴 것이 반영된다 (라인 편집기)', () {
      // "echo hlo" 를 치다가 ← 두 번, 'e' 삽입 → 셸의 라인 편집기가 보내는 흐름과 같은 모양.
      expect(_lines(_feed(['# echo hlo', '\x1b[2D', '\x1b[1@e'])), ['# echo helo']);
    });

    test('조각 경계에서 잘린 UTF-8 도 이어 붙인다', () {
      final bytes = utf8.encode('안녕 world');
      final c = _feed([bytes.sublist(0, 2), bytes.sublist(2, 4), bytes.sublist(4)]);
      expect(_lines(c).single.replaceAll(' ', ''), '안녕world', reason: '한글은 두 칸이라 사이 칸이 생길 수 있다');
    });

    test('머신이 뜨고 내릴 때 구분선을 긋는다', () {
      final c = _feed(['# ls\r\n'])..mark('stopped');
      expect(_lines(c).last, '── stopped ──');
    });
  });

  group('입력 — 키는 바이트열이 되어 머신으로 간다', () {
    late SandboxConsole c;
    final sent = <String>[];

    setUp(() {
      sent.clear();
      c = SandboxConsole()..input = sent.add;
    });

    test('글자·Enter·Ctrl-C·화살표', () {
      c.terminal.textInput('ls -la');
      c.terminal.keyInput(TerminalKey.enter);
      c.terminal.charInput('c'.codeUnitAt(0), ctrl: true);
      c.terminal.keyInput(TerminalKey.arrowUp);
      expect(sent, ['ls -la', '\r', '\x03', '\x1b[A']);
    });

    test('머신이 없으면(input 없음) 조용히 버린다', () {
      final lone = SandboxConsole();
      lone.terminal.textInput('x'); // 던지지 않는다
    });
  });

  group('크기 — 화면이 잰 크기가 머신 콘솔 크기가 된다', () {
    test('바뀐 크기를 알리고 기억한다(다음 부팅 때 쓴다)', () {
      final got = <(int, int)>[];
      final c = SandboxConsole()..resized = (cols, rows) => got.add((cols, rows));
      c.terminal.resize(100, 30);
      expect(got.last, (100, 30));
      expect(c.size, (100, 30));
    });

    test('안 보이는 패널이 잰 엉뚱한 크기(0·1)는 보내지 않는다', () {
      final got = <(int, int)>[];
      final c = SandboxConsole()..resized = (cols, rows) => got.add((cols, rows));
      c.terminal.resize(0, 0);
      expect(got, isEmpty);
      expect(c.size, isNull);
    });
  });
}
