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
  static const String _baseScript = 'collabo_tools.py';

  /// 기본 모듈을 추출하고 그 스크립트 경로를 반환한다.
  static Future<String> extractBaseModule() async {
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
    return p.join(destRoot.path, _baseScript);
  }
}
