import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'browser_tab.dart';
import 'platform_browser_view.dart';

/// 웹 검색 탭들의 주인. 탭 목록과 탭마다의 웹뷰를 들고, **원시 동사만** 낸다.
///
/// 여기에는 **검색엔진 지식이 없다.** 구글이 무엇인지, SERP 를 어떻게 읽는지는
/// 파이썬(`collabo_web.py`)이 안다. 이 층은 "탭을 열어라 · 이 URL 로 가라 ·
/// 지금 페이지를 내놔라" 만 한다. 그래야 검색엔진을 늘릴 때 Dart 를 안 고친다.
///
/// 사용자 탭과 에이전트 탭을 **나누지 않는다** — 목록도 쿠키도 하나다. 에이전트는
/// 사용자가 연 탭을 읽을 수 있고, 사용자는 에이전트가 연 탭을 보고 캡차를 풀 수 있다.
class BrowserController extends ChangeNotifier {
  BrowserController({this.onActivateRequested, this.viewFactory});

  /// 웹뷰를 만드는 방법. null 이면 플랫폼 기본([createPlatformBrowserView]).
  ///
  /// **테스트를 위한 이음매다** — 파일 통로와 탭 관리는 웹뷰 없이도 검증할 수
  /// 있어야 한다(`test/browser_channel_test.dart`). 주입하면 플랫폼 지원 검사도
  /// 건너뛴다.
  final PlatformBrowserView Function()? viewFactory;

  /// 도구가 탭을 열었을 때 **화면을 웹 검색 탭으로 돌려 달라**고 알리는 콜백.
  ///
  /// 웹뷰는 위젯 트리에 있어야 제대로 된 크기를 받는다. 크기가 0 이면 뷰포트에
  /// 기대는 페이지(지연 로딩·`innerText`)가 어긋난다. 그래서 에이전트가 처음
  /// 탭을 열 때 한 번 화면을 띄운다 — 사용자가 무슨 일이 벌어지는지 보게 되는
  /// 효과도 같이 얻는다.
  final VoidCallback? onActivateRequested;

  /// 동시에 열 수 있는 탭 수. 탭 하나가 웹뷰 하나(WebView2 는 프로세스 하나)라
  /// 상한이 없으면 메모리가 그대로 늘어난다.
  static const int maxTabs = 10;

  /// 페이지 로드를 기다리는 기본 상한. 넘으면 실패가 아니라 **그 시점의 페이지를
  /// 준다** — 광고·트래커가 끝나지 않아 `loading` 이 안 내려가는 사이트가 흔하다.
  static const Duration loadTimeout = Duration(seconds: 30);

  /// 로드 완료 뒤 DOM 이 자리를 잡을 때까지의 짧은 여유.
  static const Duration settleDelay = Duration(milliseconds: 400);

  final List<BrowserTab> _tabs = [];
  final Map<String, PlatformBrowserView> _views = {};
  final Map<String, StreamSubscription<BrowserViewEvent>> _subs = {};

  /// 탭마다 "다음 로드 완료"를 기다리는 사람. 로드가 끝나면 완료시키고 비운다.
  final Map<String, Completer<void>> _loadWaiters = {};

  var _seq = 0;
  String _activeId = '';
  var _disposed = false;

  /// 사용자 지정 User-Agent. 비어 있으면 플랫폼 기본(WebView2=Edge,
  /// WKWebView=Safari 계열)을 그대로 쓴다 — 그게 가장 평범해 보인다.
  String userAgent = '';

  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  String get activeId => _activeId;
  bool get isEmpty => _tabs.isEmpty;

  BrowserTab? get activeTab => _byId(_activeId);

