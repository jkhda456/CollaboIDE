import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 큰 텍스트 파일을 **줄 단위 창(window)** 으로 읽기 위한 색인.
///
/// 파일 전체를 메모리에 올리지 않고 "1200번째 줄부터 200줄" 같은 요청에 답하려면,
/// 줄이 어디서 시작하는지를 알아야 한다. 줄마다 오프셋을 다 들고 있으면 큰 파일에서
/// 색인이 파일만큼 커지므로, **[step] 줄마다 하나씩**만 기억하고 그 사이는 읽으면서
/// 센다(그래서 한 창을 읽는 비용이 최대 [step] 줄로 묶인다).
class LineIndex {
  const LineIndex({
    required this.lineCount,
    required this.checkpoints,
    required this.step,
  });

  /// 전체 줄 수. 마지막 줄이 개행으로 끝나면 그 뒤의 빈 줄은 세지 않는다.
  final int lineCount;

  /// `checkpoints[i]` = **`i * step` 번째 줄**이 시작하는 바이트 오프셋.
  /// 항상 `checkpoints[0] == 0`.
  final List<int> checkpoints;

  final int step;

  Map<String, Object?> toJson() => {
        'lineCount': lineCount,
        'checkpoints': checkpoints,
        'step': step,
      };

  factory LineIndex.fromJson(Map<String, Object?> json) => LineIndex(
        lineCount: (json['lineCount'] as num?)?.toInt() ?? 0,
        checkpoints: [
          for (final o in (json['checkpoints'] as List? ?? const []))
            (o as num).toInt(),
        ],
        step: (json['step'] as num?)?.toInt() ?? 1,
      );
}

/// 줄 창 하나(뷰어가 지금 그릴 만큼).
class LineWindow {
  const LineWindow({
    required this.from,
    required this.lines,
    required this.lineCount,
  });

  /// 첫 줄의 번호(0-based).
  final int from;
  final List<String> lines;

  /// 파일 전체 줄 수(스크롤바 길이 계산용).
  final int lineCount;
}

/// 한 줄이 이보다 길면 잘라서 준다(한 줄짜리 거대 파일 대비).
const int _maxLineBytes = 64 * 1024;

/// 한 창이 가져올 수 있는 최대 바이트(줄 수와 별개의 안전장치).
const int _maxWindowBytes = 1 << 20;

const int _lf = 10;
const int _cr = 13;

/// 색인을 만든다. 파일 전체를 한 번 훑으므로 **아이솔레이트**에서 돈다.
Future<LineIndex> buildLineIndex(String path, {int step = 512}) async {
  final json = await Isolate.run(() => _indexInIsolate(path, step));
  return LineIndex.fromJson(jsonDecode(json) as Map<String, Object?>);
}

String _indexInIsolate(String path, int step) {
  final raf = File(path).openSync();
  try {
    final checkpoints = <int>[0];
    final buf = Uint8List(1 << 16);
    var lines = 0;
    var offset = 0;
    var last = -1;
    while (true) {
      final n = raf.readIntoSync(buf);
      if (n <= 0) break;
      for (var i = 0; i < n; i++) {
        if (buf[i] != _lf) continue;
        lines++;
        // 방금 끝난 줄의 다음 바이트가 `lines` 번째 줄의 시작이다.
        if (lines % step == 0) checkpoints.add(offset + i + 1);
      }
      last = buf[n - 1];
      offset += n;
    }
    // 개행으로 끝나지 않았으면 마지막 조각도 한 줄이다.
    final total = offset == 0 ? 0 : (last == _lf ? lines : lines + 1);
    return jsonEncode(
      LineIndex(lineCount: total, checkpoints: checkpoints, step: step).toJson(),
    );
  } finally {
    raf.closeSync();
  }
}

/// [from] 번째 줄부터 [count] 줄을 읽는다(0-based). 파일 끝을 넘으면 있는 만큼만.
///
/// 가장 가까운 체크포인트로 건너뛴 뒤 거기서부터 세면서 읽는다 — 앞에서부터 다시
/// 읽지 않으므로 파일이 아무리 커도 한 창의 비용은 일정하다.
Future<LineWindow> readLineWindow(
  String path,
  LineIndex index,
  int from,
  int count,
) async {
  if (count <= 0 || from < 0 || from >= index.lineCount) {
    return LineWindow(from: from, lines: const [], lineCount: index.lineCount);
  }
  final slot = from ~/ index.step;
  final at = slot < index.checkpoints.length ? slot : index.checkpoints.length - 1;
  var lineNo = at * index.step;

  final raf = await File(path).open();
  try {
    await raf.setPosition(index.checkpoints[at]);
    final out = <String>[];
    final pending = BytesBuilder();
    var used = 0;
    var eof = false;
    while (out.length < count && used < _maxWindowBytes) {
      final chunk = await raf.read(1 << 16);
      if (chunk.isEmpty) {
        eof = true;
        break;
      }
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] != _lf) continue;
        pending.add(chunk.sublist(start, i));
        start = i + 1;
        final bytes = pending.takeBytes();
        if (lineNo >= from) {
          out.add(_decodeLine(bytes));
          used += bytes.length;
        }
        lineNo++;
        if (out.length >= count || used >= _maxWindowBytes) break;
      }
      if (out.length >= count || used >= _maxWindowBytes) break;
      pending.add(chunk.sublist(start));
    }
    // 개행 없이 끝난 마지막 줄.
    if (eof && out.length < count && lineNo >= from) {
      final rest = pending.takeBytes();
      if (rest.isNotEmpty) out.add(_decodeLine(rest));
    }
    return LineWindow(from: from, lines: out, lineCount: index.lineCount);
  } finally {
    await raf.close();
  }
}

/// 한 줄을 문자열로. CRLF 의 `\r` 을 떼고, 지나치게 길면 잘라서 표시한다.
String _decodeLine(Uint8List bytes) {
  var end = bytes.length;
  if (end > 0 && bytes[end - 1] == _cr) end--;
  if (end > _maxLineBytes) {
    return '${utf8.decode(bytes.sublist(0, _maxLineBytes), allowMalformed: true)} …';
  }
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}
