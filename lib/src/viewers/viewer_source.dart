import 'dart:convert';

import 'package:path/path.dart' as p;

/// 사용자가 추가한 파일 뷰어(익스텐션) JS 파일. 메인 DB 에 JSON 으로 저장된다.
///
/// 뷰어는 웹(`assets/web/viewers/`)의 플러그인 계약을 따르는 스크립트 하나다
/// (`collaboViewers.register({...})`). 도구 소스([ToolSource])와 같은 방식으로
/// **경로만 저장**하고, 실제 로드는 웹뷰가 한다.
class ViewerSource {
  const ViewerSource({required this.path, this.label = ''});

  /// 사용자 JS 파일의 원본 경로. 이 파일이 웹 루트로 복사되어 로드된다
  /// (복사하는 이유는 `viewer_assets.dart` 참고).
  final String path;

  /// 표시 이름(비면 파일명).
  final String label;

  /// 중복 판정 키. Windows 는 대소문자를 구분하지 않으므로 정규화해서 비교한다.
  String get id => p.canonicalize(path);

  String get displayName => label.isNotEmpty ? label : p.basename(path);

  /// 웹 루트에 복사될 때 쓸 파일명.
  ///
  /// 서로 다른 폴더의 같은 이름(`image.js` 두 개)을 구분해야 하므로 경로 해시를
  /// 붙인다. **같은 경로면 항상 같은 이름**이어야 한다 — 스테이징은 이 이름으로
  /// 잔재(설정에서 제거된 뷰어)를 판별하기 때문이다.
  String get stagedName {
    final base = p.basenameWithoutExtension(path);
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final tag = _fnv1a(id).toRadixString(16).padLeft(8, '0');
    return '${safe.isEmpty ? 'viewer' : safe}_$tag.js';
  }

  /// FNV-1a(32비트). 경로 → 짧은 안정적 태그. 암호학적 용도가 아니다
  /// (충돌해도 파일명이 겹치는 정도이며, 한글 경로도 UTF-8 바이트로 다룬다).
  static int _fnv1a(String s) {
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  Map<String, Object?> toJson() => {'path': path, 'label': label};

  factory ViewerSource.fromJson(Map<String, Object?> json) => ViewerSource(
        path: (json['path'] as String?) ?? '',
        label: (json['label'] as String?) ?? '',
      );

  /// 문자열(경로)만 저장된 형태에서의 이주.
  factory ViewerSource.legacy(String path) => ViewerSource(path: path);
}
