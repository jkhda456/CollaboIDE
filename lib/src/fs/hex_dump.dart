/// 표준 hex 덤프(오프셋 + 16바이트 + ASCII).
///
/// 파일 뷰어([FileService])와 압축 항목 미리보기([ArchiveService])가 같은 모양을
/// 보여야 해서 여기에 따로 뒀다(두 서비스가 서로를 import 하지 않게 하려는 목적도 있다).

/// 한 줄에 담는 바이트 수. 큰 파일의 창(window) 계산도 이 값을 기준으로 한다.
const int hexBytesPerLine = 16;

/// 덤프를 **줄 배열**로 만든다.
///
/// [startOffset] 은 첫 바이트의 파일 내 위치 — 큰 파일을 중간부터 잘라 읽을 때
/// 주소 칸이 0 부터 다시 시작하지 않게 한다.
List<String> hexDumpLines(List<int> bytes, {int startOffset = 0}) {
  final lines = <String>[];
  for (var i = 0; i < bytes.length; i += hexBytesPerLine) {
    final sb = StringBuffer();
    sb.write((startOffset + i).toRadixString(16).padLeft(8, '0'));
    sb.write('  ');
    final ascii = StringBuffer();
    for (var j = 0; j < hexBytesPerLine; j++) {
      if (i + j < bytes.length) {
        final b = bytes[i + j];
        sb.write(b.toRadixString(16).padLeft(2, '0'));
        sb.write(' ');
        ascii.write(b >= 32 && b < 127 ? String.fromCharCode(b) : '.');
      } else {
        sb.write('   ');
      }
      if (j == 7) sb.write(' ');
    }
    sb.write(' ');
    sb.write(ascii);
    lines.add(sb.toString());
  }
  return lines;
}

/// 덤프 문자열(줄마다 개행으로 끝난다).
String hexDump(List<int> bytes, {int startOffset = 0}) {
  final lines = hexDumpLines(bytes, startOffset: startOffset);
  if (lines.isEmpty) return '';
  return '${lines.join('\n')}\n';
}
