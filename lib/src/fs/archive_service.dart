import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'hex_dump.dart';

/// 압축 파일 안을 들여다보는 네이티브 API.
///
/// **순수 Dart 로만 구현한다.** 이 앱은 macOS/iOS/Windows/Linux 를 함께 노리므로,
/// 외부 실행 파일(`7z`, `unzip` …)에 위임하면 안 된다 — iOS 는 프로세스 실행 자체가
/// 불가능하고, 데스크톱도 설치를 보장할 수 없다. 그래서 어디서나 같은 결과를 주는
/// `package:archive`(pure Dart) 만 쓴다.
///
/// 지원 범위는 [ArchiveFormat] 이 전부다. 7z/rar 처럼 여기 없는 형식은
/// **지원하지 않는다고 분명히 알려 준다**(조용히 빈 목록을 주지 않는다).
///
/// 큰 파일 대비:
///  - 해독은 **별도 아이솔레이트**에서 한다([Isolate.run]) → UI 가 멈추지 않는다.
///  - [maxArchiveBytes] 를 넘는 파일은 열지 않고 이유를 돌려준다.
///  - 항목이 [maxEntries] 를 넘으면 잘라서 주고 `truncated` 로 알린다.
///  - 같은 파일(경로+크기+수정시각)에 대한 결과는 [_cache] 에 담아 재사용한다.
enum ArchiveFormat {
  zip,
  tar,
  tarGz,
  tarBz2,
  tarXz,
  gz,
  bz2,
  xz,
  zlib,
  unsupported,
}

/// 압축 파일 안의 항목 하나.
class ArchiveEntry {
  const ArchiveEntry({
    required this.name,
    required this.size,
    required this.isDir,
    this.modified,
  });

  /// 압축 안에서의 경로(`docs/readme.md`).
  final String name;

  /// 원본 크기(바이트). 알 수 없으면 -1.
  final int size;
  final bool isDir;

  /// 수정 시각(epoch ms). 없으면 null.
  final int? modified;

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'dir': isDir,
        if (modified != null) 'mtime': modified,
      };
}

/// 목록 결과. 실패해도 [error] 로 이유를 담아 돌려준다(예외를 던지지 않는다).
class ArchiveListing {
  const ArchiveListing({
    required this.format,
    required this.entries,
    this.total = 0,
    this.truncated = false,
    this.error,
  });

  final ArchiveFormat format;
  final List<ArchiveEntry> entries;

  /// 실제 항목 수(잘리기 전).
  final int total;
  final bool truncated;

  /// 열지 못한 이유(지원하지 않는 형식/너무 큼/깨진 파일). 성공이면 null.
  final String? error;

  Map<String, Object?> toJson() => {
        'format': format.name,
        'entries': [for (final e in entries) e.toJson()],
        'total': total,
        'truncated': truncated,
        if (error != null) 'error': error,
      };

  factory ArchiveListing.fromJson(Map<String, Object?> json) => ArchiveListing(
        format: ArchiveFormat.values.firstWhere(
          (f) => f.name == json['format'],
          orElse: () => ArchiveFormat.unsupported,
        ),
        entries: [
          for (final e in (json['entries'] as List? ?? const []))
            if (e is Map)
              ArchiveEntry(
                name: (e['name'] as String?) ?? '',
                size: (e['size'] as num?)?.toInt() ?? -1,
                isDir: e['dir'] == true,
                modified: (e['mtime'] as num?)?.toInt(),
              ),
        ],
        total: (json['total'] as num?)?.toInt() ?? 0,
        truncated: json['truncated'] == true,
        error: json['error'] as String?,
      );
}

/// 압축 안의 파일 하나를 읽은 결과.
///
/// 파일 뷰어와 같은 규칙으로 준다 — 텍스트로 보이면 `text`, 아니면 `hex` 덤프.
/// 상한을 넘으면 앞부분만 담고 [truncated] 를 세운다.
class ArchiveEntryData {
  const ArchiveEntryData({
    required this.name,
    required this.mode,
    required this.content,
    required this.size,
    this.truncated = false,
    this.error,
  });

  final String name;

  /// 'text' | 'hex'. 실패면 빈 문자열.
  final String mode;
  final String content;

