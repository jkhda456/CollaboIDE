import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'platform_web_view.dart';

/// macOS / Android / iOS 백엔드: 공식 `webview_flutter` 를 [PlatformWebView] 로
/// 래핑한다(macOS=WKWebView, Android=System WebView, iOS=WKWebView).
///
/// 메시지 채널:
///  - 웹 → 네이티브: JS 채널 `Collabo` (웹에서 `Collabo.postMessage(json)`).
///  - 네이티브 → 웹: `runJavaScript` 로 `window.collaboReceiveB64(<base64>)` 호출.
///    파일 내용 등 임의 문자열이 흐르므로 JS 리터럴 이스케이프 문제를 피하려고
///    UTF-8 → base64 로 인코딩해 넘기고, 웹에서 디코드 후 처리한다.
class FlutterWebView implements PlatformWebView {
  late final WebViewController _controller;
  final StreamController<dynamic> _messages = StreamController<dynamic>.broadcast();
  final StreamController<void> _pageFinished = StreamController<void>.broadcast();

  @override
  Future<void> initialize() async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Collabo',
        onMessageReceived: (JavaScriptMessage m) => _messages.add(m.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(onPageFinished: (_) => _pageFinished.add(null)),
      );
  }

  @override
  Stream<dynamic> get messages => _messages.stream;

  @override
  Stream<void> get pageFinished => _pageFinished.stream;

  @override
  Future<void> loadUrl(String url) {
    final uri = Uri.parse(url);
    if (uri.scheme == 'file') return _controller.loadFile(uri.toFilePath());
    return _controller.loadRequest(uri);
  }

  @override
  Future<void> postMessage(String json) {
    final b64 = base64.encode(utf8.encode(json));
    return _controller.runJavaScript('window.collaboReceiveB64 && '
        'window.collaboReceiveB64("$b64")');
  }

  @override
  Future<void> executeScript(String script) => _controller.runJavaScript(script);

  @override
  Widget buildView() => WebViewWidget(controller: _controller);

  @override
  bool get needsWheelWorkaround => false;

  @override
  Future<void> dispose() async {
    await _messages.close();
    await _pageFinished.close();
  }
}
