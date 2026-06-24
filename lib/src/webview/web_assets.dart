import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 임베드된 웹 리소스(`assets/web/**`)를 디스크로 추출한다.
///
/// `webview_windows` 가 상대 경로(예: `./vendor/bootstrap.min.css`)를 해석할 수
/// 있도록, 에셋을 `<appSupport>/web/` 아래에 펼친 뒤 그 `index.html` 을
/// `file://` URL 로 로드한다. 모든 리소스가 로컬이라 오프라인에서도 동작한다.
class WebAssets {
  static const String _assetPrefix = 'assets/web/';

  /// 웹 에셋을 추출하고 진입점 `index.html` 의 `file://` URL 을 반환한다.
  static Future<String> extractAndGetIndexUrl() async {
    final support = await getApplicationSupportDirectory();
    final destRoot = Directory(p.join(support.path, 'web'));

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final keys =
        manifest.listAssets().where((k) => k.startsWith(_assetPrefix));

    for (final key in keys) {
      final rel = key.substring(_assetPrefix.length);
      final dest = File(p.join(destRoot.path, rel));
      await dest.create(recursive: true);
      final data = await rootBundle.load(key);
      await dest.writeAsBytes(data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      ));
    }

    final indexPath = p.join(destRoot.path, 'index.html');
    return Uri.file(indexPath).toString();
  }
}
