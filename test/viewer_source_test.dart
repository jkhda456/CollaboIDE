import 'package:collabo_ide/src/viewers/viewer_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ViewerSource.stagedName', () {
    test('같은 경로면 항상 같은 이름 (잔재 정리 기준)', () {
      const a = ViewerSource(path: '/home/me/viewers/image.js');
      const b = ViewerSource(path: '/home/me/viewers/image.js');
      expect(a.stagedName, b.stagedName);
    });

    test('다른 폴더의 같은 파일명은 서로 다른 이름이 된다', () {
      const a = ViewerSource(path: '/one/image.js');
      const b = ViewerSource(path: '/two/image.js');
      expect(a.stagedName, isNot(b.stagedName));
      expect(a.stagedName, startsWith('image_'));
      expect(b.stagedName, startsWith('image_'));
    });

    test('파일명에 쓰기 어려운 문자는 밑줄로 바뀌고 .js 로 끝난다', () {
      const v = ViewerSource(path: '/tmp/내 뷰어 (v2).js');
      expect(v.stagedName, endsWith('.js'));
      expect(v.stagedName, matches(r'^[A-Za-z0-9_-]+\.js$'));
    });

    test('확장자만 있는 파일명도 이름이 비지 않는다', () {
      const v = ViewerSource(path: '/tmp/.js');
      expect(v.stagedName, startsWith('viewer_'));
    });
  });

  group('ViewerSource', () {
    test('표시 이름은 label, 없으면 파일명', () {
      expect(const ViewerSource(path: '/a/b/image.js').displayName, 'image.js');
      expect(
        const ViewerSource(path: '/a/b/image.js', label: '이미지').displayName,
        '이미지',
      );
    });

    test('JSON 왕복', () {
      const v = ViewerSource(path: '/a/image.js', label: 'Image');
      final back = ViewerSource.fromJson(v.toJson());
      expect(back.path, v.path);
      expect(back.label, v.label);
      expect(back.id, v.id);
    });

    test('구버전(경로 문자열) 이주', () {
      final v = ViewerSource.legacy('/a/image.js');
      expect(v.path, '/a/image.js');
      expect(v.label, isEmpty);
    });
  });
}
