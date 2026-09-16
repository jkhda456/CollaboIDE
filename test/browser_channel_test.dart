import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/browser/browser_channel.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/browser/browser_tab.dart';
import 'package:collabo_ide/src/browser/platform_browser_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 웹뷰 없이 도는 가짜 페이지. 로드를 흉내 내고, `evalJs` 는 미리 정해 둔 값을
/// 돌려준다 — 통로와 탭 관리만 검사하는 것이 목적이다.
class _FakeView implements PlatformBrowserView {
  final StreamController<BrowserViewEvent> _events =
      StreamController<BrowserViewEvent>.broadcast();

  /// `evalJs` 가 돌려줄 값. 테스트가 갈아 끼운다.
  Object? evalResult;

  /// 마지막으로 평가한 스크립트 본문.
  String lastScript = '';

  /// 다음 loadUrl 을 실패시킨다.
  String failWith = '';

  final List<String> loaded = [];
  var disposed = false;

  @override
  Future<void> initialize({String? userAgent}) async {}

  @override
  Stream<BrowserViewEvent> get events => _events.stream;

  @override
  Future<void> loadUrl(String url) async {
    loaded.add(url);
    // 실제 백엔드처럼 비동기로 로드 완료를 알린다.
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      if (failWith.isNotEmpty) {
        _events.add(BrowserViewEvent(loading: false, error: failWith));
      } else {
        _events.add(BrowserViewEvent(
          url: url,
          title: 'title of $url',
          loading: false,
          canGoBack: loaded.length > 1,
        ));
      }
    });
  }

  @override
  Future<void> goBack() async => loadUrl('back://');

  @override
  Future<void> goForward() async => loadUrl('forward://');

  @override
  Future<void> reload() async => loadUrl(loaded.isEmpty ? '' : loaded.last);

  @override
  Future<void> stopLoading() async {}

  @override
  Future<Object?> evalJs(String body,
      {Duration timeout = const Duration(seconds: 30)}) async {
    lastScript = body;
    return evalResult;
  }

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

