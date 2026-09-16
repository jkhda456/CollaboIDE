import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'platform_browser_view.dart';

/// macOS / Android / iOS 백엔드: `webview_flutter` 로 탭 한 장을 띄운다.
///
/// Windows 쪽과 같은 취지다 — 헤드리스 자동화가 아니라 **사용자가 보고 조작하는
/// 진짜 WKWebView** 라서, UA 도 Safari 계열 그대로이고 캡차·로그인은 사용자가
/// 그 자리에서 푼다.
///
/// 메시지 채널은 JS 채널 `CollaboBrowser` 다. 앱 UI 웹뷰가 쓰는 `Collabo` 와
/// **이름을 나눈다** — 둘은 다른 웹뷰이고 계약도 다르므로, 이름이 겹치면
/// 임의의 웹페이지가 앱 브리지 메시지를 흉내 낼 여지가 생긴다.
class FlutterBrowserView implements PlatformBrowserView {
  late final WebViewController _controller;
  final StreamController<BrowserViewEvent> _events =
      StreamController<BrowserViewEvent>.broadcast();

  /// 진행 중인 [evalJs] 들(상관 id → 완료자).
  final Map<String, Completer<Object?>> _pending = {};
  var _evalSeq = 0;
  var _disposed = false;

  @override
  Future<void> initialize({String? userAgent}) async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('CollaboBrowser', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (req) => isAllowedBrowserUrl(req.url)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageStarted: (url) =>
            _emit(BrowserViewEvent(url: url, loading: true, error: '')),
        onPageFinished: _onFinished,
        onUrlChange: (c) {
          final u = c.url;
          if (u != null) _emit(BrowserViewEvent(url: u));
        },
        onWebResourceError: (e) {
          // 하위 리소스(이미지·광고) 실패까지 탭을 실패로 만들면 멀쩡한 페이지가
          // 빨갛게 뜬다. 주 프레임의 실패만 센다.
          if (e.isForMainFrame == false) return;
          _emit(BrowserViewEvent(loading: false, error: e.description));
        },
      ));
    if (userAgent != null && userAgent.isNotEmpty) {
      await _controller.setUserAgent(userAgent);
    }
  }

  /// 로드가 끝나면 제목과 히스토리 가능 여부를 **물어서** 채운다
  /// (`webview_flutter` 는 이것들을 스트림으로 주지 않는다).
  Future<void> _onFinished(String url) async {
    _emit(BrowserViewEvent(url: url, loading: false));
    try {
      final title = await _controller.getTitle();
      final back = await _controller.canGoBack();
      final fwd = await _controller.canGoForward();
      _emit(BrowserViewEvent(
        title: title ?? '',
        canGoBack: back,
        canGoForward: fwd,
      ));
    } catch (_) {
      // 제목/히스토리 조회 실패는 표시 품질 문제일 뿐이라 무시한다.
    }
  }

  void _emit(BrowserViewEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _onMessage(JavaScriptMessage m) {
    Map<String, Object?>? msg;
    try {
      final decoded = jsonDecode(m.message);
      if (decoded is Map) msg = decoded.cast<String, Object?>();
    } catch (_) {
      return;
    }
    // 상관 id 가 붙은 것만 받는다 — 임의의 웹페이지도 이 채널로 말할 수 있다.
    final id = msg?['__collabo_eval'];
    if (id is! String) return;
    final done = _pending.remove(id);
    if (done == null || done.isCompleted) return;
    if (msg!['ok'] == true) {
      done.complete(msg['value']);
    } else {
      done.completeError(
          BrowserEvalException('${msg['error'] ?? 'script error'}'));
    }
  }

  @override
  Stream<BrowserViewEvent> get events => _events.stream;

  @override
  Future<void> loadUrl(String url) =>
      _controller.loadRequest(Uri.parse(url));

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  Future<void> goForward() => _controller.goForward();

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<void> stopLoading() async {
    // webview_flutter 에는 stop 이 없다. 진행 중인 로드를 끊는 가장 가까운 수단이
    // 이것뿐이라 JS 로 창을 멈춘다(실패해도 무시).
    try {
      await _controller.runJavaScript('window.stop && window.stop()');
    } catch (_) {}
    _emit(const BrowserViewEvent(loading: false));
  }

  @override
  Future<Object?> evalJs(String body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_disposed) throw const BrowserEvalException('browser tab is closed');
    final id = 'e${_evalSeq++}';
    final done = Completer<Object?>();
    _pending[id] = done;
    try {
      await _controller.runJavaScript(browserEvalScript(
        id: id,
        body: body,
        postCall: 'window.CollaboBrowser.postMessage',
      ));
    } catch (e) {
      _pending.remove(id);
      throw BrowserEvalException('$e');
    }
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw BrowserEvalException(
          'script did not answer within ${timeout.inSeconds}s');
    }
  }

  @override
  Widget buildView() => WebViewWidget(controller: _controller);

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const BrowserEvalException('browser tab is closed'));
      }
    }
    _pending.clear();
    await _events.close();
  }
}
