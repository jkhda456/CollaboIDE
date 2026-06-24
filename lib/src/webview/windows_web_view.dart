import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_windows/webview_windows.dart';

import 'platform_web_view.dart';

/// Windows 백엔드: `webview_windows`(WebView2) 를 [PlatformWebView] 로 래핑한다.
///
/// 웹↔네이티브 메시지는 WebView2 의 네이티브 메시지 채널을 쓴다
/// (수신=`webMessage`, 송신=`postWebMessage`). 휠 좌표 버그가 있어
/// [needsWheelWorkaround] 가 true 이며, 패널이 휠 신호를 JS 로 중계한다.
class WindowsWebView implements PlatformWebView {
  final WebviewController _controller = WebviewController();
  final StreamController<void> _pageFinished = StreamController<void>.broadcast();
  StreamSubscription<LoadingState>? _loadingSub;

  /// WebView2 Runtime 다운로드 안내(Evergreen).
  static const String _runtimeDownloadUrl =
      'https://developer.microsoft.com/microsoft-edge/webview2/';

  @override
  Future<void> initialize() async {
    // WebView2 Runtime 이 없으면 네이티브 초기화가 프로세스를 강제 종료시킬 수
    // 있으므로, 초기화 전에 설치 여부를 먼저 확인한다(없으면 안내 화면 표시).
    final version = await WebviewController.getWebViewVersion();
    if (version == null) {
      throw const WebViewRuntimeMissing(downloadUrl: _runtimeDownloadUrl);
    }
    await _controller.initialize();
    _loadingSub = _controller.loadingState.listen((state) {
      if (state == LoadingState.navigationCompleted) _pageFinished.add(null);
    });
  }

  @override
  Stream<dynamic> get messages => _controller.webMessage;

  @override
  Stream<void> get pageFinished => _pageFinished.stream;

  @override
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<void> postMessage(String json) => _controller.postWebMessage(json);

  @override
  Future<void> executeScript(String script) => _controller.executeScript(script);

  @override
  Widget buildView() => Webview(_controller);

  @override
  bool get needsWheelWorkaround => true;

  @override
  Future<void> dispose() async {
    await _loadingSub?.cancel();
    await _pageFinished.close();
    _controller.dispose();
  }
}