  /// 항목의 원본 크기(바이트).
  final int size;
  final bool truncated;
  final String? error;

  Map<String, Object?> toJson() => {
        'name': name,
        'mode': mode,
        'content': content,
        'size': size,
        'truncated': truncated,
        if (error != null) 'error': error,
      };

  factory ArchiveEntryData.fromJson(Map<String, Object?> json) =>
      ArchiveEntryData(
        name: (json['name'] as String?) ?? '',
        mode: (json['mode'] as String?) ?? '',
        content: (json['content'] as String?) ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        truncated: json['truncated'] == true,
        error: json['error'] as String?,
      );
}

class ArchiveService {
  /// 통째로 메모리에 올려 해독하는 최대 크기(128MB).
  ///
  /// `package:archive` 의 스트리밍 입력을 쓰면 더 키울 수 있지만, 아이솔레이트로
  /// 넘기기 쉬운 단순한 경로(바이트 읽기)를 택했다. 이 상한을 넘으면 열지 않고
  /// 이유를 돌려준다 — 몇 GB 짜리를 붙잡고 앱이 굳는 것보다 낫다.
  static const int maxArchiveBytes = 128 << 20;

  /// 목록에 담는 최대 항목 수(그 이상은 잘라서 `truncated`).
  static const int maxEntries = 5000;

  /// 항목 하나를 미리 볼 때 텍스트로 담는 최대 바이트(1MB — 파일 뷰어와 같다).
  static const int maxEntryTextBytes = 1 << 20;

  /// 항목 하나를 hex 로 담는 최대 바이트(256KB — 파일 뷰어와 같다).
  static const int maxEntryHexBytes = 1 << 18;

  /// 확장자 → 형식. 앞이 더 구체적인 것부터 본다(`.tar.gz` > `.gz`).
  static const Map<String, ArchiveFormat> _byExtension = {
    '.tar.gz': ArchiveFormat.tarGz,
    '.tgz': ArchiveFormat.tarGz,
    '.tar.bz2': ArchiveFormat.tarBz2,
    '.tbz': ArchiveFormat.tarBz2,
    '.tbz2': ArchiveFormat.tarBz2,
    '.tar.xz': ArchiveFormat.tarXz,
    '.txz': ArchiveFormat.tarXz,
    '.tar': ArchiveFormat.tar,
    '.gz': ArchiveFormat.gz,
    '.bz2': ArchiveFormat.bz2,
    '.xz': ArchiveFormat.xz,
    '.zz': ArchiveFormat.zlib,
    // zip 컨테이너를 쓰는 형식들(내용 구조만 다르다).
    '.zip': ArchiveFormat.zip,
    '.jar': ArchiveFormat.zip,
    '.war': ArchiveFormat.zip,
    '.apk': ArchiveFormat.zip,
    '.aab': ArchiveFormat.zip,
    '.ipa': ArchiveFormat.zip,
    '.whl': ArchiveFormat.zip,
    '.egg': ArchiveFormat.zip,
    '.xpi': ArchiveFormat.zip,
    '.vsix': ArchiveFormat.zip,
    '.crx': ArchiveFormat.zip,
    '.epub': ArchiveFormat.zip,
    '.odt': ArchiveFormat.zip,
    '.ods': ArchiveFormat.zip,
    '.odp': ArchiveFormat.zip,
    '.docx': ArchiveFormat.zip,
    '.xlsx': ArchiveFormat.zip,
    '.pptx': ArchiveFormat.zip,
  };

  /// 경로만으로 형식을 추정한다(대소문자 무시, 복합 확장자 우선).
  ///
  /// 웹 뷰어는 마지막 확장자 한 조각(`.gz`)으로 담당 여부를 정하고, 그게 tarball
  /// 인지(`.tar.gz`)는 여기서 판정한다 — 그래서 양쪽 목록이 정확히 같지는 않다.
  static ArchiveFormat formatForPath(String path) {
    final name = p.basename(path).toLowerCase();
    // 복합 확장자(.tar.gz)를 먼저 맞춘다.
    for (final e in _byExtension.entries) {
      if (e.key.contains('.', 1) && name.endsWith(e.key)) return e.value;
    }
    final ext = p.extension(name);
    return _byExtension[ext] ?? ArchiveFormat.unsupported;
  }

