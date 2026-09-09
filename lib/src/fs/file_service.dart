import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'archive_service.dart';
import 'hex_dump.dart';
import 'line_index.dart';

/// 파일 뷰어 모드.
///
/// [archive] 는 압축 파일의 **목록(JSON)** 을 내용으로 준다 — 뷰어는 그걸 파싱해
/// 그린다. 웹은 파일시스템에 접근하지 않으므로 압축 해독도 네이티브가 한다.
enum FileViewMode { text, hex, md, archive }

/// 디렉토리 항목 한 건.
class FsEntry {
  const FsEntry({required this.name, required this.path, required this.isDir});

  final String name;
  final String path;
  final bool isDir;

  Map<String, Object?> toJson() =>
      {'name': name, 'path': path, 'isDir': isDir};
}

/// 파일 읽기 결과(대용량 가드 포함).
class FileContent {
  const FileContent({
    required this.path,
    required this.mode,
    required this.content,
    required this.size,
    required this.truncated,
    this.windowed = false,
    this.lineCount = 0,
  });

  final String path;
  final FileViewMode mode;
  final String content;

  /// 파일 전체 크기(바이트).
  final int size;

  /// 대용량으로 인해 일부만 읽었는지.
  final bool truncated;

  /// 창(window) 단위로 이어 읽을 수 있는지 — 뷰어가 가상 스크롤을 켜는 신호.
  ///
  /// [content] 는 **창 여부와 무관하게 늘 앞부분 전체**다(예전 뷰어도 그대로 동작).
  /// 새 뷰어는 이 값이 true 면 `file.window` 로 필요한 줄만 받아 그린다.
  final bool windowed;

  /// 파일 전체 줄 수(hex 는 16바이트 = 한 줄). 창을 못 쓰면 0.
  final int lineCount;

  Map<String, Object?> toJson() => {
        'path': path,
        'mode': mode.name,
        'content': content,
        'size': size,
        'truncated': truncated,
        if (windowed) 'windowed': true,
        if (windowed) 'lineCount': lineCount,
      };
}

/// 파일시스템 접근(네이티브 전용). 웹뷰는 이 결과만 받아 렌더링한다.
///
/// 모든 읽기는 **대용량 파일을 염두에 둔 상한**을 둔다. 현재는 앞부분만 읽어
/// 보여주며, 전체 편집/가상 스크롤은 후속 단계에서 청크 단위로 확장한다.
class FileService {
  /// text/md 모드에서 한 번에 읽는 최대 바이트(1MB).
  static const int maxTextBytes = 1 << 20;

  /// hex 모드에서 한 번에 읽는 최대 바이트(256KB).
  static const int maxHexBytes = 1 << 18;

  /// 압축 파일 목록 API(순수 Dart, 아이솔레이트 + 캐시).
  final ArchiveService archives = ArchiveService();

