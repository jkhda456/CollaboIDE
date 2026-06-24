import 'dart:io';

import 'package:collabo_ide/src/fs/file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  final fs = FileService();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_fs_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('디렉토리 나열: 폴더 먼저, 그다음 파일(이름순)', () async {
    await Directory(p.join(tmp.path, 'zdir')).create();
    await Directory(p.join(tmp.path, 'adir')).create();
    await File(p.join(tmp.path, 'b.txt')).writeAsString('x');
    await File(p.join(tmp.path, 'a.txt')).writeAsString('x');

    final entries = await fs.listDirectory(tmp.path);
    expect(entries.map((e) => e.name).toList(), ['adir', 'zdir', 'a.txt', 'b.txt']);
    expect(entries.first.isDir, isTrue);
  });

  test('기본 모드 추정: 확장자 기반', () {
    expect(fs.defaultModeFor('a.md'), FileViewMode.md);
    expect(fs.defaultModeFor('a.dart'), FileViewMode.text);
    expect(fs.defaultModeFor('a.png'), FileViewMode.hex);
  });

  test('텍스트 파일 읽기', () async {
    final f = File(p.join(tmp.path, 'note.txt'));
    await f.writeAsString('hello\nworld');
    final c = await fs.readFile(f.path);
    expect(c.mode, FileViewMode.text);
    expect(c.content, 'hello\nworld');
    expect(c.truncated, isFalse);
  });

  test('hex 모드: 덤프에 오프셋/ASCII 포함', () async {
    final f = File(p.join(tmp.path, 'bin.dat'));
    await f.writeAsBytes([0x41, 0x42, 0x43]); // ABC
    final c = await fs.readFile(f.path, mode: FileViewMode.hex);
    expect(c.mode, FileViewMode.hex);
    expect(c.content, contains('00000000'));
    expect(c.content, contains('41 42 43'));
    expect(c.content, contains('ABC'));
  });

  test('대용량 가드: 상한 초과 시 truncated', () async {
    final f = File(p.join(tmp.path, 'big.txt'));
    await f.writeAsBytes(List.filled(FileService.maxTextBytes + 100, 0x61));
    final c = await fs.readFile(f.path, mode: FileViewMode.text);
    expect(c.truncated, isTrue);
    expect(c.content.length, FileService.maxTextBytes);
    expect(c.size, FileService.maxTextBytes + 100);
  });
}