  /// 압축 파일인지(뷰어 없이도 판단이 필요한 곳에서 쓴다).
  static bool isArchive(String path) =>
      formatForPath(path) != ArchiveFormat.unsupported;

  /// 경로+크기+수정시각 → 결과. 같은 파일을 다시 열 때 해독을 건너뛴다.
  final Map<String, ArchiveListing> _cache = {};

  /// 압축 파일의 항목을 나열한다. 실패는 예외가 아니라 [ArchiveListing.error] 로.
  Future<ArchiveListing> list(String path) async {
    final file = File(path);
    final int size;
    final DateTime stamp;
    try {
      final stat = await file.stat();
      size = stat.size;
      stamp = stat.modified;
    } catch (e) {
      return ArchiveListing(
          format: ArchiveFormat.unsupported, entries: const [], error: '$e');
    }

    final key = '$path|$size|${stamp.millisecondsSinceEpoch}';
    final hit = _cache[key];
    if (hit != null) return hit;

    final format = formatForPath(path);
    if (format == ArchiveFormat.unsupported) {
      return _remember(
          key,
          ArchiveListing(
            format: format,
            entries: const [],
            error: 'Unsupported archive format: ${p.extension(path)}',
          ));
    }
    if (size > maxArchiveBytes) {
      return _remember(
          key,
          ArchiveListing(
            format: format,
            entries: const [],
            error: 'Archive is too large to open '
                '(${size >> 20}MB > ${maxArchiveBytes >> 20}MB).',
          ));
    }

    // 해독은 CPU 를 오래 쓴다 → 아이솔레이트로 넘겨 UI 를 막지 않는다.
    // 주고받는 값은 아이솔레이트 경계를 넘기 쉬운 문자열(JSON)로 고정한다.
    try {
      final json = await Isolate.run(() => _listInIsolate(path, format.name));
      final listing = ArchiveListing.fromJson(
          jsonDecode(json) as Map<String, Object?>);
      return _remember(key, listing);
    } catch (e) {
      return _remember(
          key, ArchiveListing(format: format, entries: const [], error: '$e'));
    }
  }

  /// 압축 안의 파일 하나를 읽는다(뷰어의 미리보기).
  ///
  /// 목록과 마찬가지로 아이솔레이트에서 해독하고, 실패는 [ArchiveEntryData.error]
  /// 로 돌려준다. **클릭 한 번마다 압축을 다시 여는 비용**이 있으므로 최근 결과를
  /// 조금 캐시한다(같은 항목을 오가며 보는 게 흔하다).
  Future<ArchiveEntryData> readEntry(String path, String entryName) async {
    final int size;
    final DateTime stamp;
    try {
      final stat = await File(path).stat();
      size = stat.size;
      stamp = stat.modified;
    } catch (e) {
      return ArchiveEntryData(
          name: entryName, mode: '', content: '', size: 0, error: '$e');
    }
    if (size > maxArchiveBytes) {
      return ArchiveEntryData(
        name: entryName,
        mode: '',
        content: '',
        size: 0,
        error: 'Archive is too large to open '
            '(${size >> 20}MB > ${maxArchiveBytes >> 20}MB).',
      );
    }

    final key = '$path|$size|${stamp.millisecondsSinceEpoch}|$entryName';
    final hit = _entryCache[key];
    if (hit != null) return hit;

    final format = formatForPath(path);
    try {
      final json = await Isolate.run(
          () => _readEntryInIsolate(path, format.name, entryName));
      final data =
          ArchiveEntryData.fromJson(jsonDecode(json) as Map<String, Object?>);
      // 큰 내용을 오래 붙들지 않도록 몇 건만 유지한다.
      if (_entryCache.length > 8) _entryCache.clear();
      _entryCache[key] = data;
      return data;
    } catch (e) {
      return ArchiveEntryData(
          name: entryName, mode: '', content: '', size: 0, error: '$e');
    }
  }

  final Map<String, ArchiveEntryData> _entryCache = {};

