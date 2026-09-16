import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 번들된 기본 Python 도구 모듈(`assets/python/**`)을 디스크로 추출한다.
///
/// 포터블 Python 이 실행할 수 있도록 `<appSupport>/python_modules/` 아래에 펼친다.
/// 기본 모듈은 고정이며 앱과 함께 임베딩된다.
class ToolAssets {
  static const String _assetPrefix = 'assets/python/';

  /// 고정 기본 모듈들(도구 계약을 따르는 `describe`/`call` 스크립트).
  ///
  /// **첫 번째가 대표**다 — 어댑터 디렉토리(`toolAdaptersDir`)와 준비 상태 판정이
  /// 이 경로를 기준으로 한다. 이름이 겹치는 도구는 앞선 모듈이 이긴다.
  static const List<String> baseScripts = [
    'collabo_tools.py', // 파일·명령·권한 등 기본 작업
    'collabo_docs.py', // docx/xlsx/pptx 문서 읽기·편집
    'collabo_web.py', // 웹 검색·페이지 읽기(네이티브 브라우저 탭을 부린다)
    'collabo_term.py', // 터미널 세션(PTY) — 열기·읽기·입력·검색
  ];

  /// 기본 모듈을 추출하고 대표 스크립트 경로를 반환한다.
  static Future<String> extractBaseModule() async =>
      (await extractBaseModules()).first;

  /// 번들된 Python 에셋을 모두 펼치고, 기본 모듈들의 경로를 순서대로 반환한다.
  static Future<List<String>> extractBaseModules() async {
    final support = await getApplicationSupportDirectory();
    final destRoot = Directory(p.join(support.path, 'python_modules'));

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys = manifest.listAssets().where((k) => k.startsWith(_assetPrefix));
    for (final key in keys) {
      final rel = key.substring(_assetPrefix.length);
      final dest = File(p.join(destRoot.path, rel));
      await dest.create(recursive: true);
      final data = await rootBundle.load(key);
      await dest.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    return [for (final s in baseScripts) p.join(destRoot.path, s)];
  }
}
