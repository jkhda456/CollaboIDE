import 'dart:io';

import 'package:flutter/widgets.dart';

import 'flutter_browser_view.dart';
import 'windows_browser_view.dart';

/// 웹 검색 탭 **한 장**이 쓰는 웹뷰의 공통 계약.
///
/// `lib/src/webview/platform_web_view.dart`(앱 UI 웹뷰)와 **일부러 분리했다.**
/// 그쪽은 `file://` 로 우리 페이지 하나를 띄우고 JSON 브리지로만 말하는 계약이고,
/// 이쪽은 임의의 https 페이지를 오가며 뒤/앞·제목·URL·JS 평가가 필요하다.
/// 계약을 합치면 양쪽 다 넓어지기만 하고, 앱의 심장인 브리지 계약이 흔들린다.
///
///  - Windows          : `webview_windows`(WebView2) → [WindowsBrowserView]
///  - macOS/Android/iOS: `webview_flutter`(WKWebView) → [FlutterBrowserView]
///  - Linux            : 미지원. 팩토리에서 [UnsupportedError].
abstract class PlatformBrowserView {
  /// 웹뷰를 초기화한다(로드 전 1회).
  ///
  /// [userAgent] 가 비어 있지 않으면 그대로 덮어쓴다. **기본은 덮어쓰지 않는다** —
  /// WebView2 는 이미 Edge 의 UA 를, WKWebView 는 Safari 계열 UA 를 보내므로
  /// 그대로가 가장 평범한 브라우저처럼 보인다.
  Future<void> initialize({String? userAgent});

  /// URL·제목·로드 상태·히스토리 변화. 컨트롤러가 탭 스냅샷을 갱신하는 재료다.
  Stream<BrowserViewEvent> get events;

  /// 페이지 로드. http/https 만 받는다(검사는 호출측 책임).
  Future<void> loadUrl(String url);

  Future<void> goBack();
  Future<void> goForward();
  Future<void> reload();

  /// 진행 중인 로드를 멈춘다.
  Future<void> stopLoading();

  /// JS 를 평가하고 **결과를 돌려받는다.**
  ///
  /// [body] 는 함수 본문이다 — 값을 `return` 하면 그 값이 온다. Promise 를
  /// 돌려주면 풀릴 때까지 기다린다. 반환은 JSON 으로 옮길 수 있는 값이어야 한다.
  ///
  /// 백엔드마다 방식이 다른 것을 여기서 감춘다(§windows/flutter 어댑터 주석).
  /// 실패하거나 [timeout] 을 넘기면 [BrowserEvalException].
  Future<Object?> evalJs(String body, {Duration timeout});

  /// 화면에 임베드할 위젯.
  Widget buildView();

  Future<void> dispose();
}

/// 페이지에서 올라오는 상태 변화 한 건.
///
/// 백엔드마다 신호가 쪼개져 오므로(Windows 는 url/title/loadingState/history 가
/// 따로, Flutter 는 NavigationDelegate 콜백) **바뀐 필드만 채운 부분 갱신**으로
/// 통일한다. null 인 필드는 "이번엔 안 바뀜" 이다.
class BrowserViewEvent {
  const BrowserViewEvent({
    this.url,
    this.title,
    this.loading,
    this.canGoBack,
    this.canGoForward,
    this.error,
  });

  final String? url;
  final String? title;
  final bool? loading;
  final bool? canGoBack;
  final bool? canGoForward;

  /// 로드 실패 사유. 채워지면 컨트롤러가 탭을 실패 상태로 바꾼다.
  final String? error;
}

/// [PlatformBrowserView.evalJs] 실패(페이지 예외·타임아웃·백엔드 오류).
class BrowserEvalException implements Exception {
  const BrowserEvalException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 이 플랫폼에서 웹 검색 탭을 쓸 수 있는지. 앱 UI 웹뷰와 같은 조건이다.
bool get isPlatformBrowserSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isAndroid || Platform.isIOS;

/// 플랫폼에 맞는 브라우저 백엔드를 만든다.
PlatformBrowserView createPlatformBrowserView() {
  if (Platform.isWindows) return WindowsBrowserView();
  if (Platform.isMacOS || Platform.isAndroid || Platform.isIOS) {
    return FlutterBrowserView();
  }
  throw UnsupportedError(
    'Web browser tab is not supported on ${Platform.operatingSystem} yet.',
  );
}

/// [PlatformBrowserView.evalJs] 의 본문을 **결과를 되돌려 보내는 스크립트**로 감싼다.
///
/// 두 백엔드가 같은 방식을 쓴다 — 페이지가 메시지 채널로 결과를 보내고 어댑터가
/// 상관 id 로 짝을 맞춘다. `executeScript`/`runJavaScriptReturningResult` 의
/// 반환값은 백엔드·플랫폼마다 감싸는 모양이 달라(안드로이드는 한 번 더 JSON
/// 인코딩한다) 믿지 않는다. 메시지 채널은 이 앱이 이미 쓰고 있어 확실하다.
///
/// [postCall] 은 문자열 하나를 네이티브로 보내는 JS 식이다
/// (`window.chrome.webview.postMessage` / `window.CollaboBrowser.postMessage`).
/// Promise 를 반환하면 풀릴 때까지 기다린다.
String browserEvalScript({
  required String id,
  required String body,
  required String postCall,
}) {
  // id 는 우리가 만든 `e<숫자>` 라 이스케이프가 필요 없지만, 리터럴로 박히는
  // 값이므로 그래도 JSON 으로 감싸 둔다.
  final idLit = '"$id"';
  return '''
(function(){
  var __id = $idLit;
  function __send(ok, value, error){
    try {
      $postCall(JSON.stringify(
        {__collabo_eval: __id, ok: ok, value: value, error: error}));
    } catch (e) {}
  }
  try {
    var __r = (function(){ $body })();
    if (__r && typeof __r.then === 'function') {
      __r.then(function(v){ __send(true, v); },
               function(e){ __send(false, null, String(e)); });
    } else {
      __send(true, __r);
    }
  } catch (e) { __send(false, null, String(e)); }
})();
''';
}

/// 탭이 열 수 있는 스킴인지. **http/https 만 허용한다.**
///
/// `file:` 을 막는 이유가 본질적이다 — 허용하면 에이전트가 브라우저를 통해
/// 워크스페이스 밖 로컬 파일을 읽을 수 있고, 그건 파이썬 도구의 `_resolve()`
/// 가드를 통째로 우회하는 길이 된다(노트 §1 원칙 3). 로컬 파일은 트리와 뷰어가
/// 읽는다. `about:`·`data:`·`javascript:` 도 같은 이유로 막는다.
bool isAllowedBrowserUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme) return false;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https';
}