  ArchiveListing _remember(String key, ArchiveListing listing) {
    // 오류 결과도 캐시한다(같은 파일에 대해 무거운 실패를 반복하지 않게).
    // 파일이 바뀌면 키(크기·수정시각)가 달라져 자동으로 무효화된다.
    if (_cache.length > 32) _cache.clear();
    _cache[key] = listing;
    return listing;
  }

  /// 캐시를 비운다(설정 변경 등으로 강제 재해독이 필요할 때).
  void clearCache() {
    _cache.clear();
    _entryCache.clear();
  }
}

/// 압축 안의 파일 하나를 읽어 JSON 으로 돌려준다(아이솔레이트).
String _readEntryInIsolate(String path, String formatName, String entryName) {
  ArchiveEntryData fail(String message) => ArchiveEntryData(
      name: entryName, mode: '', content: '', size: 0, error: message);

  final format = ArchiveFormat.values.firstWhere((f) => f.name == formatName,
      orElse: () => ArchiveFormat.unsupported);
  try {
    final bytes = File(path).readAsBytesSync();
    final Archive archive;
    switch (format) {
      case ArchiveFormat.zip:
        archive = ZipDecoder().decodeBytes(bytes);
      case ArchiveFormat.tar:
        archive = TarDecoder().decodeBytes(bytes);
      case ArchiveFormat.tarGz:
        archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
      case ArchiveFormat.tarBz2:
        archive = TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
      case ArchiveFormat.tarXz:
        archive = TarDecoder().decodeBytes(XZDecoder().decodeBytes(bytes));
      case ArchiveFormat.gz:
      case ArchiveFormat.bz2:
      case ArchiveFormat.xz:
      case ArchiveFormat.zlib:
        // 단일 파일 압축: 압축을 풀면 그 자체가 내용이다(안이 tar 면 그 tar 에서 찾는다).
        final inner = switch (format) {
          ArchiveFormat.gz => GZipDecoder().decodeBytes(bytes),
          ArchiveFormat.bz2 => BZip2Decoder().decodeBytes(bytes),
          ArchiveFormat.xz => XZDecoder().decodeBytes(bytes),
          _ => ZLibDecoder().decodeBytes(bytes),
        };
        Archive? tar;
        try {
          tar = TarDecoder().decodeBytes(inner);
        } catch (_) {
          tar = null;
        }
        if (tar == null || tar.isEmpty) {
          return jsonEncode(_entryDataFromBytes(entryName, inner).toJson());
        }
        archive = tar;
      case ArchiveFormat.unsupported:
        return jsonEncode(fail('Unsupported archive format.').toJson());
    }

    for (final f in archive) {
      if (f.name != entryName) continue;
      if (!f.isFile) return jsonEncode(fail('Not a file: $entryName').toJson());
      final content = _entryBytes(f);
      if (content == null) {
        return jsonEncode(fail('Could not read the entry.').toJson());
      }
      return jsonEncode(_entryDataFromBytes(entryName, content).toJson());
    }
    return jsonEncode(fail('No such entry: $entryName').toJson());
  } catch (e) {
    return jsonEncode(fail('Could not read the entry: $e').toJson());
  }
}

/// [ArchiveFile] 의 바이트를 꺼낸다.
///
/// **`package:archive` 버전에 따라 이름이 다르다** — 3.x 는 `content`,
/// 4.x 는 `readBytes()` 를 쓴다. 어느 쪽이든 되게 `dynamic` 으로 둘 다 시도한다
/// (여기만 이렇게 한다. 디코더 쪽은 이름이 바뀌면 컴파일에서 바로 걸리는 편이 낫다).
List<int>? _entryBytes(ArchiveFile file) {
  final dynamic f = file;
  try {
    final r = f.readBytes();
    if (r is List<int>) return r;
  } catch (_) {}
  try {
    final r = f.content;
    if (r is List<int>) return r;
  } catch (_) {}
  return null;
}

