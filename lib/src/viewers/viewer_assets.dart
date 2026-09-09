import 'dart:convert';
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

  /// 여러 파일로 된 뷰어(폴더)의 매니페스트 파일명.
  ///
  /// ```json
  /// { "entry": "main.js", "scripts": ["lib/dep.js"], "assets": ["mod.wasm"] }
  /// ```
  /// `scripts` → `entry` 순서로 로드된다. `assets`(예: .wasm)는 로드하지 않고 그냥
  /// 같이 복사되며, 플러그인이 `collaboViewers.asset(id, name)` 으로 바이트를 읽는다
  /// (웹은 `file://` 에서 fetch 를 못 하므로 네이티브가 읽어 준다).
  static const String manifestName = 'viewer.json';

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
      try {
        final type = await FileSystemEntity.type(s.path, followLinks: true);
        if (type == FileSystemEntityType.directory) {
          // 여러 파일로 된 뷰어(폴더 + viewer.json).
          final name = s.stagedBaseName;
          if (keep.contains(name)) continue;
          final staged = await _stagePackage(s, Directory(p.join(dir.path, name)));
          if (staged.isEmpty) continue;
          keep.add(name);
          urls.addAll([for (final rel in staged) '$_urlPrefix$name/$rel']);
        } else if (type == FileSystemEntityType.file) {
          final name = s.stagedName;
          if (keep.contains(name)) continue; // 같은 파일이 두 번 등록된 경우.
          await File(s.path).copy(p.join(dir.path, name));
          keep.add(name);
          urls.add('$_urlPrefix$name');
        }
      } catch (_) {
        continue; // 없는 경로/권한/락 — 그 뷰어만 빠진다(설정에 경고가 뜬다).
      }
    }

    // 잔재 정리: 이번에 스테이징하지 않은 것은 더 이상 등록된 뷰어가 아니다.
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (keep.contains(p.basename(e.path))) continue;
        try {
          await e.delete(recursive: e is Directory);
        } catch (_) {}
      }
    } catch (_) {}

    return urls;
  }

  /// 폴더 뷰어 하나를 통째로 복사하고, **로드할 순서대로** 상대 경로를 돌려준다.
  /// 매니페스트가 없거나 entry 를 못 찾으면 빈 목록(그 뷰어는 빠진다).
  static Future<List<String>> _stagePackage(
      ViewerSource source, Directory dest) async {
    final src = Directory(source.path);
    final manifestFile = File(p.join(src.path, manifestName));
    if (!await manifestFile.exists()) return const [];

    List<String> scripts;
    String entry;
    try {
      final json = jsonDecode(await manifestFile.readAsString());
      if (json is! Map) return const [];
      entry = (json['entry'] as String?) ?? 'main.js';
      scripts = [
        for (final s in (json['scripts'] as List? ?? const []))
          if (s is String) s,
      ];
    } catch (_) {
      return const []; // 깨진 매니페스트 — 조용히 건너뛴다(설정에서 소스를 볼 수 있다).
    }
    if (!await File(p.join(src.path, entry)).exists()) return const [];

    // 폴더를 그대로 복사한다(assets/wasm 포함). 매번 새로 만들어 지워진 파일이
    // 남지 않게 한다.
    try {
      if (await dest.exists()) await dest.delete(recursive: true);
      await _copyTree(src, dest);
    } catch (_) {
      return const [];
    }
    // scripts → entry 순서. 웹은 이 순서대로 **차례로** 로드한다.
    return [...scripts, entry];
  }

  static Future<void> _copyTree(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final e in src.list(followLinks: false)) {
      final name = p.basename(e.path);
      final target = p.join(dest.path, name);
      if (e is Directory) {
        await _copyTree(e, Directory(target));
      } else if (e is File) {
        await e.copy(target);
      }
    }
  }
}
