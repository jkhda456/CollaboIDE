import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 플랫폼마다 되는 것·안 되는 것.
///
/// **iOS·iPadOS** 는 앱 샌드박스 때문에 데스크톱과 다르다:
///  - 하위 프로세스·JIT 금지 → collaboCore 샌드박스(도구 실행)가 없다([ProjectSandbox] 쪽은
///    런타임을 못 찾은 것으로 처리된다 — `WorkspaceController._locateSandboxRuntime`).
///  - 임의 폴더 접근·폴더 선택 대화상자 없음 → 프로젝트는 앱 `Documents/` 안에 둔다
///    ('파일' 앱 > 나의 iPhone/iPad > Collabo IDE 에서 보인다 — Info.plist `UIFileSharingEnabled`).
///  - OS 기본 프로그램·탐색기로 열기 없음.
///  - 앱을 업데이트/재설치하면 컨테이너 경로(UUID)가 바뀐다 → 저장된 절대 경로를 [remap] 한다.
abstract final class PlatformFeatures {
  static bool get isIOS => !kIsWeb && Platform.isIOS;

  /// OS 폴더 선택 대화상자(file_selector `getDirectoryPath`)가 있는가. 없으면 앱 안 선택기를 쓴다.
  static bool get hasSystemFolderPicker => !isIOS;

  /// OS 기본 프로그램·탐색기로 열 수 있는가.
  static bool get canOpenExternally => !isIOS;

  static String? _documentsDir;

  /// 앱 시작 때 한 번(`main`). iOS 에서 Documents 경로를 캐시하고 기본 프로젝트 폴더를 만든다.
  static Future<void> init() async {
    if (!isIOS) return;
    _documentsDir = (await getApplicationDocumentsDirectory()).path;
    try {
      await Directory(projectsDir!).create(recursive: true);
    } catch (_) {}
  }

  /// iOS 앱 Documents 경로(그 밖의 플랫폼·초기화 전에는 null).
  static String? get documentsDir => _documentsDir;

  /// iOS 기본 프로젝트 폴더 `Documents/Projects`.
  static String? get projectsDir => _documentsDir == null ? null : p.join(_documentsDir!, 'Projects');

  /// 이전 설치의 컨테이너 경로를 지금 경로로 바꾼다(iOS 전용, 그 밖에는 그대로).
  ///
  /// `…/Containers/Data/Application/<옛 UUID>/Documents/X` → `<지금 Documents>/X`.
  static String remap(String path) {
    final docs = _documentsDir;
    if (docs == null || path.isEmpty || p.isWithin(docs, path) || p.equals(docs, path)) return path;
    if (!path.contains('/Containers/Data/Application/')) return path;
    const marker = '/Documents';
    final i = path.indexOf('$marker/');
    if (i >= 0) return p.join(docs, path.substring(i + marker.length + 1));
    if (path.endsWith(marker)) return docs;
    return path;
  }
}
