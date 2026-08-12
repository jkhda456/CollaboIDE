import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;

import '../webview/web_assets.dart';
import 'viewer_source.dart';

/// 앱에 담겨 오는 예제 뷰어 하나(기본으로 붙지 않는다).
///
/// 사용자가 직접 만든 뷰어와 **똑같이 취급**되도록, 추가할 때 파일을 꺼내
/// [ViewerSource] 로 등록한다(설정 → 뷰어). 새 뷰어를 만들 출발점이기도 하다.
class ViewerExample {
  const ViewerExample({required this.assetKey, required this.fileName});

  /// 에셋 키(`assets/web/viewers/examples/markdown-editor.js`).
  final String assetKey;

  /// 파일명(`markdown-editor.js`) — 목록에 그대로 보여 준다.
  final String fileName;
}

/// 사용자 뷰어 JS 를 웹뷰가 읽을 수 있는 곳으로 옮겨 주는 계층.
class ViewerAssets {
  /// 웹 루트 안에서 사용자 뷰어를 두는 하위 폴더(`<appSupport>/web/viewers/user`).
  /// 번들 뷰어(`viewers/*.js`)와 섞이지 않게 따로 둔다 — 잔재 정리가 이 폴더
  /// 전체를 기준으로 돌기 때문이다.
  static const String _userSubdir = 'user';

  /// index.html 기준 상대 URL 접두사.
  static const String _urlPrefix = './viewers/$_userSubdir/';

  /// 앱에 담긴 예제 뷰어들의 에셋 접두사.
  static const String _examplesAssetPrefix = 'assets/web/viewers/examples/';

  /// 앱에 담긴 예제 뷰어 목록(없으면 빈 목록).
  static Future<List<ViewerExample>> examples() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final keys = manifest
          .listAssets()
          .where((k) => k.startsWith(_examplesAssetPrefix) && k.endsWith('.js'))
          .toList()
        ..sort();
      return [
        for (final k in keys)
          ViewerExample(assetKey: k, fileName: p.basename(k)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 예제를 디스크로 꺼내고 그 경로를 돌려준다(추가할 때 1회).
  ///
  /// **웹 루트 안**(`<web>/viewers/examples/`)에 둔다 — 앱 밖에 두면 macOS 샌드박스
  /// 에서 다음 실행 때 다시 못 읽는다([sync] 주석의 읽기 권한 이야기와 같은 이유).
  /// `WebAssets` 도 매 실행 같은 위치로 추출하므로 파일이 사라지지 않는다.
  static Future<String> materialize(ViewerExample example) async {
    final root = await WebAssets.webRoot();
    final dir = Directory(p.join(root.path, 'viewers', 'examples'));
    await dir.create(recursive: true);
    final dest = File(p.join(dir.path, example.fileName));
    final text = await rootBundle.loadString(example.assetKey);
    await dest.writeAsString(text, flush: true);
    return dest.path;
  }

  /// [sources] 를 웹 루트로 복사하고, 웹에 넘길 상대 URL 목록을 돌려준다.
  /// 목록에 없는 예전 파일은 지운다(설정에서 제거한 뷰어가 되살아나지 않게).
  ///
  /// **왜 원본 경로를 그대로 `<script src>` 로 쓰지 않는가**: 웹은 `file://` 로
  /// 로드되는데, macOS(`webview_flutter` → WKWebView)는 `loadFile` 시 **그 파일의
  /// 디렉토리로 읽기 권한을 한정**한다. 즉 웹 루트 밖의 `file://` 서브리소스는
  /// 조용히 차단된다(Windows/WebView2 는 로드된다 — 플랫폼별로 갈린다).
  /// 그래서 항상 웹 루트 안으로 복사해 두고, 상대 경로로 얹는다.
  ///
  /// 존재하지 않는(이동·삭제된) 원본은 건너뛴다. 설정 화면이 같은 조건으로
  /// 경고를 표시하므로 사용자는 왜 안 붙는지 알 수 있다.
  static Future<List<String>> sync(List<ViewerSource> sources) async {
    final root = await WebAssets.webRoot();
    final dir = Directory(p.join(root.path, 'viewers', _userSubdir));
    await dir.create(recursive: true);

    final keep = <String>{};
    final urls = <String>[];
    for (final s in sources) {
      if (s.path.isEmpty) continue;
      final name = s.stagedName;
      if (keep.contains(name)) continue; // 같은 파일이 두 번 등록된 경우.
      try {
        if (!await File(s.path).exists()) continue;
        await File(s.path).copy(p.join(dir.path, name));
      } catch (_) {
        continue; // 권한/락 등으로 복사 실패 — 그 뷰어만 빠진다.
      }
      keep.add(name);
      urls.add('$_urlPrefix$name');
    }

    // 잔재 정리: 이번에 스테이징하지 않은 파일은 더 이상 등록된 뷰어가 아니다.
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && !keep.contains(p.basename(e.path))) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}

    return urls;
  }
}
