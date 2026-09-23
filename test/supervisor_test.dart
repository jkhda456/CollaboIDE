import 'package:collabo_ide/src/agent/supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('정체 탐지 3종', () {
    test('진전 없는 라운드가 임계값에 닿으면 개입', () {
      final s = Supervisor(noProgressRounds: 3);
      expect(s.roundDone(progress: false), isNull);
      expect(s.roundDone(progress: false), isNull);
      final iv = s.roundDone(progress: false);
      expect(iv, isNotNull);
      expect(iv!.reason, contains('no progress'));
      expect(iv.level, 1);
    });

    test('진전이 있으면 카운터가 풀린다', () {
      final s = Supervisor(noProgressRounds: 3);
      s.roundDone(progress: false);
      s.roundDone(progress: false);
      s.roundDone(progress: true); // 리셋
      expect(s.roundDone(progress: false), isNull);
      expect(s.roundDone(progress: false), isNull);
      expect(s.roundDone(progress: false), isNotNull);
    });

    test('같은 도구를 같은 인자로 반복하면 개입', () {
      final s = Supervisor(repeatWindow: 4, repeatThreshold: 3);
      Intervention? iv;
      for (var i = 0; i < 4; i++) {
        iv = s.observe(const StepObs(
              tool: 'search_text',
              args: '{"query":"foo"}',
            )) ??
            iv;
      }
      expect(iv, isNotNull);
      expect(iv!.reason, contains('search_text'));
    });

    test('인자가 다르면 반복이 아니다', () {
      final s = Supervisor(repeatWindow: 4, repeatThreshold: 3);
      for (var i = 0; i < 8; i++) {
        final iv = s.observe(StepObs(tool: 'read_file', args: '{"path":"$i"}'));
        expect(iv, isNull);
      }
    });

    test('같은 오류를 반복하면 개입 — 숫자가 달라도 같은 오류로 본다', () {
      final s = Supervisor(sameErrorThreshold: 3);
      Intervention? iv;
      for (final line in [12, 15, 91]) {
        iv = s.observe(StepObs(
              tool: 'replace_lines',
              args: '{"start_line":$line}',
              errorSig: errorSignature('No match at line $line of foo.dart'),
            )) ??
            iv;
      }
      expect(iv, isNotNull);
      expect(iv!.reason, contains('same error'));
    });
  });

  test('errorSignature: 숫자를 지우고 길이를 자른다', () {
    expect(errorSignature('Line 12 failed'), errorSignature('Line 4096 failed'));
    expect(errorSignature(null), '');
    expect(errorSignature('   '), '');
    expect(errorSignature('x' * 500).length, 120);
  });

  test('사다리: 3단계까지 오르고 마지막에서 halt', () {
    final s = Supervisor(noProgressRounds: 1);
    final first = s.roundDone(progress: false)!;
    expect(first.action, 'force_hypothesis');
    expect(first.halt, isFalse);

    final second = s.roundDone(progress: false)!;
    expect(second.action, 'force_replan');
    expect(second.halt, isFalse);

    final third = s.roundDone(progress: false)!;
    expect(third.action, 'ask_user');
    expect(third.halt, isTrue);
    expect(third.message, contains('ask the user'));

    // 그 뒤로도 마지막 단계에 머문다(사다리 밖으로 나가지 않는다).
    final fourth = s.roundDone(progress: false)!;
    expect(fourth.action, 'ask_user');
    expect(fourth.level, 4);
  });

  test('개입 직후에는 같은 이유로 곧바로 다시 걸리지 않는다', () {
    final s = Supervisor(noProgressRounds: 2);
    expect(s.roundDone(progress: false), isNull);
    expect(s.roundDone(progress: false), isNotNull); // 개입 → 탐지기 리셋
    expect(s.roundDone(progress: false), isNull); // 다시 처음부터 센다
  });

  test('서브에이전트용: 마지막 단계가 사용자가 아니라 부모에게 보고', () {
    final s = Supervisor.forSubAgent();
    Intervention? last;
    for (var i = 0; i < 12; i++) {
      last = s.roundDone(progress: false) ?? last;
    }
    expect(last!.action, 'ask_user');
    expect(last.halt, isTrue);
    expect(last.message, contains('main agent'));
    expect(last.message, isNot(contains('ask the user')));
  });

  test('꺼져 있으면 아무것도 하지 않는다', () {
    final s = Supervisor(enabled: false, noProgressRounds: 1);
    expect(s.roundDone(progress: false), isNull);
    expect(s.observe(const StepObs(tool: 't', errorSig: 'e')), isNull);
    expect(
      s.exitViolations(openSteps: ['남은 단계'], usedTools: true),
      isEmpty,
    );
  });

  group('종료 차단 — 판단 재료는 구조뿐(답변 본문을 읽지 않는다)', () {
    final s = Supervisor();

    test('열린 단계가 남았으면 위반', () {
      final v = s.exitViolations(openSteps: ['테스트 돌리기'], usedTools: true);
      expect(v, hasLength(1));
      expect(v.first, contains('테스트 돌리기'));
    });

    test('열린 단계가 없으면 통과', () {
      expect(s.exitViolations(openSteps: [], usedTools: true), isEmpty);
    });

    test('도구를 안 쓴 턴(순수 대화)은 검사하지 않는다', () {
      expect(s.exitViolations(openSteps: ['남은 것'], usedTools: false), isEmpty);
    });

    test('열린 단계가 많으면 앞 4개만 보여 주고 나머지는 개수로', () {
      final v = s.exitViolations(
        openSteps: ['a', 'b', 'c', 'd', 'e', 'f'],
        usedTools: true,
      );
      expect(v.first, contains('+2 more'));
    });

    test('되돌려보내는 문구가 BLOCKED 탈출구를 알려 준다', () {
      // 사용자에게 물으려면 문장이 아니라 **도구 호출**로 표시해야 한다는 것이
      // 모델에게 전달되는 유일한 경로다.
      final v = s.exitViolations(openSteps: ['답을 기다림'], usedTools: true);
      expect(v.first, contains('BLOCKED'));
      expect(v.first, contains('update_plan'));
    });

    test('같은 계획 상태로 헛돌면 상한에서 멈춘다', () {
      final t = Supervisor(maxReinjections: 2);
      const open = ['테스트 돌리기'];
      expect(t.mayReinjectFor(open), isTrue);
      t.noteReinjection(open);
      expect(t.mayReinjectFor(open), isTrue);
      t.noteReinjection(open);
      expect(t.mayReinjectFor(open), isFalse, reason: '두 번 밀어도 그대로면 그만둔다');
      expect(t.exhaustedFor(open), isTrue);
    });

    test('★ 계획이 움직이면 예산이 되살아난다 — 단계가 많아도 차단이 사라지지 않는다', () {
      // 예전에는 생성 한 번에 두 번이 전부였다. 단계가 여럿인 작업은 세 번째부터
      // 종료 차단이 조용히 빠져, 할 일이 남은 채로 턴이 끝났다.
      final t = Supervisor(maxReinjections: 2);
      t.noteReinjection(['a', 'b', 'c']);
      t.noteReinjection(['a', 'b', 'c']);
      expect(t.mayReinjectFor(['a', 'b', 'c']), isFalse);

      // 모델이 a 를 끝냈다(계획이 움직였다) → 다시 밀어 준다.
      expect(t.mayReinjectFor(['b', 'c']), isTrue);
      t.noteReinjection(['b', 'c']);
      expect(t.mayReinjectFor(['b', 'c']), isTrue, reason: '그 상태에서는 다시 처음부터 센다');
    });
  });
}
