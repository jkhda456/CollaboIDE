import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'browser_controller.dart';
import 'browser_tab.dart';

/// 파이썬 도구 ↔ 네이티브 브라우저의 **파일 통로**.
///
/// ```
/// <project>/.collabo/browser/
/// ├── req/<id>.json      파이썬 → 네이티브 요청
/// ├── res/<id>.json      네이티브 → 파이썬 응답
/// └── log/<날짜>.jsonl    끝난 요청 한 줄씩 (사람이 읽는 기록)
/// ```
///
/// **왜 파일인가**: 백그라운드 명령 레지스트리(`.collabo/proc`)와 같은 결이다 —
/// 포트를 열지 않고, 무슨 일이 있었는지가 디스크에 그대로 남는다. 에이전트가
/// 무엇을 검색하고 무엇을 읽었는지는 감사할 수 있어야 하는 종류의 기록이다.
/// 지연은 문제가 되지 않는다 — 어차피 페이지 로드가 통로보다 훨씬 느리다.
///
/// **왜 동사가 이렇게 얄팍한가**: 검색엔진 지식은 전부 파이썬에 둔다. 이 통로는
/// "탭을 열어라 · 이 URL 로 가라 · 지금 페이지를 내놔라 · 이 JS 를 돌려라" 뿐이고,
/// 새 검색엔진은 파이썬 쪽만 고쳐서 는다.
class BrowserChannel {
  BrowserChannel(this.controller);

  final BrowserController controller;

  /// `<project>/.collabo/browser`. 프로젝트가 없으면 null(통로도 없다).
  String? _root;

  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _poll;

  /// 이미 집어 든 요청 id. 같은 파일 이벤트가 여러 번 와도 한 번만 처리한다.
  final Set<String> _seen = {};

  /// 파일 감시가 못 미더운 환경(네트워크 드라이브 등)을 위한 저속 스캔 주기.
  static const Duration _pollInterval = Duration(milliseconds: 500);

  /// 남은 요청·응답 파일을 치우는 기준 나이. 파이썬이 죽어서 응답을 못 가져간
  /// 경우에도 폴더가 무한정 자라지 않게 한다.
  static const Duration _staleAfter = Duration(minutes: 10);

  String? get root => _root;

  /// 프로젝트를 바꾼다(열기/전환/닫기). 통로를 다시 걸고 감시를 재시작한다.
  void attachProject(String? projectPath) {
    _watch?.cancel();
    _watch = null;
    _poll?.cancel();
    _poll = null;
    _seen.clear();
    if (projectPath == null || projectPath.isEmpty) {
      _root = null;
      return;
    }
    _root = p.join(projectPath, '.collabo', 'browser');
    _start();
  }

  void _start() {
    final root = _root;
    if (root == null) return;
    try {
      Directory(p.join(root, 'req')).createSync(recursive: true);
      Directory(p.join(root, 'res')).createSync(recursive: true);
      Directory(p.join(root, 'log')).createSync(recursive: true);
      _sweep();
      _watch = Directory(p.join(root, 'req'))
          .watch()
          .listen((_) => _scan(), onError: (_) {});
    } catch (_) {
      // 감시를 못 걸어도 아래 폴링이 받아 준다.
    }
    _poll = Timer.periodic(_pollInterval, (_) {
      _scan();
      // 응답을 못 가져간 파일 치우기. 파이썬이 중간에 죽는 흔한 경우는 사용자가
      // 중지를 눌러 도구 프로세스가 죽은 때다 — 그때 `res` 가 주인 없이 남는다.
      if (++_ticks % _sweepEvery == 0) _sweep();
    });
    _scan();
  }

  var _ticks = 0;

  /// 몇 번의 폴링마다 한 번 쓸 것인가(500ms × 120 = 1분).
  static const int _sweepEvery = 120;

