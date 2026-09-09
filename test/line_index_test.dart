import 'dart:io';

import 'package:collabo_ide/src/fs/file_service.dart';
import 'package:collabo_ide/src/fs/line_index.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 대용량 파일 뷰어(가상 스크롤)가 기대는 두 가지를 본다:
/// ① 줄 수를 정확히 세는가 ② 아무 줄에서나 시작하는 창을 정확히 읽는가.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_lines_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> write(String name, String content) async {
    final f = File(p.join(tmp.path, name));
    await f.writeAsString(content);
    return f;
  }

  group('줄 세기', () {
    test('개행으로 끝나면 그 뒤의 빈 줄은 세지 않는다', () async {
      final f = await write('a.txt', 'one\ntwo\nthree\n');

      final index = await buildLineIndex(f.path);

      expect(index.lineCount, 3);
    });

    test('개행 없이 끝나는 마지막 줄도 한 줄이다', () async {
      final f = await write('b.txt', 'one\ntwo');

      final index = await buildLineIndex(f.path);

      expect(index.lineCount, 2);
    });

    test('빈 파일은 0줄', () async {
      final f = await write('c.txt', '');

      final index = await buildLineIndex(f.path);

      expect(index.lineCount, 0);
    });
  });

  group('창 읽기', () {
    test('체크포인트 사이의 줄도 정확히 집는다', () async {
      // step=8 이면 체크포인트는 0/8/16/… 줄. 그 사이(예: 21)에서 시작해 본다.
      final f = await write(
        'd.txt',
        [for (var i = 0; i < 40; i++) 'line $i'].join('\n'),
      );
      final index = await buildLineIndex(f.path, step: 8);

      final w = await readLineWindow(f.path, index, 21, 3);

      expect(w.from, 21);
      expect(w.lines, ['line 21', 'line 22', 'line 23']);
      expect(w.lineCount, 40);
    });

    test('파일 끝을 넘겨 달라고 하면 있는 만큼만 준다', () async {
      final f = await write('e.txt', 'a\nb\nc\n');
      final index = await buildLineIndex(f.path);

      final w = await readLineWindow(f.path, index, 2, 10);

      expect(w.lines, ['c']);
    });

    test('마지막 줄이 개행으로 끝나지 않아도 읽는다', () async {
      final f = await write('f.txt', 'a\nb\nc');
      final index = await buildLineIndex(f.path);

      final w = await readLineWindow(f.path, index, 1, 5);

      expect(w.lines, ['b', 'c']);
    });

    test('CRLF 의 \\r 은 떼고 준다', () async {
      final f = await write('g.txt', 'a\r\nb\r\n');
      final index = await buildLineIndex(f.path);

      final w = await readLineWindow(f.path, index, 0, 2);

      expect(w.lines, ['a', 'b']);
    });

    test('범위 밖에서 시작하면 빈 창', () async {
      final f = await write('h.txt', 'a\nb\n');
      final index = await buildLineIndex(f.path);

      final w = await readLineWindow(f.path, index, 99, 5);

      expect(w.lines, isEmpty);
      expect(w.lineCount, 2);
    });
  });

  group('FileService 창', () {
    test('상한을 넘는 텍스트 파일은 windowed + 전체 줄 수를 알려 준다', () async {
      // 1MB 상한을 넘기려면 넉넉히. 한 줄 = 20바이트 → 60000줄 ≈ 1.2MB.
      final f = await write(
        'big.txt',
        [for (var i = 0; i < 60000; i++) 'line ${i.toString().padLeft(12, '0')}']
            .join('\n'),
      );
      final fs = FileService();

      final content = await fs.readFile(f.path, mode: FileViewMode.text);

      expect(content.truncated, isTrue, reason: '전체를 다 담지 않았다');
      expect(content.windowed, isTrue);
      expect(content.lineCount, 60000);

      final w = await fs.readWindow(f.path,
          mode: FileViewMode.text, from: 59998, count: 10);
      expect(w.lines, [
        'line ${59998.toString().padLeft(12, '0')}',
        'line ${59999.toString().padLeft(12, '0')}',
      ]);
    });

    test('작은 파일은 창을 쓰지 않는다', () async {
      final f = await write('small.txt', 'hello\nworld\n');
      final fs = FileService();

      final content = await fs.readFile(f.path, mode: FileViewMode.text);

      expect(content.truncated, isFalse);
      expect(content.windowed, isFalse);
    });

    test('hex 창은 16바이트씩, 주소가 이어진다', () async {
      final bytes = List<int>.generate(64, (i) => i);
      final f = File(p.join(tmp.path, 'bin.dat'));
      await f.writeAsBytes(bytes);
      final fs = FileService();

      final w = await fs.readWindow(f.path,
          mode: FileViewMode.hex, from: 2, count: 2);

      expect(w.lines.length, 2);
      expect(w.lineCount, 4, reason: '64바이트 / 16 = 4줄');
      expect(w.lines.first.startsWith('00000020'), isTrue,
          reason: '3번째 줄의 주소는 0x20');
    });
  });
}
