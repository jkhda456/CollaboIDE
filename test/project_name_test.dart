import 'package:collabo_ide/src/ui/new_project_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('정상 이름은 통과', () {
    expect(validateProjectName('my_project'), isNull);
    expect(validateProjectName('프로젝트-1'), isNull);
    expect(validateProjectName('  trim me  '), isNull); // 내부 trim 후 유효
  });

  test('빈 이름/공백은 거부', () {
    expect(validateProjectName(''), isNotNull);
    expect(validateProjectName('   '), isNotNull);
  });

  test('3개 OS 공통 금지 문자 거부', () {
    for (final c in [r'<', r'>', r':', '"', '/', r'\', '|', '?', '*']) {
      expect(validateProjectName('a${c}b'), isNotNull, reason: '문자 $c 는 막혀야 함');
    }
  });

  test('. 와 .. 거부', () {
    expect(validateProjectName('.'), isNotNull);
    expect(validateProjectName('..'), isNotNull);
  });

  test('마침표/공백으로 끝나면 거부(Windows)', () {
    expect(validateProjectName('name.'), isNotNull);
    expect(validateProjectName('name '), isNull); // trim 되어 통과
    expect(validateProjectName('na me'), isNull); // 내부 공백은 허용
  });

  test('Windows 예약어 거부', () {
    expect(validateProjectName('CON'), isNotNull);
    expect(validateProjectName('com1'), isNotNull);
    expect(validateProjectName('LPT9.txt'), isNotNull);
    expect(validateProjectName('console'), isNull); // 예약어 아님
  });
}
