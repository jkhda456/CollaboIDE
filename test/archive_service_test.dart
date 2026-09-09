import 'dart:io';

import 'package:archive/archive.dart';
import 'package:collabo_ide/src/fs/archive_service.dart';
import 'package:collabo_ide/src/fs/file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_archive_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 테스트용 zip 하나를 만든다.
  File writeZip(String name, Map<String, String> files) {
    final archive = Archive();
    for (final e in files.entries) {
      final bytes = e.value.codeUnits;
      archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
    }
    final out = File(p.join(tmp.path, name));
    out.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return out;
  }

  group('형식 판정', () {
    test('확장자로 형식을 고른다 (복합 확장자 우선)', () {
      expect(ArchiveService.formatForPath('a.zip'), ArchiveFormat.zip);
      expect(ArchiveService.formatForPath('a.tar'), ArchiveFormat.tar);
      expect(ArchiveService.formatForPath('a.tar.gz'), ArchiveFormat.tarGz);
      expect(ArchiveService.formatForPath('a.tgz'), ArchiveFormat.tarGz);
      expect(ArchiveService.formatForPath('a.gz'), ArchiveFormat.gz);
      expect(ArchiveService.formatForPath('a.tar.xz'), ArchiveFormat.tarXz);
    });

    test('대소문자를 무시한다', () {
      expect(ArchiveService.formatForPath('A.ZIP'), ArchiveFormat.zip);
      expect(ArchiveService.formatForPath('A.Tar.Gz'), ArchiveFormat.tarGz);
    });

    test('zip 컨테이너를 쓰는 형식들도 zip 으로 본다', () {
      for (final ext in ['jar', 'apk', 'ipa', 'whl', 'docx', 'epub']) {
        expect(ArchiveService.formatForPath('a.$ext'), ArchiveFormat.zip,
            reason: ext);
      }
    });

    test('모르는 확장자는 unsupported (7z/rar 은 순수 Dart 로 못 읽는다)', () {
      expect(ArchiveService.formatForPath('a.7z'), ArchiveFormat.unsupported);
      expect(ArchiveService.formatForPath('a.rar'), ArchiveFormat.unsupported);
      expect(ArchiveService.formatForPath('a.txt'), ArchiveFormat.unsupported);
      expect(ArchiveService.isArchive('a.txt'), isFalse);
      expect(ArchiveService.isArchive('a.zip'), isTrue);
    });
  });

  group('목록', () {
    test('zip 안의 항목을 나열한다', () async {
      final zip = writeZip('sample.zip', {
        'readme.md': '# hello',
        'src/main.dart': 'void main() {}',
      });

      final listing = await ArchiveService().list(zip.path);

      expect(listing.error, isNull);
      expect(listing.format, ArchiveFormat.zip);
      expect(listing.entries.map((e) => e.name),
          containsAll(<String>['readme.md', 'src/main.dart']));
      expect(listing.truncated, isFalse);
      final readme =
          listing.entries.firstWhere((e) => e.name == 'readme.md');
      expect(readme.size, '# hello'.length);
      expect(readme.isDir, isFalse);
    });

    test('지원하지 않는 형식은 이유를 돌려준다 (예외를 던지지 않는다)', () async {
      final f = File(p.join(tmp.path, 'note.txt'));
      await f.writeAsString('not an archive');

      final listing = await ArchiveService().list(f.path);

      expect(listing.error, isNotNull);
      expect(listing.format, ArchiveFormat.unsupported);
      expect(listing.entries, isEmpty);
    });

    test('압축이 깨져 있어도 이유만 돌려준다', () async {
      final f = File(p.join(tmp.path, 'broken.zip'));
      await f.writeAsBytes(List<int>.filled(64, 7));

      final listing = await ArchiveService().list(f.path);

      expect(listing.error, isNotNull);
      expect(listing.entries, isEmpty);
    });

    test('없는 파일도 예외 없이 오류로', () async {
      final listing = await ArchiveService().list(p.join(tmp.path, 'nope.zip'));
      expect(listing.error, isNotNull);
    });

    test('같은 파일을 다시 열면 캐시를 쓴다', () async {
      final zip = writeZip('cached.zip', {'a.txt': 'a'});
      final service = ArchiveService();

      final first = await service.list(zip.path);
      final second = await service.list(zip.path);

      expect(identical(first, second), isTrue, reason: '해독을 반복하지 않는다');
    });

    test('파일이 바뀌면 캐시가 무효화된다', () async {
      final zip = writeZip('changing.zip', {'a.txt': 'a'});
      final service = ArchiveService();
      final first = await service.list(zip.path);

      // 크기·수정시각이 달라지도록 다시 쓴다.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      writeZip('changing.zip', {'a.txt': 'a', 'b.txt': 'bbbb'});
      final second = await service.list(zip.path);

      expect(identical(first, second), isFalse);
      expect(second.entries.map((e) => e.name), contains('b.txt'));
    });
  });

  group('항목 읽기 (미리보기)', () {
    test('텍스트 항목은 text 모드로 준다', () async {
      final zip = writeZip('read.zip', {
        'src/main.dart': 'void main() { print("hi"); }',
      });

      final data = await ArchiveService().readEntry(zip.path, 'src/main.dart');

      expect(data.error, isNull);
      expect(data.mode, 'text');
      expect(data.content, contains('void main()'));
      expect(data.size, 'void main() { print("hi"); }'.length);
      expect(data.truncated, isFalse);
    });

    test('바이너리 항목은 hex 덤프로 준다', () async {
      // NUL 이 섞이면 바이너리로 본다.
      final archive = Archive();
      final bytes = <int>[0x00, 0x01, 0x02, 0xff, 0x41];
      archive.addFile(ArchiveFile('blob.bin', bytes.length, bytes));
      final out = File(p.join(tmp.path, 'bin.zip'));
      out.writeAsBytesSync(ZipEncoder().encode(archive)!);

      final data = await ArchiveService().readEntry(out.path, 'blob.bin');

      expect(data.error, isNull);
      expect(data.mode, 'hex');
      expect(data.content, contains('00000000'));
      expect(data.size, bytes.length);
    });

    test('없는 항목은 이유를 돌려준다', () async {
      final zip = writeZip('miss.zip', {'a.txt': 'a'});

      final data = await ArchiveService().readEntry(zip.path, 'nope.txt');

      expect(data.error, isNotNull);
      expect(data.content, isEmpty);
    });

    test('같은 항목을 다시 읽으면 캐시를 쓴다', () async {
      final zip = writeZip('cache-entry.zip', {'a.txt': 'a'});
      final service = ArchiveService();

      final first = await service.readEntry(zip.path, 'a.txt');
      final second = await service.readEntry(zip.path, 'a.txt');

      expect(identical(first, second), isTrue);
    });

    test('압축이 아닌 파일은 이유를 돌려준다', () async {
      final f = File(p.join(tmp.path, 'plain.txt'));
      await f.writeAsString('hello');

      final data = await ArchiveService().readEntry(f.path, 'hello');

      expect(data.error, isNotNull);
    });
  });

  group('FileService 연동', () {
    test('archive 모드로 읽으면 내용이 목록 JSON 이다', () async {
      final zip = writeZip('fs.zip', {'a.txt': 'hello'});

      final content =
          await FileService().readFile(zip.path, mode: FileViewMode.archive);

      expect(content.mode, FileViewMode.archive);
      expect(content.content, contains('"entries"'));
      expect(content.content, contains('a.txt'));
      expect(content.size, await zip.length());
    });
  });
}
