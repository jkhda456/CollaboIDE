import 'package:collabo_ide/src/webview/web_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// 턴 요약은 이제 응답에 섞지 않고 별도 호출로 만든다. 다만 **그 이전에 저장된
/// 대화 기록**에는 `<turn_summary>` 마커가 본문으로 남아 있어, 표시·컨텍스트
/// 재사용 시 걷어내야 한다.
void main() {
  test('마커가 없으면 원문 그대로', () {
    const s = 'Just a normal answer with <b>html</b> and code `x < y`.';
    expect(stripTurnSummary(s), s);
  });

  test('짝이 맞는 블록은 통째로 제거하고 본문만 남긴다', () {
    const s = '<turn_summary>Did A and B.</turn_summary>\n\nHere is the answer.';
    expect(stripTurnSummary(s), 'Here is the answer.');
  });

  test('본문 뒤에 붙은 블록도 제거한다(모델이 순서를 어긴 경우)', () {
    const s = 'Here is the answer.\n<turn_summary>Did A.</turn_summary>';
    expect(stripTurnSummary(s), 'Here is the answer.\n');
  });

  test('여러 줄 요약도 제거한다', () {
    const s = '<turn_summary>\nline1\nline2\n</turn_summary>\nAnswer.';
    expect(stripTurnSummary(s), 'Answer.');
  });

  test('닫히지 않은 태그는 태그만 지우고 뒤 내용은 살린다', () {
    // 통째로 지우면 실제 답변을 잃는다 — 답변 유실 방지가 우선.
    const s = '<turn_summary>Did A.\nHere is the answer.';
    expect(stripTurnSummary(s), 'Did A.\nHere is the answer.');
  });

  test('닫는 태그만 있어도 안전하게 지운다', () {
    const s = 'Answer.</turn_summary>';
    expect(stripTurnSummary(s), 'Answer.');
  });

  test('대소문자가 달라도 제거한다', () {
    const s = '<TURN_SUMMARY>x</TURN_SUMMARY>Answer.';
    expect(stripTurnSummary(s), 'Answer.');
  });

  test('빈 문자열/공백에도 안전하다', () {
    expect(stripTurnSummary(''), '');
    expect(stripTurnSummary('   '), '   ');
  });
}
