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

  /// 웹 리소스가 펼쳐지는 루트(`<appSupport>/web`).
  ///
  /// 사용자 뷰어 스테이징(`ViewerAssets.sync`)도 **이 안**에 둔다 — macOS 웹뷰가
  /// 읽을 수 있는 범위가 여기로 한정되기 때문이다(이유는 그쪽 주석 참고).
  static Future<Directory> webRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'web'));
  }

  /// 웹 에셋을 추출하고 진입점 `index.html`(대화)의 `file://` URL 을 반환한다.
  static Future<String> extractAndGetIndexUrl() => pageUrl('index.html');

  /// 웹 에셋을 추출하고 [page](`index.html` 대화 · `viewer.html` 파일 뷰어)의 URL.
  static Future<String> pageUrl(String page) async {
    final destRoot = await _extract();
    return Uri.file(p.join(destRoot.path, page)).toString();
  }

  /// 추출은 **앱 실행마다 한 번**이다. 프로젝트마다 웹뷰가 둘(대화 + 뷰어)이라,
  /// 패널이 뜰 때마다 전부 다시 쓰면 같은 파일을 몇 번이고 덮어쓴다.
  /// 실패하면 다음 호출이 다시 시도한다.
  static Future<Directory>? _extracting;

  static Future<Directory> _extract() {
    final running = _extracting;
    if (running != null) return running;
    final f = _extractAll();
    _extracting = f;
    f.catchError((Object _) {
      _extracting = null;
      return Directory('');
    });
    return f;
  }

  static Future<Directory> _extractAll() async {
    final destRoot = await webRoot();
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
    return destRoot;
  }
}