  /// 디렉토리 직속 항목을 반환(폴더 먼저, 그다음 파일, 이름순). 숨김(.) 제외 안 함.
  Future<List<FsEntry>> listDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final entries = <FsEntry>[];
    await for (final e in dir.list(followLinks: false)) {
      final isDir = e is Directory;
      entries.add(FsEntry(name: p.basename(e.path), path: e.path, isDir: isDir));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// 프로젝트 폴더 구조를 **짧게** 요약한다(에이전트 상태 주입용).
  ///
  /// 각 줄은 `상대경로/ (n files)` 형태이고, 얕은 곳부터(BFS) [maxDirs] 개까지만
  /// 훑는다. `_skipDirs`(.git/.collabo/node_modules/build/…)는 건너뛴다.
  /// 큰 프로젝트에서도 비용과 길이가 상한에 묶이도록 **깊이·개수 모두 제한**한다.
  /// 잘렸으면 마지막 줄에 `…` 표시를 붙인다.
  Future<List<String>> outline(
    String root, {
    int maxDirs = 40,
    int maxDepth = 3,
  }) async {
    final lines = <String>[];
    final queue = <({String path, int depth})>[(path: root, depth: 0)];
    var truncated = false;

    while (queue.isNotEmpty) {
      if (lines.length >= maxDirs) {
        truncated = true;
        break;
      }
      final cur = queue.removeAt(0);
      List<FileSystemEntity> children;
      try {
        children = await Directory(cur.path).list(followLinks: false).toList();
      } catch (_) {
        continue; // 권한 등으로 못 읽는 폴더는 건너뛴다.
      }
      var files = 0;
      final subdirs = <String>[];
      for (final e in children) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (!_skipDirs.contains(name)) subdirs.add(e.path);
        } else {
          files++;
        }
      }
      // 루트 자신은 './' 로, 하위는 상대 경로로 표기.
      final rel = cur.path == root ? '.' : p.relative(cur.path, from: root);
      lines.add('$rel/ ($files ${files == 1 ? 'file' : 'files'})');
      if (cur.depth < maxDepth) {
        subdirs.sort();
        for (final d in subdirs) {
          queue.add((path: d, depth: cur.depth + 1));
        }
      } else if (subdirs.isNotEmpty) {
        truncated = true;
      }
    }
    if (truncated || queue.isNotEmpty) lines.add('… (truncated)');
    return lines;
  }

  /// 확장자로 기본 뷰어 모드를 추정한다.
  FileViewMode defaultModeFor(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    if (ext == '.md' || ext == '.markdown') return FileViewMode.md;
    return _looksTextual(ext) ? FileViewMode.text : FileViewMode.hex;
  }

  static const Set<String> _textExts = {
    '.txt', '.md', '.markdown', '.dart', '.json', '.yaml', '.yml', '.xml',
    '.html', '.htm', '.css', '.js', '.ts', '.py', '.c', '.h', '.cpp', '.cc',
    '.hpp', '.java', '.kt', '.go', '.rs', '.rb', '.php', '.sh', '.bat', '.ps1',
    '.ini', '.cfg', '.conf', '.toml', '.csv', '.log', '.sql', '.gradle',
    '.properties', '.gitignore', '.env',
  };

  bool _looksTextual(String ext) => _textExts.contains(ext);

  /// 파일을 주어진 모드로 읽는다(상한 적용). [mode] 가 null 이면 기본 모드 추정.
  Future<FileContent> readFile(String filePath, {FileViewMode? mode}) async {
    final resolved = mode ?? defaultModeFor(filePath);
    final file = File(filePath);
    final size = await file.length();

    if (resolved == FileViewMode.archive) {
      // 내용 = 목록 JSON. 해독은 아이솔레이트에서 돌아 UI 를 막지 않는다.
      // 열지 못한 경우도 JSON 안의 error 로 전달해 뷰어가 이유를 보여 준다.
      final listing = await archives.list(filePath);
      return FileContent(
        path: filePath,
        mode: resolved,
        content: jsonEncode(listing.toJson()),
        size: size,
        // 목록이 잘렸다는 뜻(파일 앞부분만 읽은 게 아니다).
        truncated: listing.truncated,
      );
    }

    if (resolved == FileViewMode.hex) {
      final bytes = await _readPrefix(file, maxHexBytes);
      final truncated = size > bytes.length;
      return FileContent(
        path: filePath,
        mode: resolved,
        content: hexDump(bytes),
        size: size,
        truncated: truncated,
        // hex 는 색인이 필요 없다 — n번째 줄 = 16n 바이트.
        windowed: truncated,
        lineCount: truncated ? (size + hexBytesPerLine - 1) ~/ hexBytesPerLine : 0,
      );
    }

    // text / md: 앞부분 바이트를 UTF-8(불량 허용)로 디코드.
    final bytes = await _readPrefix(file, maxTextBytes);
    final truncated = size > bytes.length;
    // md 는 창을 쓰지 않는다 — 마크다운은 문서 전체가 있어야 렌더가 맞는다
    // (표·코드블록이 창 경계에서 잘리면 다르게 그려진다). 잘림 안내만 남긴다.
    // 색인은 파일을 한 번 통독하므로, 통독 자체가 부담인 크기는 제외한다.
    final canWindow = truncated &&
        resolved == FileViewMode.text &&
        size <= maxIndexBytes;
    return FileContent(
      path: filePath,
      mode: resolved,
      content: utf8.decode(bytes, allowMalformed: true),
      size: size,
      truncated: truncated,
      windowed: canWindow,
      lineCount: canWindow ? (await _indexFor(filePath, size)).lineCount : 0,
    );
  }

  // --- 창(window) 읽기: 대용량 파일 가상 스크롤 ---

  /// 한 번에 줄 수 있는 최대 줄 수(요청이 더 커도 여기서 자른다).
  static const int maxWindowLines = 2000;

  /// 줄 색인을 만들 수 있는 최대 크기(512MB).
  ///
  /// 색인은 파일을 처음부터 끝까지 한 번 읽어야 한다 — 그 자체가 오래 걸리는
  /// 크기면 가상 스크롤을 켜지 않고 예전처럼 **앞부분만** 보여 준다(hex 는 색인이
  /// 필요 없으므로 이 제한과 무관하다).
  static const int maxIndexBytes = 512 << 20;

  /// 줄 색인 캐시. 파일마다 전체 스캔이 한 번 필요하므로 재사용한다.
  /// 키는 `경로|크기|수정시각` — 파일이 바뀌면 자연히 새 색인을 만든다.
  final Map<String, LineIndex> _indexes = {};

  Future<LineIndex> _indexFor(String filePath, int size) async {
    final stat = await File(filePath).stat();
    final key = '$filePath|$size|${stat.modified.millisecondsSinceEpoch}';
    final hit = _indexes[key];
    if (hit != null) return hit;
    final index = await buildLineIndex(filePath);
    // 오래된 항목부터 버린다(같은 파일을 오가며 보는 게 흔하므로 몇 개는 남긴다).
    if (_indexes.length >= 4) _indexes.remove(_indexes.keys.first);
    _indexes[key] = index;
    return index;
  }

  /// [from] 번째 줄부터 [count] 줄을 읽는다(0-based).
  ///
  /// text 는 줄 색인을, hex 는 `16바이트 = 한 줄` 규칙을 쓴다. 그 외 모드는
  /// 창을 지원하지 않으므로 빈 결과를 준다(호출측이 전체 내용을 이미 갖고 있다).
  Future<LineWindow> readWindow(
    String filePath, {
    required FileViewMode mode,
    required int from,
    required int count,
  }) async {
    final want = count < 0 ? 0 : (count > maxWindowLines ? maxWindowLines : count);
    final size = await File(filePath).length();

    if (mode == FileViewMode.hex) {
      final total = (size + hexBytesPerLine - 1) ~/ hexBytesPerLine;
      if (from < 0 || from >= total || want == 0) {
        return LineWindow(from: from, lines: const [], lineCount: total);
      }
      final start = from * hexBytesPerLine;
      final raf = await File(filePath).open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(want * hexBytesPerLine);
        return LineWindow(
          from: from,
          lines: hexDumpLines(bytes, startOffset: start),
          lineCount: total,
        );
      } finally {
        await raf.close();
      }
    }

    if (mode != FileViewMode.text) {
      return LineWindow(from: from, lines: const [], lineCount: 0);
    }
    final index = await _indexFor(filePath, size);
    return readLineWindow(filePath, index, from, want);
  }

  Future<List<int>> _readPrefix(File file, int maxBytes) async {
    final raf = await file.open();
    try {
      final len = await raf.length();
      return await raf.read(len < maxBytes ? len : maxBytes);
    } finally {
      await raf.close();
    }
  }

  static const Set<String> _skipDirs = {
    '.git', '.collabo', 'node_modules', 'build', '.dart_tool', '.idea',
    '__pycache__',
  };

  /// 이름에 [query] 를 포함하는 파일을 프로젝트에서 재귀 검색한다(파일명 검색).
  Future<List<FsEntry>> findByName(String root, String query,
      {int limit = 300}) async {
    final q = query.toLowerCase().trim();
    if (q.isEmpty) return const [];
    final out = <FsEntry>[];
    final stack = <String>[root];
    while (stack.isNotEmpty && out.length < limit) {
      final dir = Directory(stack.removeLast());
      try {
        await for (final e in dir.list(followLinks: false)) {
          final name = p.basename(e.path);
          if (e is Directory) {
            if (!_skipDirs.contains(name)) stack.add(e.path);
          } else if (name.toLowerCase().contains(q)) {
            out.add(FsEntry(name: name, path: e.path, isDir: false));
            if (out.length >= limit) break;
          }
        }
      } catch (_) {}
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// 파일 내용을 UTF-8 로 덮어쓴다(뷰어 편집기의 저장).
  ///
  /// **에이전트의 파일 수정과는 다른 경로다.** 에이전트는 Python 도구 계층만
  /// 쓰고(워크스페이스 가드·diff 기록), 이건 사용자가 뷰어에서 직접 누른 저장이다.
  /// 호출부([WebBridge])가 프로젝트 안인지 먼저 확인한다.
  Future<void> writeFile(String filePath, String content) async {
    await File(filePath).writeAsString(content, flush: true);
  }

  /// 파일/디렉토리를 이동(이름 변경)한다.
  Future<void> movePath(String src, String dst) async {
    final type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      await File(src).rename(dst);
    }
  }

  /// 파일/디렉토리를 복사한다(디렉토리는 재귀).
  Future<void> copyPath(String src, String dst) async {
    final type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.directory) {
      await _copyDir(Directory(src), Directory(dst));
    } else {
      await File(dst).create(recursive: true);
      await File(src).copy(dst);
    }
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = p.basename(e.path);
      final target = p.join(dst.path, name);
      if (e is Directory) {
        await _copyDir(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }

  /// 프로젝트 디렉토리를 재귀 감시한다(실시간 트리 갱신용).
  /// 권한/플랫폼 문제로 실패할 수 있으므로 호출부에서 오류를 처리한다.
  Stream<FileSystemEvent> watch(String root) =>
      Directory(root).watch(recursive: true);
}