  BrowserTab? _byId(String id) {
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  int _indexOf(String id) => _tabs.indexWhere((t) => t.id == id);

  /// 탭의 웹뷰. 패널이 [PlatformBrowserView.buildView] 를 부를 때 쓴다.
  PlatformBrowserView? viewOf(String id) => _views[id];

  // ---------------------------------------------------------------- 탭 수명

  /// 새 탭을 만들고 id 를 돌려준다. 웹뷰 초기화까지 끝난 뒤 반환한다.
  ///
  /// [url] 을 주면 이어서 로드하되 **기다리지는 않는다**(기다림은 [openUrl] 의 몫).
  Future<String> newTab({
    String? url,
    String name = '',
    TabOwner owner = TabOwner.user,
    bool activate = true,
  }) async {
    if (_disposed) throw StateError('browser is closed');
    if (_tabs.length >= maxTabs) {
      throw BrowserException(
          'too many tabs open ($maxTabs). Close one with web_tabs(action="close").');
    }
    if (viewFactory == null && !isPlatformBrowserSupported) {
      throw const BrowserException('web browser is not supported on this platform');
    }
    final id = 't${++_seq}';
    final view = (viewFactory ?? createPlatformBrowserView)();
    try {
      await view.initialize(userAgent: userAgent);
    } catch (e) {
      await view.dispose();
      throw BrowserException('could not start a browser tab: $e');
    }
    _views[id] = view;
    _subs[id] = view.events.listen((e) => _onEvent(id, e));
    _tabs.add(BrowserTab(id: id, name: name, owner: owner));
    if (activate || _activeId.isEmpty) _activeId = id;
    // 에이전트가 연 탭이면 화면을 웹 검색 쪽으로 돌린다(위 onActivateRequested 주석).
    if (owner == TabOwner.agent) onActivateRequested?.call();
    notifyListeners();
    if (url != null && url.isNotEmpty) {
      unawaited(_navigate(id, url));
    }
    return id;
  }

  /// 탭을 닫는다. 마지막 탭을 닫으면 활성 탭은 비워 둔다(패널이 빈 화면을 그린다).
  Future<void> closeTab(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    _tabs.removeAt(i);
    await _subs.remove(id)?.cancel();
    await _views.remove(id)?.dispose();
    _loadWaiters.remove(id)?.complete();
    if (_activeId == id) {
      // 닫은 자리를 이어받는다 — 없으면 그 앞 탭.
      final next = i < _tabs.length ? _tabs[i] : (_tabs.isEmpty ? null : _tabs.last);
      _activeId = next?.id ?? '';
    }
    notifyListeners();
  }

  /// 탭을 한꺼번에 닫는다. [owner] 를 주면 **그 주인의 탭만**. 닫은 수를 돌려준다.
  ///
  /// 에이전트 탭만 닫는 쪽이 따로 있는 이유: 탭 목록은 사용자와 에이전트가
  /// 같이 쓰는 하나다(§12 — 나누지 않기로 했다). 그래서 조사 몇 번이면 에이전트
  /// 탭이 쌓여 사용자가 보던 탭이 묻히는데, 그때 **자기 탭은 그대로 두고** 치우는
  /// 길이 있어야 한다. 꼬리표(`owner`)를 이미 들고 있으니 그걸 그대로 쓴다.
  Future<int> closeAll({TabOwner? owner}) async {
    // 닫는 동안 `_tabs` 가 줄어드므로 id 를 먼저 떠 둔다.
    final ids = [
      for (final t in _tabs)
        if (owner == null || t.owner == owner) t.id,
    ];
    for (final id in ids) {
      await closeTab(id);
    }
    return ids.length;
  }

  void activate(String id) {
    if (_indexOf(id) < 0 || _activeId == id) return;
    _activeId = id;
    notifyListeners();
  }

  /// 탭 이름을 바꾼다(에이전트가 무슨 탭인지 표시해 두는 용도).
  void rename(String id, String name) {
    final i = _indexOf(id);
    if (i < 0) return;
    _tabs[i] = _tabs[i].copyWith(name: name);
    notifyListeners();
  }

  // ----------------------------------------------------------------- 이동

  /// URL 을 열고 **로드가 끝날 때까지 기다린다.** [tabId] 가 없으면 새 탭.
  ///
  /// 기다림이 상한에 걸려도 실패가 아니다 — 끝나지 않는 페이지가 흔하므로
  /// 그 시점 상태로 돌려주고, 부른 쪽이 내용을 보고 판단한다.
  Future<BrowserTab> openUrl(
    String url, {
    String? tabId,
    String name = '',
    TabOwner owner = TabOwner.agent,
    Duration? timeout,
  }) async {
    if (!isAllowedBrowserUrl(url)) {
      throw BrowserException('only http/https URLs can be opened: $url');
    }
    var id = tabId ?? '';
    if (id.isEmpty) {
      id = await newTab(name: name, owner: owner);
    } else {
      if (_indexOf(id) < 0) throw BrowserException('no such tab: $id');
      if (name.isNotEmpty) rename(id, name);
    }
    await _navigate(id, url);
    await waitForLoad(id, timeout: timeout);
    return _byId(id)!;
  }

  Future<void> _navigate(String id, String url) async {
    final view = _views[id];
    if (view == null) return;
    final i = _indexOf(id);
    if (i >= 0) {
      _tabs[i] = _tabs[i]
          .copyWith(url: url, load: TabLoad.loading, error: '');
      notifyListeners();
    }
    // 이동을 시작하는 순간부터 기다릴 수 있게 대기자를 먼저 만들어 둔다.
    _loadWaiters[id] ??= Completer<void>();
    try {
      await view.loadUrl(url);
    } catch (e) {
      _fail(id, '$e');
    }
  }

  /// 탭의 히스토리를 움직인다. [action] 은 back/forward/reload/stop.
  Future<void> navigateAction(String id, String action) async {
    final view = _views[id];
    if (view == null) throw BrowserException('no such tab: $id');
    switch (action) {
      case 'back':
        _loadWaiters[id] ??= Completer<void>();
        await view.goBack();
      case 'forward':
        _loadWaiters[id] ??= Completer<void>();
        await view.goForward();
      case 'reload':
        _loadWaiters[id] ??= Completer<void>();
        await view.reload();
      case 'stop':
        await view.stopLoading();
        _loadWaiters.remove(id)?.complete();
      default:
        throw BrowserException('unknown action: $action');
    }
  }

  /// 탭의 로드가 끝날 때까지 기다린다. 이미 끝나 있으면 곧바로 돌아온다.
  Future<void> waitForLoad(String id, {Duration? timeout}) async {
    final tab = _byId(id);
    if (tab == null) throw BrowserException('no such tab: $id');
    final waiter = _loadWaiters[id];
    if (waiter == null || waiter.isCompleted) {
      if (!tab.isLoading) return;
    }
    final c = _loadWaiters[id] ??= Completer<void>();
    try {
      await c.future.timeout(timeout ?? loadTimeout);
    } on TimeoutException {
      // 끝나지 않는 페이지는 흔하다. 실패로 만들지 않고 지금 상태로 진행한다.
      _loadWaiters.remove(id);
    }
    // DOM 이 자리 잡을 짧은 여유. 이게 없으면 방금 그려진 결과를 놓친다.
    await Future<void>.delayed(settleDelay);
  }

  // ----------------------------------------------------------------- 읽기

  /// 페이지에서 뽑을 수 있는 형태. **파이썬 계약의 `format` 값과 같은 이름이다.**
  static const Set<String> readFormats = {'text', 'html', 'links'};

  /// 기본 상한. html 은 파이썬 파서가 SERP 를 읽을 만큼, text 는 모델 컨텍스트에
  /// 넣을 만큼으로 잡았다. 자르면 결과에 `truncated: true` 가 붙는다(노트 §6 과 같은 규약).
  static const int maxHtmlChars = 2 * 1024 * 1024;
  static const int maxTextChars = 200 * 1024;
  static const int maxLinks = 300;

  /// 탭의 현재 페이지를 읽는다.
  ///
  /// 자르기는 **페이지 안에서** 한다 — 메시지 채널로 수 MB 를 건네고 나서 Dart 가
  /// 자르면 그 왕복이 통째로 낭비다.
  Future<Map<String, Object?>> readPage(
    String id, {
    String format = 'text',
    int? maxChars,
  }) async {
    final view = _views[id];
    final tab = _byId(id);
    if (view == null || tab == null) throw BrowserException('no such tab: $id');
    if (!readFormats.contains(format)) {
      throw BrowserException(
          'unknown format: $format (use ${readFormats.join("|")})');
    }
    final Object? value;
    try {
      value = await view.evalJs(_readScript(format, maxChars));
    } on BrowserEvalException catch (e) {
      throw BrowserException('could not read the page: ${e.message}');
    }
    final out = <String, Object?>{
      'tab': id,
      'url': tab.url,
      'title': tab.title,
      'format': format,
    };
    if (format == 'links') {
      out['links'] = value is List ? value : const [];
      out['truncated'] = (value is List) && value.length >= maxLinks;
    } else {
      final text = value is String ? value : '${value ?? ''}';
      final limit = maxChars ??
          (format == 'html' ? maxHtmlChars : maxTextChars);
      out['content'] = text;
      out['truncated'] = text.length >= limit;
    }
    return out;
  }

  static String _readScript(String format, int? maxChars) {
    switch (format) {
      case 'html':
        final n = maxChars ?? maxHtmlChars;
        return '''
var el = document.documentElement;
var s = el ? el.outerHTML : '';
return s.length > $n ? s.slice(0, $n) : s;
''';
      case 'links':
        // `download` 속성과 파일처럼 보이는 확장자를 같이 준다 — 에이전트가
        // 어느 링크가 받을 것인지 고를 때 쓴다(`web_download(link:)`).
        // 판정은 여기서 하지 않는다. **재료만** 주고 고르는 것은 파이썬의 일이다.
        return '''
var out = [], seen = {};
var as = document.querySelectorAll('a[href]');
for (var i = 0; i < as.length && out.length < $maxLinks; i++) {
  var a = as[i];
  var h = a.href || '';
  if (h.indexOf('http') !== 0 || seen[h]) continue;
  seen[h] = 1;
  var t = (a.innerText || a.textContent || '').replace(/\\s+/g, ' ').trim();
  var rec = {text: t.slice(0, 300), url: h};
  var d = a.getAttribute('download');
  if (d !== null) rec.download = d || true;
  var m = /\\/([^\\/?#]+)\\.([A-Za-z0-9]{1,8})(?:[?#]|\$)/.exec(h);
  if (m) { rec.file = m[1] + '.' + m[2]; rec.ext = m[2].toLowerCase(); }
  out.push(rec);
}
return out;
''';
      default:
        final n = maxChars ?? maxTextChars;
        return '''
var b = document.body;
var s = b ? (b.innerText || b.textContent || '') : '';
return s.length > $n ? s.slice(0, $n) : s;
''';
    }
  }

  /// 페이지에서 임의의 JS 를 평가한다. **검색엔진 확장이 기대는 통로다** —
  /// 새 엔진이 DOM 을 직접 훑어야 하면 Dart 를 고치지 않고 여기로 온다.
  ///
  /// 원격 페이지의 스크립트를 우리가 대신 돌리는 것이므로 http/https 페이지에서만
  /// 허용한다(빈 탭·내부 페이지에서는 거부).
  Future<Object?> evalJs(String id, String body, {Duration? timeout}) async {
    final view = _views[id];
    final tab = _byId(id);
    if (view == null || tab == null) throw BrowserException('no such tab: $id');
    if (!isAllowedBrowserUrl(tab.url)) {
      throw const BrowserException('the tab has no page loaded');
    }
    try {
      return await view.evalJs(body,
          timeout: timeout ?? const Duration(seconds: 30));
    } on BrowserEvalException catch (e) {
      throw BrowserException(e.message);
    }
  }

  // ------------------------------------------------------------------ 간격

  /// 이름별로 "다음 차례는 언제부터" 를 들고 있는다. **메모리에만 둔다.**
  ///
  /// 정확히 관리할 값이 아니다 — 에이전트가 검색엔진을 초당 몇 번씩 두드리는
  /// 것만 막으면 되고, "대충 이 간격은 지킨다" 면 충분하다. 앱을 껐다 켜면
  /// 초기화되는 것도 오히려 맞다(그 사이엔 아무도 안 두드렸다).
  ///
  /// 값이 여기 있어야 하는 이유는 하나뿐이다: **도구 호출은 매번 새 프로세스**라
  /// (§5 도구 계약) 파이썬 쪽 변수는 다음 호출에서 사라진다. 오래 사는 것은
  /// 이 컨트롤러이고, 브라우저가 앱에 하나이므로(§1.5) 간격도 앱에 하나가 된다.
  final Map<String, DateTime> _slots = {};

  /// 같은 [key] 의 요청 사이에 최소 [minGap] 을 둔다. 기다린 밀리초를 돌려준다.
  ///
  /// **왜 오류가 아니라 대기인가**: 거절하면 모델이 곧바로 다시 부른다 —
  /// 막으려던 것을 오히려 늘린다. 조용히 늦추는 편이 실제로 횟수를 줄인다.
  ///
  /// 자기 차례를 **기다리기 전에** 찍어 둔다. 그래야 거의 동시에 들어온 둘이
  /// 같은 시각을 보고 나란히 나가지 않고 줄을 선다. Dart 는 단일 스레드라
  /// 이 사이에 끼어들 수 없다 — 파일로 하던 때의 경합이 통째로 사라진다.
  Future<int> waitForSlot(String key, Duration minGap) async {
    if (minGap <= Duration.zero) return 0;
    // 엉뚱한 값이 와도 한 번에 1분 넘게 붙잡지 않는다.
    final gap = minGap > maxSlotGap ? maxSlotGap : minGap;
    final now = DateTime.now();
    final next = _slots[key];
    final slot = (next == null || next.isBefore(now)) ? now : next;
    _slots[key] = slot.add(gap);
    final wait = slot.difference(now);
    if (wait <= Duration.zero) return 0;
    await Future<void>.delayed(wait);
    return wait.inMilliseconds;
  }

  /// 한 번에 기다릴 수 있는 최대.
  static const Duration maxSlotGap = Duration(minutes: 1);

  // ---------------------------------------------------------------- 내려받기

  /// 한 번에 웹뷰에서 꺼내 오는 조각(원시 바이트 기준).
  ///
  /// 통째로 가져오지 않는 이유: 바이트가 **base64 문자열**로 메시지 채널을 탄다
  /// (§evalJs — 반환값 대신 채널을 쓰는 이유는 §12 에 있다). 64MB 파일이면 87MB
  /// 짜리 문자열 하나가 되는데, 그걸 한 번에 넘기면 백엔드가 버티든 못 버티든
  /// 메모리가 세 배로 뛴다. 512KB 씩 끊으면 왕복이 늘 뿐 비용이 평평해진다.
  static const int downloadChunkBytes = 512 * 1024;

  /// 한 번의 다운로드 상한(기본). 호출측이 더 낮출 수 있다.
  static const int maxDownloadBytes = 128 * 1024 * 1024;

  /// 페이지가 다 받을 때까지 기다리는 기본 상한. 페이지 로드보다 길게 잡는다 —
  /// 큰 파일은 원래 오래 걸린다.
  static const Duration downloadTimeout = Duration(minutes: 3);

  var _dlSeq = 0;

  /// **탭의 세션으로** [url] 을 받아 파일로 쓴다.
  ///
  /// ★ 이것이 "그냥 HTTP 요청" 과 다른 점: 받는 주체가 우리가 아니라 **그 페이지**다.
  /// 페이지 안에서 `fetch(credentials:'include')` 를 돌리므로 로그인 쿠키
  /// (HttpOnly 포함 — 그래서 `document.cookie` 를 긁는 방식으로는 안 된다),
  /// Referer, 동의 상태, 서비스 워커가 전부 사용자가 보고 있는 그대로다.
  /// 로그인해야 받을 수 있는 파일이 이 방법의 존재 이유다.
  ///
  /// 한계도 그 구조에서 나온다 — **교차 출처는 CORS 가 허락해야 읽힌다.**
  /// 막히면 그 URL 의 출처에서 다시 받아야 하는데, 그 판단은 파이썬이 한다
  /// (§12 층 가르기 — 여기는 "이 탭에서 받아라" 만 안다).
  ///
  /// [destDir] 은 **호출측이 이미 검증한** 폴더다(통로가 프로젝트 안인지 본다).
  Future<Map<String, Object?>> downloadToFile(
    String id,
    String url, {
    required String destDir,
    String? fileName,
    int? maxBytes,
    Duration? timeout,
  }) async {
    final view = _views[id];
    final tab = _byId(id);
    if (view == null || tab == null) throw BrowserException('no such tab: $id');
    if (!isAllowedBrowserUrl(url)) {
      throw BrowserException('only http/https URLs can be downloaded: $url');
    }
    if (!isAllowedBrowserUrl(tab.url)) {
      throw const BrowserException(
          'the tab has no page loaded — open one first so the download can use '
          'its session');
    }
    final limit = (maxBytes == null || maxBytes <= 0)
        ? maxDownloadBytes
        : (maxBytes > maxDownloadBytes ? maxDownloadBytes : maxBytes);
    final key = 'd${++_dlSeq}';
    final wait = timeout ?? downloadTimeout;

    Object? head;
    try {
      head = await view.evalJs(_downloadStartScript(url, key), timeout: wait);
    } on BrowserEvalException catch (e) {
      throw BrowserException('download failed: ${e.message}');
    }
    final info =
        head is Map ? head.cast<String, Object?>() : const <String, Object?>{};
    if (info['ok'] != true) {
      // 페이지가 준 이유를 그대로 올린다 — CORS 인지 404 인지 파이썬이 보고
      // 다음 수를 정한다(출처를 바꿔 다시 받을지).
      await _downloadCleanup(view, key);
      throw BrowserException(
          'the page could not fetch it: ${info['error'] ?? 'unknown error'}');
    }
    final size = (info['size'] as num?)?.toInt() ?? 0;
    final status = (info['status'] as num?)?.toInt() ?? 0;
    if (status >= 400) {
      await _downloadCleanup(view, key);
      throw BrowserException('the server answered $status for $url');
    }
    if (size > limit) {
      await _downloadCleanup(view, key);
      throw BrowserException(
          'the file is too large: $size bytes (limit $limit). Raise max_bytes '
          'if you really want it.');
    }

    // 리다이렉트를 따라갔으면 **최종 URL** 이 이름의 근거로 더 정확하다.
    // 다만 백엔드가 못 채워 줄 수도 있어, 비어 있으면 요청한 URL 로 돌아간다.
    final landed = (info['url'] as String?) ?? '';
    final effectiveUrl = landed.isNotEmpty ? landed : url;
    final name = _downloadFileName(
      fileName,
      (info['disposition'] as String?) ?? '',
      effectiveUrl,
    );
    await Directory(destDir).create(recursive: true);
    final dest = await _uniqueFile(destDir, name);
    final sink = dest.openWrite();
    var done = false;
    try {
      var written = 0;
      while (written < size) {
        final n = (size - written) < downloadChunkBytes
            ? (size - written)
            : downloadChunkBytes;
        final Object? chunk;
        try {
          chunk = await view.evalJs(_downloadChunkScript(key, written, n),
              timeout: wait);
        } on BrowserEvalException catch (e) {
          throw BrowserException('download was interrupted: ${e.message}');
        }
        final b64 = chunk is String ? chunk : '';
        if (b64.isEmpty) {
          // 조각이 비었다 = 페이지가 옮겨 갔거나 버퍼가 사라졌다.
          throw const BrowserException(
              'the page navigated away while downloading — open the file URL '
              'in its own tab and try again');
        }
        final bytes = base64.decode(b64);
        sink.add(bytes);
        written += bytes.length;
      }
      await sink.flush();
      done = true;
    } finally {
      await sink.close();
      await _downloadCleanup(view, key);
      if (!done) {
        // 반쯤 쓰인 파일을 남기지 않는다 — 다음 도구가 그걸 온전한 파일로 읽는다.
        try {
          if (await dest.exists()) await dest.delete();
        } catch (_) {}
      }
    }

    return {
      'tab': id,
      'url': effectiveUrl,
      'path': dest.path,
      'name': p.basename(dest.path),
      'bytes': size,
      'mime': ((info['type'] as String?) ?? '').split(';').first.trim(),
      'status': status,
      'from': tab.url,
    };
  }

  /// 페이지 안에서 받아 `window.__collaboDl[key]` 에 담아 둔다(아직 안 넘긴다).
  static String _downloadStartScript(String url, String key) {
    final u = jsonEncode(url);
    final k = jsonEncode(key);
    return '''
window.__collaboDl = window.__collaboDl || {};
return fetch($u, {credentials: 'include', redirect: 'follow'})
  .then(function(r){
    function h(n){ try { return r.headers.get(n) || ''; } catch (e) { return ''; } }
    var cd = h('content-disposition'), ct = h('content-type');
    return r.arrayBuffer().then(function(b){
      window.__collaboDl[$k] = new Uint8Array(b);
      return {ok: true, status: r.status, size: b.byteLength,
              type: ct, disposition: cd, url: r.url};
    });
  })
  .catch(function(e){
    return {ok: false, error: String((e && e.message) || e)};
  });
''';
  }

  /// 담아 둔 바이트에서 한 조각을 base64 로 꺼낸다.
  static String _downloadChunkScript(String key, int offset, int count) {
    final k = jsonEncode(key);
    // ⚠️ `String.fromCharCode.apply` 에 큰 배열을 한 번에 주면 인자 한도를 넘겨
    // 스택이 터진다. 8KB 씩 이어 붙인다.
    return '''
var a = (window.__collaboDl || {})[$k];
if (!a) return '';
var s = $offset, e = Math.min(s + $count, a.length), bin = '';
for (var i = s; i < e; i += 8192) {
  bin += String.fromCharCode.apply(null, a.subarray(i, Math.min(i + 8192, e)));
}
return btoa(bin);
''';
  }

  /// 페이지에 남은 버퍼를 지운다. 실패해도 조용히 넘어간다 — 탭을 닫거나
  /// 페이지를 옮기면 어차피 사라진다.
  static Future<void> _downloadCleanup(
      PlatformBrowserView view, String key) async {
    try {
      await view.evalJs(
        'try { delete (window.__collaboDl || {})[${jsonEncode(key)}]; } '
        'catch (e) {} return true;',
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {}
  }

  /// 저장할 이름을 정한다: 지정한 이름 → `Content-Disposition` → URL 의 끝 → 기본값.
  ///
  /// 어느 쪽에서 왔든 **경로가 아니라 이름 하나로** 만든다. 서버가 주는 문자열을
  /// 그대로 경로에 붙이면 `../../` 한 줄로 프로젝트 밖에 쓰게 된다.
  static String _downloadFileName(
      String? given, String disposition, String url) {
    final explicit = (given ?? '').trim();
    if (explicit.isNotEmpty) return sanitizeDownloadName(explicit);

    // RFC 5987 의 `filename*=UTF-8''...` 이 있으면 그쪽이 우선이다(비ASCII 이름).
    final star = RegExp(r"filename\*\s*=\s*([^']*)'[^']*'([^;]+)",
            caseSensitive: false)
        .firstMatch(disposition);
    if (star != null) {
      try {
        final decoded = Uri.decodeComponent(star.group(2)!.trim());
        if (decoded.isNotEmpty) return sanitizeDownloadName(decoded);
      } catch (_) {}
    }
    final plain =
        RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false)
            .firstMatch(disposition);
    if (plain != null) {
      final v = plain.group(1)!.trim();
      if (v.isNotEmpty) return sanitizeDownloadName(v);
    }

    final uri = Uri.tryParse(url);
    final segs = uri?.pathSegments.where((s) => s.isNotEmpty).toList() ?? const [];
    if (segs.isNotEmpty) {
      final last = sanitizeDownloadName(segs.last);
      if (last != _fallbackDownloadName) return last;
    }
    return _fallbackDownloadName;
  }

  static const String _fallbackDownloadName = 'download.bin';

  /// 서버·페이지가 준 이름을 **파일 이름 하나**로 깎는다.
  ///
  /// 경로 구분자와 3-OS 공통 금지 문자를 지우고, 앞의 점을 떼고(`.`/`..` 방지),
  /// 길이를 자른다. 남는 게 없으면 기본 이름.
  static String sanitizeDownloadName(String raw) {
    var s = raw.trim().replaceAll('\\', '/');
    // 경로가 섞여 와도 마지막 조각만 쓴다.
    if (s.contains('/')) s = s.split('/').last;
    s = s.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '').trim();
    while (s.startsWith('.')) {
      s = s.substring(1);
    }
    s = s.trim();
    if (s.isEmpty) return _fallbackDownloadName;
    if (s.length > 180) {
      final dot = s.lastIndexOf('.');
      final ext = (dot > 0 && s.length - dot <= 12) ? s.substring(dot) : '';
      s = s.substring(0, 180 - ext.length) + ext;
    }
    return s;
  }

  /// 같은 이름이 있으면 `name_1.ext`, `name_2.ext` … 로 비켜 간다.
  /// **덮어쓰지 않는다** — 받은 파일이 조용히 사라지는 쪽이 훨씬 나쁘다.
  static Future<File> _uniqueFile(String dir, String name) async {
    var candidate = File(p.join(dir, name));
    if (!await candidate.exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      candidate = File(p.join(dir, '${stem}_$i$ext'));
      if (!await candidate.exists()) return candidate;
    }
    return File(p.join(dir, '${stem}_${DateTime.now().millisecondsSinceEpoch}$ext'));
  }

  // --------------------------------------------------------------- 상태 갱신

  void _onEvent(String id, BrowserViewEvent e) {
    final i = _indexOf(id);
    if (i < 0) return;
    final before = _tabs[i];
    var load = before.load;
    // 새 로드가 시작되면 지난 실패는 지운다 — 안 그러면 한 번 실패한 탭이
    // 다시 성공해도 빨간 표시를 달고 있게 된다.
    var error = e.error;
    if (e.loading == true) error = '';
    if (error != null && error.isNotEmpty) {
      load = TabLoad.failed;
    } else if (e.loading == true) {
      load = TabLoad.loading;
    } else if (e.loading == false) {
      load = before.load == TabLoad.failed ? TabLoad.failed : TabLoad.ready;
    }
    _tabs[i] = before.copyWith(
      url: e.url,
      title: e.title,
      load: load,
      canGoBack: e.canGoBack,
      canGoForward: e.canGoForward,
      error: error,
    );
    if (e.loading == false || (e.error != null && e.error!.isNotEmpty)) {
      _loadWaiters.remove(id)?.complete();
    }
    notifyListeners();
  }

  void _fail(String id, String message) {
    final i = _indexOf(id);
    if (i < 0) return;
    _tabs[i] = _tabs[i].copyWith(load: TabLoad.failed, error: message);
    _loadWaiters.remove(id)?.complete();
    notifyListeners();
  }

  /// 사용자가 **주소창에 친 말**을 검색 URL 로 바꾼다.
  ///
  /// ⚠️ 검색엔진 지식이 이 파일에 있는 **유일한 자리**이고, `collabo_web.py` 의
  /// 엔진 목록과 **두 벌**이다(노트 §12 표에 등록해 둘 것). 나눠 놓은 이유:
  /// 주소창은 도구가 아니라 사용자 입력이라 파이썬을 거칠 수 없고, 필요한 것도
  /// 질의 URL 한 줄뿐이다(파이썬 쪽은 결과를 긁는 JS 까지 안다).
  /// 파이썬에 드롭인 엔진을 넣어도 여기는 안 따라온다 — 그때 사용자의 주소창은
  /// 구글로 떨어진다. 화면 동작이라 그 정도 어긋남은 안전하다.
  static String searchUrlFor(String query, String engine) {
    final q = Uri.encodeQueryComponent(query);
    switch (engine) {
      case 'duckduckgo':
        return 'https://duckduckgo.com/?q=$q&ia=web';
      default:
        return 'https://www.google.com/search?q=$q';
    }
  }

  /// 주소창에 친 말이 **주소인가 검색어인가.**
  ///
  /// 스킴이 있으면 주소. 없으면 `점이 있고 공백이 없는` 것만 주소로 본다
  /// (`example.com/x` 는 주소, `flutter 상태관리` 와 `3.14` 는 검색어).
  static bool looksLikeUrl(String input) {
    final s = input.trim();
    if (s.isEmpty || s.contains(' ')) return false;
    if (s.startsWith('http://') || s.startsWith('https://')) return true;
    if (s.contains('://')) return false; // 다른 스킴은 열지 않는다
    final host = s.split('/').first;
    if (!host.contains('.')) return false;
    // 마지막 점 뒤가 글자로만 이뤄져 있어야 TLD 로 친다(`3.14` 를 거른다).
    final tld = host.split('.').last;
    return tld.length >= 2 && RegExp(r'^[A-Za-z]+$').hasMatch(tld);
  }

  /// 주소창 입력 하나를 처리한다 — 주소면 그리로, 아니면 검색.
  Future<void> submitFromAddressBar(String input, String engine) async {
    final s = input.trim();
    if (s.isEmpty) return;
    final url = looksLikeUrl(s)
        ? (s.startsWith('http') ? s : 'https://$s')
        : searchUrlFor(s, engine);
    final id = _activeId;
    if (id.isEmpty) {
      await newTab(url: url, owner: TabOwner.user);
      return;
    }
    await _navigate(id, url);
  }

  /// 파일 통로(`web_tabs`)가 그대로 돌려주는 목록.
  List<Map<String, Object?>> tabsJson() => [
        for (final t in _tabs)
          {...t.toJson(), 'active': t.id == _activeId},
      ];

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs.values) {
      s.cancel();
    }
    _subs.clear();
    for (final v in _views.values) {
      v.dispose();
    }
    _views.clear();
    _tabs.clear();
    for (final c in _loadWaiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _loadWaiters.clear();
    super.dispose();
  }
}

/// 브라우저 동사가 실패한 이유. 파일 통로가 이 메시지를 그대로 파이썬에 넘기고,
/// 파이썬은 도구 오류로 바꾼다 — 모델이 읽고 고칠 수 있는 문장이어야 한다.
class BrowserException implements Exception {
  const BrowserException(this.message);

  final String message;

  @override
  String toString() => message;
}
