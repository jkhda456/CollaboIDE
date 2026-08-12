import 'package:collabo_ide/src/viewers/viewer_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ViewerRule.parseExtensions', () {
    test('구분자(쉼표/공백/세미콜론)를 모두 받는다', () {
      expect(ViewerRule.parseExtensions('.md, .txt;.log .csv'),
          ['.md', '.txt', '.log', '.csv']);
    });

    test('점·별표 유무와 대소문자를 흡수한다', () {
      expect(ViewerRule.parseExtensions('MD, *.Markdown, .TXT'),
          ['.md', '.markdown', '.txt']);
    });

    test('중복은 첫 등장만 남긴다', () {
      expect(ViewerRule.parseExtensions('.md, md, *.MD'), ['.md']);
    });

    test('빈 입력과 점만 있는 조각은 버린다', () {
      expect(ViewerRule.parseExtensions('   '), isEmpty);
      expect(ViewerRule.parseExtensions('. , .md , *'), ['.md']);
    });

    test('입력창 표시 형태로 되돌린다', () {
      expect(ViewerRule.formatExtensions(['.md', '.txt']), '.md, .txt');
    });
  });

  group('ViewerRule', () {
    test('기본 상태는 저장할 필요가 없다', () {
      expect(const ViewerRule().isDefault, isTrue);
      expect(const ViewerRule(enabled: false).isDefault, isFalse);
      // 빈 목록은 "담당 확장자 없음" 이라는 명시적 설정이다 — 기본값이 아니다.
      expect(const ViewerRule(extensions: []).isDefault, isFalse);
    });

    test('clearExtensions 로 확장자 override 를 해제한다', () {
      const r = ViewerRule(enabled: false, extensions: ['.md']);
      final cleared = r.copyWith(clearExtensions: true);
      expect(cleared.extensions, isNull);
      expect(cleared.enabled, isFalse, reason: '사용 여부는 그대로여야 한다');
    });

    test('JSON 왕복 (확장자 없으면 키를 넣지 않는다)', () {
      expect(const ViewerRule().toJson().containsKey('extensions'), isFalse);
      final back = ViewerRule.fromJson(
          const ViewerRule(enabled: false, extensions: ['.md']).toJson());
      expect(back.enabled, isFalse);
      expect(back.extensions, ['.md']);
    });

    test('JSON 의 확장자도 정규화한다 (구버전/손으로 고친 값)', () {
      final r = ViewerRule.fromJson({'extensions': ['MD', 'txt']});
      expect(r.extensions, ['.md', '.txt']);
    });
  });

  group('ViewerInfo', () {
    test('웹 보고를 파싱한다', () {
      final info = ViewerInfo.fromJson({
        'id': 'markdown',
        'label': 'Markdown',
        'dataMode': 'text',
        'extensions': ['.MD', 'markdown'],
        'user': true,
      });
      expect(info.id, 'markdown');
      expect(info.dataMode, 'text');
      expect(info.defaultExtensions, ['.md', '.markdown']);
      expect(info.user, isTrue);
    });

    test('모르는 dataMode 는 text 로 본다', () {
      final info = ViewerInfo.fromJson({'id': 'x', 'dataMode': 'weird'});
      expect(info.dataMode, 'text');
      expect(info.defaultExtensions, isEmpty);
      expect(info.user, isFalse);
    });

    test('JSON 왕복 (캐시 저장·복원)', () {
      const info = ViewerInfo(
        id: 'markdown',
        label: 'Markdown',
        dataMode: 'text',
        defaultExtensions: ['.md'],
        user: true,
      );
      final back = ViewerInfo.fromJson(info.toJson());
      expect(back.id, info.id);
      expect(back.label, info.label);
      expect(back.dataMode, info.dataMode);
      expect(back.defaultExtensions, info.defaultExtensions);
      expect(back.user, isTrue);
    });
  });

  group('sortViewersByOrder', () {
    ViewerInfo v(String id) => ViewerInfo(
          id: id,
          label: id,
          dataMode: 'text',
          defaultExtensions: const [],
        );

    test('순서를 정하지 않으면 등록된 순서 그대로', () {
      final out = sortViewersByOrder([v('md'), v('ed'), v('text')], const []);
      expect(out.map((e) => e.id), ['md', 'ed', 'text']);
    });

    test('사용자 순서가 등록 순서를 이긴다', () {
      final out = sortViewersByOrder(
          [v('md'), v('ed'), v('text')], ['ed', 'text', 'md']);
      expect(out.map((e) => e.id), ['ed', 'text', 'md']);
    });

    test('목록에 없는 뷰어(새로 등록됨)는 뒤로, 그들끼리는 등록 순서', () {
      final out =
          sortViewersByOrder([v('new1'), v('md'), v('new2')], ['md']);
      expect(out.map((e) => e.id), ['md', 'new1', 'new2']);
    });

    test('사라진 뷰어 id 가 순서에 남아 있어도 나머지 순서는 유지된다', () {
      final out = sortViewersByOrder([v('a'), v('b')], ['gone', 'b', 'a']);
      expect(out.map((e) => e.id), ['b', 'a']);
    });
  });
}
