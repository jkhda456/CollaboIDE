import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 파일 뷰어 모드.
enum FileViewMode { text, hex, md }

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
  });

  final String path;
  final FileViewMode mode;
  final String content;

  /// 파일 전체 크기(바이트).
  final int size;

  /// 대용량으로 인해 일부만 읽었는지.
  final bool truncated;

  Map<String, Object?> toJson() => {
        'path': path,
        'mode': mode.name,
        'content': content,
        'size': size,
        'truncated': truncated,
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

    if (resolved == FileViewMode.hex) {
      final bytes = await _readPrefix(file, maxHexBytes);
      return FileContent(
        path: filePath,
        mode: resolved,
        content: _hexDump(bytes),
        size: size,
        truncated: size > bytes.length,
      );
    }

    // text / md: 앞부분 바이트를 UTF-8(불량 허용)로 디코드.
    final bytes = await _readPrefix(file, maxTextBytes);
    return FileContent(
      path: filePath,
      mode: resolved,
      content: utf8.decode(bytes, allowMalformed: true),
      size: size,
      truncated: size > bytes.length,
    );
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

  /// 표준 hex 덤프(오프셋 + 16바이트 + ASCII).
  static String _hexDump(List<int> bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i += 16) {
      sb.write(i.toRadixString(16).padLeft(8, '0'));
      sb.write('  ');
      final ascii = StringBuffer();
      for (var j = 0; j < 16; j++) {
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
      sb.write('\n');
    }
    return sb.toString();
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
