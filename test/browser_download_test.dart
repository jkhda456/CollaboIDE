import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_ide/src/browser/browser_channel.dart';
import 'package:collabo_ide/src/browser/browser_controller.dart';
import 'package:collabo_ide/src/browser/platform_browser_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 다운로드를 **페이지 쪽에서** 흉내 내는 가짜 웹뷰.
///
/// `downloadToFile` 이 실제로 주입하는 스크립트를 보고 대답한다 — fetch 스크립트가
/// 오면 헤더를, 조각 스크립트가 오면 **거기 박힌 offset/count 그대로** 잘라
/// base64 로 준다. 그래서 이 대역은 청크 계산까지 같이 검증한다(오프셋이 틀리면
/// 내용이 어긋나서 바로 드러난다).
class _FakeView implements PlatformBrowserView {
  _FakeView();

  final StreamController<BrowserViewEvent> _events =
      StreamController<BrowserViewEvent>.broadcast();

  /// 서버가 준 것으로 칠 바이트.
  List<int> body = const [];

  int status = 200;
  String contentType = 'application/octet-stream';
  String disposition = '';

  /// 비어 있지 않으면 fetch 가 실패한 것으로 대답한다.
  String fetchError = '';

  /// 이 조각 번호부터는 빈 문자열을 준다(페이지가 옮겨 간 상황).
  int? dropFromChunk;

  /// 응답에 실을 최종 URL(리다이렉트 흉내).
  String finalUrl = '';

  final List<String> scripts = [];
  int chunkCalls = 0;
  var cleaned = false;

  @override
  Future<void> initialize({String? userAgent}) async {}

  @override
  Stream<BrowserViewEvent> get events => _events.stream;

  @override
  Future<void> loadUrl(String url) async {
    scheduleMicrotask(() {
      if (_events.isClosed) return;
      _events.add(BrowserViewEvent(url: url, title: 't', loading: false));
    });
  }

  @override
  Future<void> goBack() async {}
  @override
  Future<void> goForward() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> stopLoading() async {}

  @override
  Future<Object?> evalJs(String body_,
      {Duration timeout = const Duration(seconds: 30)}) async {
    scripts.add(body_);
    if (body_.contains('delete (window.__collaboDl')) {
      cleaned = true;
      return true;
    }
    if (body_.contains('fetch(')) {
      if (fetchError.isNotEmpty) {
        return {'ok': false, 'error': fetchError};
      }
      return {
        'ok': true,
        'status': status,
        'size': body.length,
        'type': contentType,
        'disposition': disposition,
        'url': finalUrl,
      };
    }
    if (body_.contains('btoa(')) {
      final n = chunkCalls++;
      if (dropFromChunk != null && n >= dropFromChunk!) return '';
      final m = RegExp(r'var s = (\d+), e = Math\.min\(s \+ (\d+)')
          .firstMatch(body_);
      if (m == null) return '';
      final start = int.parse(m.group(1)!);
      final count = int.parse(m.group(2)!);
      final end = (start + count) > body.length ? body.length : start + count;
      if (start >= end) return '';
      return base64.encode(body.sublist(start, end));
    }
    return null;
  }

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

void main() {
  late Directory tmp;
  late _FakeView view;
  late BrowserController ctrl;

  /// 페이지가 열려 있는 탭 하나를 만든다 — 다운로드는 **그 페이지의 세션**으로
  /// 하는 것이라 빈 탭에서는 시작할 수 없다.
  Future<String> openTab([String url = 'https://site.test/page']) async {
    final tab = await ctrl.openUrl(url);
    return tab.id;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_dl_');
    view = _FakeView();
    ctrl = BrowserController(viewFactory: () => view);
  });

