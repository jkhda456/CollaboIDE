import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:webview_windows/webview_windows.dart';

import 'platform_browser_view.dart';

/// Windows 백엔드: `webview_windows`(WebView2) 로 탭 한 장을 띄운다.
///
/// **WebView2 를 쓰는 것이 구글 차단 회피의 핵심이다.** 이건 헤드리스 자동화
/// 브라우저가 아니라 사용자가 실제로 보고 클릭하는 Edge Chromium 이다 —
/// `navigator.webdriver` 가 서지 않고, UA 도 평범한 Edge 이며, 쿠키·동의 화면·
/// 로그인이 사용자 조작으로 그대로 풀린다. 캡차가 뜨면 사용자가 그 탭에서 직접
/// 푼다(에이전트 탭과 사용자 탭을 나누지 않은 이유 중 하나다).
class WindowsBrowserView implements PlatformBrowserView {
  final WebviewController _controller = WebviewController();
  final StreamController<BrowserViewEvent> _events =
      StreamController<BrowserViewEvent>.broadcast();

  final List<StreamSubscription<dynamic>> _subs = [];

  /// 진행 중인 [evalJs] 들(상관 id → 완료자).
  final Map<String, Completer<Object?>> _pending = {};
  var _evalSeq = 0;
  var _disposed = false;

  @override
  Future<void> initialize({String? userAgent}) async {
    await _controller.initialize();
    if (userAgent != null && userAgent.isNotEmpty) {
      await _controller.setUserAgent(userAgent);
    }
    _subs.add(_controller.url.listen(
      (u) => _emit(BrowserViewEvent(url: u)),
      onError: (_) {},
    ));
    _subs.add(_controller.title.listen(
      (t) => _emit(BrowserViewEvent(title: t)),
      onError: (_) {},
    ));
    _subs.add(_controller.loadingState.listen(
      (s) => _emit(BrowserViewEvent(loading: s == LoadingState.loading)),
      onError: (_) {},
    ));
    _subs.add(_controller.historyChanged.listen(
      (h) => _emit(BrowserViewEvent(
        canGoBack: h.canGoBack,
        canGoForward: h.canGoForward,
      )),
      onError: (_) {},
    ));
    // evalJs 의 응답 통로. 페이지가 보낸 다른 메시지는 조용히 버린다 —
    // 임의의 웹페이지가 `chrome.webview` 로 아무 말이나 보낼 수 있으므로
    // **우리가 심은 상관 id 가 붙은 것만** 받는다.
    _subs.add(_controller.webMessage.listen(_onWebMessage, onError: (_) {}));
  }

  void _emit(BrowserViewEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _onWebMessage(dynamic raw) {
    Map<String, Object?>? msg;
    if (raw is Map) {
      msg = raw.cast<String, Object?>();
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) msg = decoded.cast<String, Object?>();
      } catch (_) {
        return;
      }
    }
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
  Future<void> loadUrl(String url) => _controller.loadUrl(url);

  @override
  Future<void> goBack() => _controller.goBack();

  @override
  Future<void> goForward() => _controller.goForward();

  @override
  Future<void> reload() => _controller.reload();

  @override
  Future<void> stopLoading() => _controller.stop();

  /// **`executeScript` 의 반환값에 기대지 않는다.**
  ///
  /// 패키지 버전에 따라 결과를 돌려주기도 하고 안 돌려주기도 해서, 이미 이 앱이
  /// 쓰고 있어 확실한 통로(`chrome.webview.postMessage` → `webMessage`)로 받는다.
  /// WebView2 는 `window.chrome.webview` 를 **모든 페이지에** 심어 주므로 원격
  /// 페이지에서도 그대로 동작한다.
  @override
  Future<Object?> evalJs(String body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (_disposed) throw const BrowserEvalException('browser tab is closed');
    final id = 'e${_evalSeq++}';
    final done = Completer<Object?>();
    _pending[id] = done;
    try {
      await _controller.executeScript(browserEvalScript(
        id: id,
        body: body,
        postCall: 'window.chrome.webview.postMessage',
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
  Widget buildView() => Webview(_controller);

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const BrowserEvalException('browser tab is closed'));
      }
    }
    _pending.clear();
    await _events.close();
    _controller.dispose();
  }
}
