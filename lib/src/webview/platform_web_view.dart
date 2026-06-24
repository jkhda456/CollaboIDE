import 'dart:io';

import 'package:flutter/widgets.dart';

import 'flutter_web_view.dart';
import 'windows_web_view.dart';

/// 가운데 대화 + 우측 트리/뷰어가 렌더링되는 웹뷰 백엔드의 공통 계약.
///
/// 플랫폼마다 임베디드 웹뷰 + JS 브리지 API 가 다르므로 이 인터페이스로 추상화한다.
///  - Windows         : `webview_windows`(WebView2)  → [WindowsWebView]
///  - macOS/Android/iOS: 공식 `webview_flutter`        → [FlutterWebView]
///  - Linux           : 미지원(추후 `webview_cef`).  팩토리에서 차단된다.
///
/// 웹↔네이티브 메시지는 양쪽 모두 JSON 문자열로 주고받는다. 수신([messages])은
/// 백엔드에 따라 String 또는 파싱된 Map 으로 올 수 있어 소비측에서 모두 처리한다.
abstract class PlatformWebView {
  /// 컨트롤러를 초기화한다(페이지 로드 전 1회).
  Future<void> initialize();

  /// 웹(JS) → 네이티브 메시지 스트림. 각 이벤트는 String 또는 Map.
  Stream<dynamic> get messages;

  /// 페이지 로드 완료(navigation completed) 알림.
  Stream<void> get pageFinished;

  /// 페이지 URL 로드. `file://` 로컬 리소스를 받는다.
  Future<void> loadUrl(String url);

  /// 네이티브 → 웹: 구조화 메시지(JSON 문자열)를 브리지로 전달한다.
  Future<void> postMessage(String json);

  /// 네이티브 → 웹: 임의 JS 를 실행한다(테마/언어팩 주입 등).
  Future<void> executeScript(String script);

  /// 화면에 임베드할 위젯.
  Widget buildView();

  /// 마우스 휠 좌표 버그 우회(JS 주입)가 필요한 백엔드인지.
  /// `webview_windows` 0.4.0 만 해당한다.
  bool get needsWheelWorkaround => false;

  Future<void> dispose();
}

/// 웹뷰 런타임(예: Windows 의 Microsoft Edge WebView2 Runtime)이 설치돼 있지
/// 않을 때 던진다. 네이티브 초기화가 프로세스를 강제 종료시킬 수 있으므로,
/// 어댑터는 초기화 전에 이를 감지해 던지고 패널은 안내 화면을 표시한다.
class WebViewRuntimeMissing implements Exception {
  const WebViewRuntimeMissing({this.downloadUrl});

  /// 런타임 다운로드 안내 URL(있으면 패널에 링크로 노출).
  final String? downloadUrl;

  @override
  String toString() => 'WebView runtime is not installed';
}

/// 현재 플랫폼이 임베디드 웹뷰를 지원하는지.
/// (Linux 는 추후 `webview_cef` 연결 전까지 false → 플레이스홀더 표시.)
bool get isPlatformWebViewSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isAndroid || Platform.isIOS;

/// 플랫폼에 맞는 웹뷰 백엔드를 생성한다.
/// 지원하지 않는 플랫폼(Linux)에서 호출하면 [UnsupportedError].
PlatformWebView createPlatformWebView() {
  if (Platform.isWindows) return WindowsWebView();
  if (Platform.isMacOS || Platform.isAndroid || Platform.isIOS) {
    return FlutterWebView();
  }
  throw UnsupportedError(
    'Embedded WebView is not supported on ${Platform.operatingSystem} yet.',
  );
}
