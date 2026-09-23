// 호스트 ↔ 샌드박스(게스트) 경로 대응. 도구 결과는 호스트 경로가 정본이다 —
// 트리·뷰어·file_changes·시스템 프롬프트가 전부 호스트 경로로 말하기 때문이다.
import 'package:collabo_ide/src/tools/tool_executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('Windows 호스트', () {
    final m = PathMapping([
      (r'C:\Users\me\proj', '/work'),
      (r'C:\Users\me\AppData\python_modules', '/opt/collabo/tools'),
    ], hostContext: p.windows);

    test('호스트 → 게스트 (대소문자·구분자 무관)', () {
      expect(m.toGuest(r'C:\Users\me\proj'), '/work');
      expect(m.toGuest(r'C:\Users\me\proj\src\a.py'), '/work/src/a.py');
      expect(m.toGuest(r'c:\users\ME\proj\b.txt'), '/work/b.txt');
      expect(m.toGuest('C:/Users/me/proj/c.txt'), '/work/c.txt');
      expect(m.toGuest(r'C:\Users\me\AppData\python_modules\collabo_tools.py'),
          '/opt/collabo/tools/collabo_tools.py');
    });

    test('마운트 밖·형제 prefix·상대 경로는 옮기지 않는다', () {
      expect(m.toGuest(r'C:\Users\me\proj-evil\x'), isNull);
      expect(m.toGuest(r'D:\other'), isNull);
      expect(m.toGuest(r'src\a.py'), isNull);
    });

    test('게스트 → 호스트', () {
      expect(m.toHost('/work'), r'C:\Users\me\proj');
      expect(m.toHost('/work/src/a.py'), r'C:\Users\me\proj\src\a.py');
      expect(m.toHost('/workshop/x'), isNull);
      expect(m.toHost('/etc/passwd'), isNull);
    });

    test('결과: 경로 키의 값만 바꾸고, 내용은 건드리지 않는다', () {
      final out = m.resultToHost({
        'path': '/work/a.txt',
        'src': '/work/old',
        'cwd': '/work',
        'paths': ['/work/p1', '/work/p2'],
        'content': '/work/a.txt',
        'entries': [
          {'name': 'b', 'path': '/work/b'},
        ],
        'stdout': 'cd /work/src\nls\n',
        'diff': '--- /work/a.txt\n+++ /work/a.txt\n@@ -1 +1 @@\n-/work/x\n+/work/y',
        // 문서 도구(collabo_docs)가 만든/복사한 파일을 부르는 이름.
        'created': '/work/new.docx',
        'copied_to': '/work/copy.docx',
      }) as Map;
      expect(out['path'], r'C:\Users\me\proj\a.txt');
      expect(out['src'], r'C:\Users\me\proj\old');
      expect(out['cwd'], r'C:\Users\me\proj');
      expect(out['paths'], [r'C:\Users\me\proj\p1', r'C:\Users\me\proj\p2']);
      expect(out['content'], '/work/a.txt', reason: '한 줄짜리 파일 내용이 경로 모양이어도 그대로');
      expect(((out['entries'] as List).first as Map)['path'], r'C:\Users\me\proj\b');
      expect(out['stdout'], 'cd /work/src\nls\n', reason: '명령 출력은 그대로');
      expect(out['diff'],
          '--- C:\\Users\\me\\proj\\a.txt\n+++ C:\\Users\\me\\proj\\a.txt\n@@ -1 +1 @@\n-/work/x\n+/work/y',
          reason: 'diff 는 헤더 두 줄만');
      expect(out['created'], r'C:\Users\me\proj\new.docx');
      expect(out['copied_to'], r'C:\Users\me\proj\copy.docx');
      // `created: true` 처럼 경로가 아닌 값은 그대로(문자열만 바꾼다).
      expect((m.resultToHost({'created': true}) as Map)['created'], isTrue);
    });

    test('인자: 모델이 되돌려 보낸 호스트 경로를 게스트로', () {
      expect(
        m.argsToGuest({
          'path': r'C:\Users\me\proj\a.txt',
          'query': 'hello',
          'paths': [r'C:\Users\me\proj\b', 'rel/c'],
          'n': 3,
        }),
        {
          'path': '/work/a.txt',
          'query': 'hello',
          'paths': ['/work/b', 'rel/c'],
          'n': 3,
        },
      );
    });
  });

  group('POSIX 호스트', () {
    final m = PathMapping([('/Users/me/proj', '/work')], hostContext: p.posix);

    test('왕복', () {
      expect(m.toGuest('/Users/me/proj/src/a.py'), '/work/src/a.py');
      expect(m.toHost('/work/src/a.py'), '/Users/me/proj/src/a.py');
      expect(m.toGuest('/Users/me/project2/a'), isNull);
    });
  });
}