void main() {
  // 통로는 파일 감시 + 폴링으로 돈다. 응답이 파일로 떨어질 때까지 기다린다.
  Future<Map<String, Object?>> ask(
    String root,
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    final id = 'r${DateTime.now().microsecondsSinceEpoch}';
    final reqDir = Directory(p.join(root, 'req'))..createSync(recursive: true);
    final tmp = File(p.join(reqDir.path, '$id.json.tmp'));
    await tmp.writeAsString(jsonEncode({'id': id, 'op': op, 'args': args}));
    await tmp.rename(p.join(reqDir.path, '$id.json'));

    final res = File(p.join(root, 'res', '$id.json'));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (res.existsSync()) {
        final body =
            (jsonDecode(await res.readAsString()) as Map).cast<String, Object?>();
        await res.delete();
        return body;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('통로가 $op 에 답하지 않았다');
  }

  group('경로/입력 판정 (순수 함수)', () {
    test('http/https 만 연다', () {
      expect(isAllowedBrowserUrl('https://example.com'), isTrue);
      expect(isAllowedBrowserUrl('http://example.com'), isTrue);
      // file: 을 허용하면 파이썬 도구의 워크스페이스 가드를 통째로 우회한다.
      expect(isAllowedBrowserUrl('file:///etc/passwd'), isFalse);
      expect(isAllowedBrowserUrl('about:blank'), isFalse);
      expect(isAllowedBrowserUrl('javascript:alert(1)'), isFalse);
      expect(isAllowedBrowserUrl('data:text/html,x'), isFalse);
      expect(isAllowedBrowserUrl('example.com'), isFalse);
      expect(isAllowedBrowserUrl(''), isFalse);
    });

    test('주소창 입력이 주소인지 검색어인지', () {
      expect(BrowserController.looksLikeUrl('https://a.com/b'), isTrue);
      expect(BrowserController.looksLikeUrl('example.com'), isTrue);
      expect(BrowserController.looksLikeUrl('example.com/path'), isTrue);
      expect(BrowserController.looksLikeUrl('flutter webview'), isFalse);
      expect(BrowserController.looksLikeUrl('3.14'), isFalse);
      expect(BrowserController.looksLikeUrl('localhost'), isFalse);
      expect(BrowserController.looksLikeUrl('file:///x'), isFalse);
    });

    test('검색어는 엔진별 URL 이 된다', () {
      expect(BrowserController.searchUrlFor('a b', 'google'),
          'https://www.google.com/search?q=a%20b');
      expect(BrowserController.searchUrlFor('a b', 'duckduckgo'),
          startsWith('https://duckduckgo.com/?q='));
      // 모르는 엔진은 구글로 떨어진다(주소창은 화면 동작이라 안전한 기본값).
      expect(BrowserController.searchUrlFor('x', 'altavista'),
          startsWith('https://www.google.com/'));
    });

    test('evalJs 래퍼는 본문과 상관 id 를 싣는다', () {
      final s = browserEvalScript(
          id: 'e7', body: 'return 1;', postCall: 'window.post');
      expect(s, contains('"e7"'));
      expect(s, contains('return 1;'));
      expect(s, contains('window.post(JSON.stringify('));
      // Promise 도 기다린다.
      expect(s, contains("typeof __r.then === 'function'"));
    });
  });

  group('탭 모델', () {
    test('label 은 이름 → 제목 → URL 순', () {
      const t = BrowserTab(id: 't1', url: 'https://a.com');
      expect(t.label, 'https://a.com');
      expect(t.copyWith(title: 'A').label, 'A');
      expect(t.copyWith(title: 'A', name: 'N').label, 'N');
    });

    test('toJson 의 키가 파이썬 계약과 같다', () {
      const t = BrowserTab(id: 't1', name: 'n', title: 'T', url: 'u');
      expect(t.toJson().keys.toSet(), {
        'tab', 'name', 'title', 'url', 'status',
        'opened_by', 'can_go_back', 'can_go_forward',
      });
    });
  });

  group('파일 통로', () {
    late Directory dir;
    late List<_FakeView> views;
    late BrowserController controller;
    late BrowserChannel channel;

    /// 다음에 만들어질 탭이 로드에 실패하게 한다(탭이 생기기 **전에** 정해야 한다).
    var nextFailWith = '';

    // 탭마다 웹뷰가 하나다 — 테스트도 그렇게 만들어야 한다. 하나를 돌려쓰면
    // 닫힌(dispose 된) 웹뷰를 다음 탭이 물려받아 이벤트가 영영 안 온다.
    _FakeView newView() {
      final v = _FakeView()..failWith = nextFailWith;
      views.add(v);
      return v;
    }

    /// 가장 최근에 열린 탭의 웹뷰.
    _FakeView view() => views.last;

    /// 이 프로젝트의 통로 폴더.
    late String root;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('collabo_browser_');
      root = p.join(dir.path, '.collabo', 'browser');
      views = [];
      nextFailWith = '';
      controller = BrowserController(viewFactory: newView);
      channel = BrowserChannel(controller)..attachProject(dir.path);
    });

    tearDown(() {
      channel.dispose();
      controller.dispose();
      dir.deleteSync(recursive: true);
    });

    test('open 이 탭을 만들고 로드를 기다린다', () async {
      final res = await ask(root, 'open', {'url': 'https://example.com/'});
      expect(res['ok'], isTrue);
      final r = (res['result'] as Map).cast<String, Object?>();
      expect(r['tab'], 't1');
      expect(r['url'], 'https://example.com/');
      // 기다렸으므로 제목까지 채워져 있어야 한다.
      expect(r['title'], 'title of https://example.com/');
      expect(r['status'], 'ready');
      expect(r['opened_by'], 'agent');
      expect(view().loaded, ['https://example.com/']);
    });

    test('http/https 가 아니면 거부한다', () async {
      final res = await ask(root, 'open', {'url': 'file:///etc/passwd'});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('http'));
      expect(views, isEmpty, reason: '거부했으면 탭도 만들지 않는다');
    });

    test('탭을 안 주면 활성 탭으로 떨어진다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      view().evalResult = 'body text';
      final res = await ask(root, 'read', {'format': 'text'});
      final r = (res['result'] as Map).cast<String, Object?>();
      expect(r['tab'], 't1');
      expect(r['content'], 'body text');
      expect(r['truncated'], isFalse);
    });

    test('읽을 탭이 하나도 없으면 무엇을 하라고 알려 준다', () async {
      final res = await ask(root, 'read', {});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('web_open'));
    });

    test('links 형태는 배열을 그대로 준다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      view().evalResult = [
        {'text': 'A', 'url': 'https://a.example/'},
      ];
      final res = await ask(root, 'read', {'format': 'links'});
      final r = (res['result'] as Map).cast<String, Object?>();
      expect((r['links'] as List), hasLength(1));
    });

    test('모르는 형태는 쓸 수 있는 값을 알려 준다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      final res = await ask(root, 'read', {'format': 'pdf'});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('text'));
    });

    test('js 는 페이지가 있어야 돈다', () async {
      var res = await ask(root, 'js', {'script': 'return 1;'});
      expect(res['ok'], isFalse, reason: '탭이 없다');

      await ask(root, 'open', {'url': 'https://a.com/'});
      view().evalResult = {'ok': 1};
      res = await ask(root, 'js', {'script': 'return document.title;'});
      expect(res['ok'], isTrue);
      expect(view().lastScript, 'return document.title;');
    });

    test('tabs · name · focus · close 가 목록에 반영된다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      await ask(root, 'name', {'tab': 't1', 'name': '조사'});

      var res = await ask(root, 'tabs');
      var tabs = ((res['result'] as Map)['tabs'] as List)
          .cast<Map<String, Object?>>();
      expect(tabs, hasLength(1));
      expect(tabs.first['name'], '조사');
      expect(tabs.first['active'], isTrue);

      res = await ask(root, 'close', {'tab': 't1'});
      expect(res['ok'], isTrue);
      expect(view().disposed, isTrue);

      res = await ask(root, 'tabs');
      tabs = ((res['result'] as Map)['tabs'] as List)
          .cast<Map<String, Object?>>();
      expect(tabs, isEmpty);
    });

    test('닫은 탭 번호는 다시 쓰이지 않는다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      await ask(root, 'close', {'tab': 't1'});
      final res = await ask(root, 'open', {'url': 'https://b.com/'});
      expect((res['result'] as Map)['tab'], 't2');
    });

    test('없는 탭은 이름을 그대로 말해 준다', () async {
      final res = await ask(root, 'read', {'tab': 't9'});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('t9'));
    });

    test('모르는 op 는 거부한다', () async {
      final res = await ask(root, 'teleport');
      expect(res['ok'], isFalse);
    });

    test('로드 실패는 탭 상태에 남는다', () async {
      nextFailWith = 'net::ERR_NAME_NOT_RESOLVED';
      await ask(root, 'open', {'url': 'https://nope.invalid/'});
      final res = await ask(root, 'tabs');
      final tabs = ((res['result'] as Map)['tabs'] as List)
          .cast<Map<String, Object?>>();
      expect(tabs.first['status'], 'failed');
      expect(tabs.first['error'], contains('ERR_NAME_NOT_RESOLVED'));
    });

    test('끝난 요청은 지우고 로그만 남긴다', () async {
      await ask(root, 'open', {'url': 'https://a.com/'});
      expect(Directory(p.join(root, 'req')).listSync(), isEmpty);
      final logs = Directory(p.join(root, 'log')).listSync();
      expect(logs, isNotEmpty);
      final line = File(logs.first.path).readAsLinesSync().first;
      final rec = (jsonDecode(line) as Map).cast<String, Object?>();
      expect(rec['op'], 'open');
      expect(rec['url'], 'https://a.com/');
      expect(rec['ok'], isTrue);
    });

    test('탭 상한을 넘으면 닫으라고 말해 준다', () async {
      for (var i = 0; i < BrowserController.maxTabs; i++) {
        await controller.newTab();
      }
      final res = await ask(root, 'open', {'url': 'https://a.com/'});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('web_tabs'));
    });
  });
}
