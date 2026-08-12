import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// macOS 전용 파일 선택기 — **심링크를 해석하지 않고 고른 경로 그대로** 돌려준다.
///
/// `file_selector`(NSOpenPanel 기본)는 별칭/심링크를 풀어버려, venv 의
/// `bin/python`(= base 인터프리터로의 심링크)을 고르면 base(Homebrew/시스템)
/// 경로로 바뀐다. 그러면 venv 가 아니라 base 로 실행돼 PEP 668 등으로 막힌다.
/// 이 채널은 네이티브에서 `resolvesAliases=false` + `url.path`(해석 없음)로
/// 선택 경로를 그대로 반환한다(비 macOS 는 no-op → 호출부가 file_selector 로 폴백).
class MacFilePicker {
  MacFilePicker._();

  static const MethodChannel _ch = MethodChannel('collabo/macos_files');

  static bool get supported => !kIsWeb && Platform.isMacOS;

  /// 파일 하나를 고른다. 취소/미지원이면 null.
  /// [extensions] 를 주면 그 확장자만 선택할 수 있게 제한한다(예: 이미지).
  static Future<String?> pickFile({String? title, List<String>? extensions}) async {
    if (!supported) return null;
    try {
      return await _ch.invokeMethod<String>('pickFile', {
        'title': title,
        if (extensions != null && extensions.isNotEmpty)
          'extensions': extensions,
      });
    } on PlatformException {
      return null;
    }
  }
}