  /// `req/` 를 훑어 아직 안 본 요청을 집어 든다.
  void _scan() {
    final root = _root;
    if (root == null) return;
    final dir = Directory(p.join(root, 'req'));
    if (!dir.existsSync()) return;
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final id = p.basenameWithoutExtension(e.path);
      if (!_seen.add(id)) continue;
      unawaited(_handleFile(e, id));
    }
  }

  Future<void> _handleFile(File file, String id) async {
    final started = DateTime.now();
    Map<String, Object?> req;
    try {
      req = (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
    } catch (e) {
      // 반쯤 쓰인 파일을 집었을 수 있다. 한 번 더 본다 — 파이썬은 tmp 에 쓰고
      // rename 하므로 정상 경로에서는 일어나지 않아야 한다.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      try {
        req =
            (jsonDecode(await file.readAsString()) as Map).cast<String, Object?>();
      } catch (_) {
        await _respond(id, {'ok': false, 'error': 'malformed request: $e'});
        return;
      }
    }
    final op = (req['op'] as String?) ?? '';
    final args = (req['args'] as Map?)?.cast<String, Object?>() ?? const {};
    Map<String, Object?> res;
    try {
      res = {'ok': true, 'result': await _dispatch(op, args)};
    } on BrowserException catch (e) {
      res = {'ok': false, 'error': e.message};
    } catch (e) {
      res = {'ok': false, 'error': '$e'};
    }
    await _respond(id, res);
    await _log(id, op, args, res, DateTime.now().difference(started));
    try {
      await file.delete();
    } catch (_) {}
  }

  /// 통로가 아는 **모든** 동사. 검색엔진은 여기 없다(위 클래스 주석).
  Future<Object?> _dispatch(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'tabs':
        return {'tabs': controller.tabsJson()};

      case 'open':
        final url = (args['url'] as String?) ?? '';
        if (url.isEmpty) throw const BrowserException('open needs a url');
        final tab = await controller.openUrl(
          url,
          tabId: _tabArg(args),
          name: (args['name'] as String?) ?? '',
          owner: TabOwner.agent,
          timeout: _timeoutArg(args),
        );
        return tab.toJson();

      case 'read':
        final id = _requireTab(args);
        return controller.readPage(
          id,
          format: (args['format'] as String?) ?? 'text',
          maxChars: (args['max_chars'] as num?)?.toInt(),
        );

      case 'js':
        final id = _requireTab(args);
        final body = (args['script'] as String?) ?? '';
        if (body.isEmpty) throw const BrowserException('js needs a script');
        return {'value': await controller.evalJs(id, body, timeout: _timeoutArg(args))};

      case 'close':
        final id = _requireTab(args);
        await controller.closeTab(id);
        return {'closed': id};

      case 'nav':
        final id = _requireTab(args);
        final action = (args['action'] as String?) ?? '';
        await controller.navigateAction(id, action);
        if (action != 'stop') {
          await controller.waitForLoad(id, timeout: _timeoutArg(args));
        }
        return (_tabById(id) ?? const BrowserTab(id: '')).toJson();

      case 'focus':
        final id = _requireTab(args);
        controller.activate(id);
        return {'tab': id};

      case 'name':
        final id = _requireTab(args);
        controller.rename(id, (args['name'] as String?) ?? '');
        return (_tabById(id) ?? const BrowserTab(id: '')).toJson();

      case 'wait':
        final id = _requireTab(args);
        await controller.waitForLoad(id, timeout: _timeoutArg(args));
        return (_tabById(id) ?? const BrowserTab(id: '')).toJson();

      default:
        throw BrowserException('unknown browser op: $op');
    }
  }

  BrowserTab? _tabById(String id) {
    for (final t in controller.tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// 탭 인자. 비어 있으면 null(= 새 탭을 열라는 뜻).
  static String? _tabArg(Map<String, Object?> args) {
    final v = args['tab'];
    final s = v is String ? v.trim() : '';
    return s.isEmpty ? null : s;
  }

  /// 탭 인자. **비어 있으면 활성 탭으로 떨어진다** — 에이전트가 탭 하나만 쓰는
  /// 흔한 경우에 매번 id 를 적지 않아도 되게 한다(§도구 인자를 관대하게).
  String _requireTab(Map<String, Object?> args) {
    final id = _tabArg(args) ?? controller.activeId;
    if (id.isEmpty) {
      throw const BrowserException(
          'no browser tab is open. Use web_open(url) first.');
    }
    return id;
  }

  static Duration? _timeoutArg(Map<String, Object?> args) {
    final ms = (args['timeout_ms'] as num?)?.toInt();
    if (ms == null || ms <= 0) return null;
    return Duration(milliseconds: ms.clamp(1000, 180000));
  }

  /// 응답 파일을 **원자적으로** 쓴다(tmp → rename). 파이썬이 반쯤 쓰인 JSON 을
  /// 읽는 일이 없어야 한다.
  Future<void> _respond(String id, Map<String, Object?> body) async {
    final root = _root;
    if (root == null) return;
    try {
      final dest = p.join(root, 'res', '$id.json');
      final tmp = File('$dest.tmp');
      await tmp.writeAsString(jsonEncode({'id': id, ...body}), flush: true);
      await tmp.rename(dest);
    } catch (_) {
      // 응답을 못 쓰면 파이썬이 타임아웃으로 끝난다(도구 오류로 보고된다).
    }
  }

  /// 끝난 요청을 한 줄 남긴다. **이 통로의 값어치 절반이 이 기록이다** —
  /// 에이전트가 어디를 돌아다녔는지 사람이 나중에 그대로 읽을 수 있다.
  Future<void> _log(
    String id,
    String op,
    Map<String, Object?> args,
    Map<String, Object?> res,
    Duration took,
  ) async {
    final root = _root;
    if (root == null) return;
    final now = DateTime.now();
    final day = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    // 본문(페이지 내용)은 남기지 않는다 — 로그가 곧 수십 MB 가 된다. 무엇을
    // 했는지와 얼마나 받았는지만 남긴다.
    final result = res['result'];
    final line = jsonEncode({
      'ts': now.toIso8601String(),
      'id': id,
      'op': op,
      'tab': args['tab'],
      'url': args['url'],
      'format': args['format'],
      'ok': res['ok'],
      if (res['error'] != null) 'error': res['error'],
      'ms': took.inMilliseconds,
      if (result is Map && result['content'] is String)
        'chars': (result['content'] as String).length,
    });
    try {
      await File(p.join(root, 'log', '$day.jsonl'))
          .writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 오래 남은 요청·응답 파일을 치운다(파이썬이 중간에 죽은 경우). 로그는 둔다.
  void _sweep() {
    final root = _root;
    if (root == null) return;
    final cutoff = DateTime.now().subtract(_staleAfter);
    for (final sub in ['req', 'res']) {
      final dir = Directory(p.join(root, sub));
      if (!dir.existsSync()) continue;
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        try {
          if (e.statSync().modified.isBefore(cutoff)) e.deleteSync();
        } catch (_) {}
      }
    }
  }

  void dispose() {
    _watch?.cancel();
    _poll?.cancel();
  }
}