  tearDown(() async {
    ctrl.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('페이지가 받은 바이트가 그대로 파일이 된다', () async {
    view.body = utf8.encode('hello download');
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/a.txt', destDir: tmp.path);

    expect(out['bytes'], 14);
    expect(out['name'], 'a.txt');
    expect(File(out['path'] as String).readAsStringSync(), 'hello download');
    expect(view.cleaned, isTrue, reason: '페이지에 버퍼를 남기면 안 된다');
  });

  /// ★ 조각으로 나눠 받는 것이 이 구현의 핵심이다 — base64 로 부풀어 메시지
  /// 채널을 타므로 통째로는 못 가져온다. 이어 붙이는 자리가 어긋나면 파일이
  /// 조용히 망가지므로, 경계를 넘는 크기로 바이트 하나까지 본다.
  test('조각 경계를 넘는 파일도 정확히 이어 붙인다', () async {
    final size = BrowserController.downloadChunkBytes * 2 + 1234;
    view.body = List<int>.generate(size, (i) => i % 251);
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/big.bin', destDir: tmp.path);

    final bytes = File(out['path'] as String).readAsBytesSync();
    expect(bytes.length, size);
    expect(bytes, orderedEquals(view.body));
    expect(view.chunkCalls, 3, reason: '512KB 씩 세 번이면 충분하다');
  });

  test('Content-Disposition 의 이름을 쓴다', () async {
    view.body = [1, 2, 3];
    view.disposition = 'attachment; filename="report final.pdf"';
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/d?id=9', destDir: tmp.path);

    expect(out['name'], 'report final.pdf');
  });

  /// 비ASCII 이름은 `filename*=UTF-8''…` 로 온다. 한국어 파일명이 그렇다.
  test("filename*= 가 있으면 그쪽이 이긴다", () async {
    view.body = [1];
    view.disposition =
        "attachment; filename=\"_.pdf\"; filename*=UTF-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf";
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/d', destDir: tmp.path);

    expect(out['name'], '보고서.pdf');
  });

  test('헤더에 이름이 없으면 URL 끝을 쓴다', () async {
    view.body = [1];
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/files/setup.exe?v=2', destDir: tmp.path);

    expect(out['name'], 'setup.exe');
  });

  test('이름을 전혀 못 정하면 기본 이름으로 떨어진다', () async {
    view.body = [1];
    final id = await openTab();

    final out =
        await ctrl.downloadToFile(id, 'https://site.test/', destDir: tmp.path);

    expect(out['name'], 'download.bin');
  });

  /// **덮어쓰지 않는다** — 받은 파일이 조용히 사라지는 쪽이 훨씬 나쁘다.
  test('같은 이름이 있으면 비켜 간다', () async {
    File(p.join(tmp.path, 'a.txt')).writeAsStringSync('먼저 있던 것');
    view.body = utf8.encode('new');
    final id = await openTab();

    final out = await ctrl.downloadToFile(
        id, 'https://site.test/a.txt', destDir: tmp.path);

    expect(out['name'], 'a_1.txt');
    expect(File(p.join(tmp.path, 'a.txt')).readAsStringSync(), '먼저 있던 것');
  });

  /// 서버가 주는 이름을 그대로 경로에 붙이면 `../../` 한 줄로 프로젝트 밖에 쓴다.
  test('이름에 경로가 섞여 와도 이름 하나로 깎는다', () {
    expect(BrowserController.sanitizeDownloadName('../../etc/passwd'), 'passwd');
    expect(BrowserController.sanitizeDownloadName(r'..\..\win.ini'), 'win.ini');
    expect(BrowserController.sanitizeDownloadName('..'), 'download.bin');
    expect(BrowserController.sanitizeDownloadName('  .hidden  '), 'hidden');
    expect(BrowserController.sanitizeDownloadName('a<b>c:d?.txt'), 'abcd.txt');
    expect(BrowserController.sanitizeDownloadName(''), 'download.bin');
    expect(BrowserController.sanitizeDownloadName('ok.zip'), 'ok.zip');
  });

  test('상한을 넘으면 받지 않고 파일도 안 남긴다', () async {
    view.body = List<int>.filled(5000, 7);
    final id = await openTab();

    await expectLater(
      ctrl.downloadToFile(id, 'https://site.test/big.bin',
          destDir: tmp.path, maxBytes: 1000),
      throwsA(isA<BrowserException>()
          .having((e) => e.message, 'message', contains('too large'))),
    );
    expect(Directory(tmp.path).listSync(), isEmpty);
    expect(view.cleaned, isTrue, reason: '거절해도 페이지 버퍼는 치운다');
  });

  test('서버가 4xx 를 주면 실패로 본다', () async {
    view.body = utf8.encode('Not Found');
    view.status = 404;
    final id = await openTab();

    await expectLater(
      ctrl.downloadToFile(id, 'https://site.test/nope', destDir: tmp.path),
      throwsA(isA<BrowserException>()
          .having((e) => e.message, 'message', contains('404'))),
    );
    expect(Directory(tmp.path).listSync(), isEmpty);
  });

  /// CORS 로 막힌 이유가 그대로 올라와야 파이썬이 "출처를 바꿔 다시" 를 결정한다.
  test('페이지가 못 받으면 그 이유를 그대로 올린다', () async {
    view.fetchError = 'TypeError: Failed to fetch';
    final id = await openTab();

    await expectLater(
      ctrl.downloadToFile(id, 'https://cdn.other.test/a.zip', destDir: tmp.path),
      throwsA(isA<BrowserException>()
          .having((e) => e.message, 'message', contains('Failed to fetch'))),
    );
  });

  /// 받는 도중 페이지가 옮겨 가면 버퍼가 사라진다 — **반쯤 쓴 파일을 남기면**
  /// 다음 도구가 그걸 온전한 파일로 읽는다.
  test('중간에 끊기면 반쯤 쓴 파일을 지운다', () async {
    view.body = List<int>.filled(BrowserController.downloadChunkBytes * 2, 3);
    view.dropFromChunk = 1;
    final id = await openTab();

    await expectLater(
      ctrl.downloadToFile(id, 'https://site.test/big.bin', destDir: tmp.path),
      throwsA(isA<BrowserException>()
          .having((e) => e.message, 'message', contains('navigated away'))),
    );
    expect(Directory(tmp.path).listSync(), isEmpty);
  });

  test('http/https 가 아니면 받지 않는다', () async {
    final id = await openTab();
    await expectLater(
      ctrl.downloadToFile(id, 'file:///etc/passwd', destDir: tmp.path),
      throwsA(isA<BrowserException>()),
    );
  });

  test('페이지가 없는 탭에서는 시작하지 않는다', () async {
    final id = await ctrl.newTab();
    await expectLater(
      ctrl.downloadToFile(id, 'https://site.test/a.zip', destDir: tmp.path),
      throwsA(isA<BrowserException>()
          .having((e) => e.message, 'message', contains('no page loaded'))),
    );
  });

  test('링크 목록에 파일 힌트가 같이 온다', () async {
    final id = await openTab();
    // `links` 스크립트는 DOM 을 훑으므로 가짜 뷰가 흉내 낼 수 없다 — 대신
    // 스크립트 자체가 `download` 속성과 확장자를 챙기는지를 본다.
    await ctrl.readPage(id, format: 'links');
    final script = view.scripts.last;
    expect(script, contains("getAttribute('download')"));
    expect(script, contains('rec.ext'));
  });

  // ===================================================== 통로(파일 채널) 쪽

  group('파일 통로', () {
    late Directory project;
    late BrowserChannel channel;

    Future<Map<String, Object?>> ask(String op,
        [Map<String, Object?> args = const {}]) async {
      final root = p.join(project.path, '.collabo', 'browser');
      final id = 'r${DateTime.now().microsecondsSinceEpoch}';
      final reqDir = Directory(p.join(root, 'req'))..createSync(recursive: true);
      final tmpFile = File(p.join(reqDir.path, '$id.json.tmp'));
      await tmpFile.writeAsString(jsonEncode({'id': id, 'op': op, 'args': args}));
      await tmpFile.rename(p.join(reqDir.path, '$id.json'));
      final res = File(p.join(root, 'res', '$id.json'));
      for (var i = 0; i < 200; i++) {
        if (await res.exists()) {
          final body = jsonDecode(await res.readAsString());
          return (body as Map).cast<String, Object?>();
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('통로가 $op 에 답하지 않았다');
    }

    setUp(() async {
      project = await Directory.systemTemp.createTemp('collabo_dlproj_');
      channel = BrowserChannel(ctrl)..attachProject(project.path);
    });

    tearDown(() async {
      channel.dispose();
      if (await project.exists()) await project.delete(recursive: true);
    });

    test('download op 가 파일을 만들고 결과를 돌려준다', () async {
      view.body = utf8.encode('via channel');
      final id = await openTab();
      final dir = p.join(project.path, '.collabo', 'downloads');

      final res = await ask('download',
          {'tab': id, 'url': 'https://site.test/x.txt', 'dir': dir});

      expect(res['ok'], isTrue, reason: '${res['error']}');
      final result = (res['result'] as Map).cast<String, Object?>();
      expect(result['name'], 'x.txt');
      expect(File(result['path'] as String).readAsStringSync(), 'via channel');
    });

    /// ★ 파이썬도 이미 워크스페이스로 가두지만, **디스크에 쓰는 유일한 브라우저
    /// 동사**라 통로에서 한 번 더 본다 — 파일 도구의 경계를 브라우저로 우회하는
    /// 길이 되면 안 된다.
    test('프로젝트 밖 폴더는 통로가 막는다', () async {
      view.body = [1, 2, 3];
      final id = await openTab();

      final res = await ask('download', {
        'tab': id,
        'url': 'https://site.test/x.txt',
        'dir': p.join(tmp.path, 'escape'),
      });

      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('outside the project'));
      expect(Directory(p.join(tmp.path, 'escape')).existsSync(), isFalse,
          reason: '거절한 폴더에 뭔가 남기면 안 된다');
    });

    test('dir 없이 부르면 거절한다', () async {
      final id = await openTab();
      final res =
          await ask('download', {'tab': id, 'url': 'https://site.test/x.txt'});
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('dir'));
    });

    test('url 없이 부르면 거절한다', () async {
      final id = await openTab();
      final res = await ask('download', {
        'tab': id,
        'dir': p.join(project.path, 'd'),
      });
      expect(res['ok'], isFalse);
      expect('${res['error']}', contains('url'));
    });

    /// 로그가 이 통로 값어치의 절반이다 — 내려받기는 **무엇이 디스크에 생겼는지**가
    /// 핵심이라 경로와 크기를 같이 남긴다.
    test('로그에 경로와 크기가 남는다', () async {
      view.body = utf8.encode('logged');
      final id = await openTab();
      await ask('download', {
        'tab': id,
        'url': 'https://site.test/y.txt',
        'dir': p.join(project.path, 'out'),
      });

      final logDir = Directory(p.join(project.path, '.collabo', 'browser', 'log'));
      final lines = logDir
          .listSync()
          .whereType<File>()
          .expand((f) => f.readAsLinesSync())
          .map((l) => jsonDecode(l) as Map)
          .where((m) => m['op'] == 'download')
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single['bytes'], 6);
      expect('${lines.single['path']}', endsWith('y.txt'));
    });
  });
}