/// 바이트 → 미리보기(텍스트로 읽히면 text, 아니면 hex). 상한을 넘으면 앞부분만.
ArchiveEntryData _entryDataFromBytes(String name, List<int> bytes) {
  final size = bytes.length;
  // 앞부분에 NUL 이 있으면 바이너리로 본다(파일 뷰어의 판정과 같은 취지).
  final probe = bytes.take(4096);
  final binary = probe.contains(0);
  if (binary) {
    final head = bytes.take(ArchiveService.maxEntryHexBytes).toList();
    return ArchiveEntryData(
      name: name,
      mode: 'hex',
      content: hexDump(head),
      size: size,
      truncated: size > head.length,
    );
  }
  final head = bytes.take(ArchiveService.maxEntryTextBytes).toList();
  return ArchiveEntryData(
    name: name,
    mode: 'text',
    content: utf8.decode(head, allowMalformed: true),
    size: size,
    truncated: size > head.length,
  );
}

/// 아이솔레이트에서 도는 실제 해독. **최상위 함수여야 한다**(클로저 캡처 금지).
///
/// 결과를 JSON 문자열로 돌려주므로, 여기서 나가는 값에는 `package:archive` 객체가
/// 섞이지 않는다.
String _listInIsolate(String path, String formatName) {
  final format = ArchiveFormat.values.firstWhere((f) => f.name == formatName,
      orElse: () => ArchiveFormat.unsupported);
  try {
    final bytes = File(path).readAsBytesSync();
    final entries = <ArchiveEntry>[];
    var total = 0;

    void addAll(Archive archive) {
      total = archive.length;
      for (final f in archive) {
        if (entries.length >= ArchiveService.maxEntries) break;
        entries.add(ArchiveEntry(
          name: f.name,
          size: f.size,
          isDir: !f.isFile,
          // archive 는 초 단위 epoch 를 준다(0 이면 정보 없음).
          modified: f.lastModTime > 0 ? f.lastModTime * 1000 : null,
        ));
      }
    }

    // ── package:archive 를 부르는 곳은 여기뿐이다 ─────────────────────────
    // 패키지 API 가 바뀌면 이 블록만 고치면 된다.
    switch (format) {
      case ArchiveFormat.zip:
        addAll(ZipDecoder().decodeBytes(bytes));
      case ArchiveFormat.tar:
        addAll(TarDecoder().decodeBytes(bytes));
      case ArchiveFormat.tarGz:
        addAll(TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes)));
      case ArchiveFormat.tarBz2:
        addAll(TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes)));
      case ArchiveFormat.tarXz:
        addAll(TarDecoder().decodeBytes(XZDecoder().decodeBytes(bytes)));
      case ArchiveFormat.gz:
      case ArchiveFormat.bz2:
      case ArchiveFormat.xz:
      case ArchiveFormat.zlib:
        // 단일 파일 압축: 담긴 파일 하나를 항목으로 보여 준다. 안이 tar 면
        // (확장자만 .gz 인 tarball) tar 로 한 번 더 풀어 목록을 낸다.
        final inner = switch (format) {
          ArchiveFormat.gz => GZipDecoder().decodeBytes(bytes),
          ArchiveFormat.bz2 => BZip2Decoder().decodeBytes(bytes),
          ArchiveFormat.xz => XZDecoder().decodeBytes(bytes),
          _ => ZLibDecoder().decodeBytes(bytes),
        };
        Archive? tar;
        try {
          tar = TarDecoder().decodeBytes(inner);
        } catch (_) {
          tar = null;
        }
        if (tar != null && tar.isNotEmpty) {
          addAll(tar);
        } else {
          // 압축을 풀면 나오는 이름은 확장자를 뗀 것으로 본다.
          final base = p.basenameWithoutExtension(path);
          entries.add(ArchiveEntry(name: base, size: inner.length, isDir: false));
          total = 1;
        }
      case ArchiveFormat.unsupported:
        return jsonEncode(ArchiveListing(
          format: format,
          entries: const [],
          error: 'Unsupported archive format.',
        ).toJson());
    }

    return jsonEncode(ArchiveListing(
      format: format,
      entries: entries,
      total: total,
      truncated: total > entries.length,
    ).toJson());
  } catch (e) {
    return jsonEncode(ArchiveListing(
      format: format,
      entries: const [],
      error: 'Could not read the archive: $e',
    ).toJson());
  }
}
