import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collabo_core/collabo_core.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../tools/tool_executor.dart';
import 'sandbox_console.dart';

/// 샌드박스 상태(설정·좌측 메뉴 표시용).
enum SandboxState { idle, starting, running, failed }

/// **프로젝트 하나의 리눅스 머신**(collaboCore). 도구 계층이 여기서 돈다.
///
/// 프로젝트마다 하나다 — venv 가 프로젝트별이었던 것과 같은 이유이고, 프로젝트 폴더
/// 하나만 `/work` 로 보이는 것이 격리의 요점이다. [ProjectSession] 이 소유한다.
///
/// - **처음 필요할 때 부팅한다**([ready]). 열어 둔 프로젝트를 복원할 때마다 전부
///   부팅하면(각 ~4초 + 첫 파이썬 ~3초) 앱 시작이 무거워진다.
/// - 머신이 죽으면(엔진 종료·커널 패닉) 다음 [ready] 가 새로 부팅한다.
/// - 머신 안의 프로세스는 머신과 함께 사라진다. 그래서 부팅·종료 때
///   `.collabo/proc` 의 샌드박스 기록 중 running 으로 남은 것을 정리한다([sweepStale]).
class ProjectSandbox extends ChangeNotifier {
  ProjectSandbox({
    required this.projectPath,
    required this.toolsDir,
    required this.runtime,
  }) {
    // 터미널의 키 입력 → 머신의 root 셸, 터미널 크기 → 머신 콘솔 크기(셸의 줄바꿈·vi 화면).
    console.input = (data) => unawaited(writeConsole(data).then((_) {}, onError: (_) {}));
    console.resized = (cols, rows) {
      final core = _core;
      if (core != null) unawaited(core.resizeConsole(cols, rows).then((_) {}, onError: (_) {}));
    };
  }

  /// 게스트에서 프로젝트가 보이는 자리. 명령의 기본 cwd 이기도 하다.
  static const String guestWorkspace = '/work';

  /// 게스트에서 기본 도구 모듈(`<appSupport>/python_modules`)이 보이는 자리(읽기 전용).
  static const String guestTools = '/opt/collabo/tools';

  /// 사용자 CLI 도구 스크립트를 복사해 넣는 자리(게스트 메모리 — 재부팅하면 다시 넣는다).
  static const String guestUserTools = '/opt/collabo/user';

  final String projectPath;
  final String toolsDir;
  final CollaboRuntime runtime;

  /// 이 런타임에 네트워크 도구 이미지(`tools.cpio` — curl·ssh·git)가 있는가.
  ///
  /// 같은 릴리스(2026-09-22 밤)부터 python 이미지에 pip 도 들었다. 둘은 함께 들어왔으므로
  /// 에이전트 안내([SandboxToolExecutor.environmentNote])는 이 하나로 가른다. 들여온 복사본은
  /// 둘 다 이 릴리스지만, COLLABO_CORE_RUNTIME 으로 옛 런타임을 가리킬 수 있다 — 없는 것을
  /// 있다고 안내하면 모델이 헛돈다.
  bool get hasNetworkTools => runtime.arguments.contains('--tools-image');

  late final PathMapping paths = PathMapping([
    (projectPath, guestWorkspace),
    (toolsDir, guestTools),
  ]);

  SandboxState _state = SandboxState.idle;
  SandboxState get state => _state;
  String _error = '';
  String get error => _error;

  CollaboCore? _core;
  Future<CollaboCore>? _starting;
  final List<StreamSubscription<Object?>> _subs = [];

  /// 콘솔(root 셸)·네트워크 기록. 샌드박스 화면이 본다 — 알림 통로가 따로다
  /// ([SandboxConsole] 참고). 재부팅해도 이어서 쌓는다(구분선을 긋는다).
  final SandboxConsole console = SandboxConsole();

  /// 지금 머신이 뜬 시각(돌고 있지 않으면 null).
  DateTime? get startedAt => _startedAt;
  DateTime? _startedAt;

  bool get isRunning => _core != null;

  /// 화면에 보일 마운트 목록(호스트 → 게스트, 읽기 전용 여부).
  List<(String, String, bool)> get mounts => [
        (projectPath, guestWorkspace, false),
        (toolsDir, guestTools, true),
      ];

  /// 이 부팅에서 이미 게스트에 넣은 사용자 스크립트(호스트 경로 → 게스트 경로, 내용 지문).
  final Map<String, (String, String)> _staged = {};

  bool _closed = false;

  /// 부팅된 머신. 아직이면 부팅하고, 부팅 중이면 그걸 기다린다.
  Future<CollaboCore> ready() {
    if (_closed) return Future.error(StateError('sandbox closed'));
    final core = _core;
    if (core != null) return Future.value(core);
    return _starting ??= _start();
  }

  Future<CollaboCore> _start() async {
    _state = SandboxState.starting;
    _error = '';
    notifyListeners();
    CollaboCore? booted;
    try {
      // 지난 머신에서 돌던 것은 이미 없다 — 레지스트리가 영원히 running 이지 않게.
      sweepStale();
      // 화면이 이미 크기를 쟀으면 그 크기로 띄운다(아니면 엔진 기본 120×40).
      final size = console.size;
      final core = booted = await CollaboCore.start(
        CollaboConfig(
          quiet: true,
          consoleColumns: size?.$1 ?? 120,
          consoleRows: size?.$2 ?? 40,
          mounts: [
            for (final (host, guest, ro) in mounts)
              Mount(hostPath: host, guestPath: guest, readOnly: ro),
          ],
        ),
        runtime: runtime,
      );
      // 콘솔은 broadcast 라 먼저 붙어야 흘려보내지 않는다. 부팅 메시지는 quiet 로 꺼 뒀다.
      // 준비(예열)가 끝날 때까지는 **가린다** — 그 사이 지나간 첫 프롬프트는 준비가 끝난 뒤
      // Enter 하나로 다시 띄운다(예열 도중 사용자가 친 것과 섞이지 않게).
      console.mark('boot ${_clock(DateTime.now())}');
      var muted = true;
      _subs
        ..add(core.console.listen((bytes) {
          if (!muted) console.addBytes(bytes);
        }))
        ..add(core.networkEvents.listen(console.addEvent));
      // 첫 python 실행은 게스트 프로그램 컴파일 캐시를 채우느라 수 초 걸린다 → 미리 한 번.
      // (devpts 와 콘솔 셸의 제어 터미널은 게스트 /init 이 직접 한다 — 2026-09-22 밤 릴리스부터.
      // 그 전 이미지에는 없어서 앱이 부팅 직후 대신 했다.)
      await core.run('python3 -c pass');
      muted = false;
      if (_closed) {
        unawaited(core.stop());
        throw StateError('sandbox closed');
      }
      _core = core;
      _startedAt = DateTime.now();
      _staged.clear();
      _state = SandboxState.running;
      notifyListeners();
      // 셸 프롬프트는 가려 둔 사이에 지나갔다 — Enter 하나로 다시 띄운다.
      unawaited(writeConsole('\r'));
      unawaited(core.done.then((exit) {
        if (!identical(_core, core)) return;
        _core = null;
        _starting = null;
        _startedAt = null;
        _cancelSubs();
        _state = _closed ? SandboxState.idle : SandboxState.failed;
        _error = _closed ? '' : 'sandbox stopped: ${exit.reason}${exit.message != null ? ' (${exit.message})' : ''}';
        sweepStale();
        notifyListeners();
      }));
      return core;
    } catch (e) {
      // 엔진은 떴는데 그 뒤(예열)에서 실패했으면 엔진을 남기지 않는다.
      _cancelSubs();
      if (booted != null && !identical(_core, booted)) unawaited(booted.stop());
      _starting = null;
      _state = SandboxState.failed;
      _error = '$e';
      notifyListeners();
      rethrow;
    }
  }

  static String _clock(DateTime t) => t.toIso8601String().substring(0, 19).replaceFirst('T', ' ');

  void _cancelSubs() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  /// 머신을 내린다. 세션은 그대로이고, 다음 도구 호출이나 [start] 가 다시 띄운다.
  ///
  /// 그 안에서 돌던 명령·터미널은 머신과 함께 끝난다(기록은 [sweepStale] 이 고친다).
  Future<void> stop() async {
    final starting = _starting;
    if (_core == null && starting != null) {
      // 부팅 중이면 끝날 때까지 기다렸다가 내린다(반쯤 뜬 엔진을 남기지 않게).
      try {
        await starting;
      } catch (_) {}
    }
    final core = _core;
    if (core == null) return;
    _core = null;
    _starting = null;
    _startedAt = null;
    _cancelSubs();
    await core.stop();
    sweepStale();
    console.mark('stopped ${_clock(DateTime.now())}');
    _state = SandboxState.idle;
    _error = '';
    notifyListeners();
  }

  /// 부팅한다(이미 돌고 있으면 아무것도 안 한다). 샌드박스 화면의 "시작".
  Future<void> start() => ready().then((_) {}, onError: (_) {});

  /// 내렸다가 다시 띄운다. 게스트에 넣어 둔 것(사용자 스크립트, 설치한 pip 등 /work 밖)은 사라진다.
  Future<void> restart() async {
    await stop();
    await start();
  }

  /// root 셸에 입력한다(샌드박스 화면의 콘솔). **보낸 순서대로** 도착한다.
  ///
  /// 엔진은 요청마다 스레드를 따로 띄워 처리한다(CollaboCore `protocol.rs`) — `console.write` 를
  /// 연달아 보내면 게스트에 뒤바뀐 순서로 닿을 수 있다(빠른 타이핑, IME 확정 직후의 Enter:
  /// "#" 다음 Enter 가 다음 줄 글자 뒤로 갔다). 그래서 앞의 쓰기가 끝난 뒤에 다음을 보낸다.
  Future<void> writeConsole(String text) {
    final core = _core;
    if (core == null) return Future.value();
    return _consoleTail = _consoleTail
        .then((_) => identical(_core, core) ? core.writeConsole(text) : null)
        .then((_) {}, onError: (_) {});
  }

  Future<void> _consoleTail = Future.value();

  /// 사용자 CLI 도구 스크립트를 게스트에 복사한다(바뀌었을 때만). 게스트 경로를 준다.
  ///
  /// 스크립트 **한 파일**만 옮긴다 — 옆 파일을 import 하는 스크립트는 게스트에서
  /// 못 찾는다(마운트는 부팅 때 정해져 실행 중에 늘릴 수 없다).
  Future<String?> stage(String hostPath) async {
    try {
      final core = await ready();
      final file = File(hostPath);
      final stat = await file.stat();
      final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      final prev = _staged[hostPath];
      if (prev != null && prev.$2 == stamp) return prev.$1;
      // 같은 이름의 스크립트가 다른 폴더에 있을 수 있어 슬롯을 나눈다(부팅마다 새로 넣는다).
      final guest = prev?.$1 ?? '$guestUserTools/${_staged.length}/${p.basename(hostPath)}';
      await core.writeFile(guest, await file.readAsBytes());
      _staged[hostPath] = (guest, stamp);
      return guest;
    } catch (_) {
      return null;
    }
  }

  /// 게스트의 백그라운드 프로세스 그룹을 끝낸다([BackgroundProcessRegistry.kill] 이 부른다).
  ///
  /// ★ **호스트에서 이 pid 를 kill 하면 안 된다** — 게스트 pid 라 호스트의 엉뚱한
  /// 프로세스가 죽는다. 터미널은 대화형 셸이 SIGTERM 을 무시하므로 HUP 부터 보낸다.
  Future<void> killGroup(int pid, {bool terminal = false}) async {
    final core = _core;
    if (core == null) return; // 머신이 없으면 그 프로세스도 이미 없다
    await core.exec(
      ['python3', '-c', _killScript, '$pid', ...(terminal ? ['HUP', 'TERM', 'KILL'] : ['TERM', 'KILL'])],
      timeout: const Duration(seconds: 15),
    ).then((_) {}, onError: (_) {});
  }

  /// argv: pid, 신호 이름들. 그룹(없으면 그 pid)에 차례로 보내고, 끝나면 멈춘다.
  static const String _killScript = '''
import os, signal, sys, time
pid = int(sys.argv[1])
for name in sys.argv[2:]:
    sig = getattr(signal, "SIG" + name)
    try:
        try:
            os.killpg(pid, sig)
        except OSError:
            os.kill(pid, sig)
    except OSError:
        sys.exit(0)
    for _ in range(15):
        time.sleep(0.1)
        try:
            os.kill(pid, 0)
        except OSError:
            sys.exit(0)
''';

  /// `.collabo/proc` 에서 **샌드박스에서 돌았고 아직 running 인** 기록을 끝난 것으로 고친다.
  ///
  /// 머신이 새로 뜨거나 내려가면 그 안의 프로세스는 없다. 러너(게스트)가 meta 를
  /// 고칠 기회도 없었으므로 여기서 대신 적는다. 호스트 프로세스 기록은 건드리지 않는다.
  void sweepStale() => sweepStaleIn(projectPath);

  /// [sweepStale] 의 몸통. 세션을 **열 때**도 부른다 — 앱이 죽었으면 지난 머신의
  /// 기록이 running 으로 남아 있고, 그때는 아직 샌드박스 객체가 없다.
  static void sweepStaleIn(String projectPath) {
    try {
      final root = Directory(p.join(projectPath, '.collabo', 'proc'));
      if (!root.existsSync()) return;
      for (final d in root.listSync().whereType<Directory>()) {
        final f = File(p.join(d.path, 'meta.json'));
        if (!f.existsSync()) continue;
        final meta = jsonDecode(f.readAsStringSync());
        if (meta is! Map || meta['sandbox'] != true || meta['status'] != 'running') continue;
        meta['status'] = 'killed';
        meta['ended_at'] = DateTime.now().millisecondsSinceEpoch / 1000;
        meta['note'] = 'the sandbox it ran in has stopped';
        f.writeAsStringSync(jsonEncode(meta));
      }
    } catch (_) {
      // 정리는 부가 작업이다 — 실패해도 부팅은 계속한다.
    }
  }

  /// 머신을 내린다(세션 닫기). 두 번 불러도 안전하다.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final core = _core;
    _core = null;
    _starting = null;
    _startedAt = null;
    _cancelSubs();
    if (core != null) await core.stop();
    sweepStale();
    _state = SandboxState.idle;
  }
}

/// 도구를 [ProjectSandbox] 의 게스트 CPython 으로 실행한다.
class SandboxToolExecutor extends ToolExecutor {
  SandboxToolExecutor(this.sandbox);

  final ProjectSandbox sandbox;
  PathMapping get _paths => sandbox.paths;

  static int _seq = 0;

  @override
  String get kind => 'sandbox';

  @override
  String? execPath(String hostPath) => _paths.toGuest(hostPath);

  /// 프로젝트 안의 스크립트는 이미 보인다. 밖이면 게스트로 복사한다.
  @override
  Future<String?> stageScript(String hostPath) async =>
      _paths.toGuest(hostPath) ?? await sandbox.stage(hostPath);

  @override
  Map<String, Object?> execArgs(Map<String, Object?> args) =>
      (_paths.argsToGuest(args) as Map).cast<String, Object?>();

  @override
  Object? hostify(Object? value) => _paths.resultToHost(value);

  @override
  String get environmentNote =>
      'Execution environment: your tools run inside an isolated Linux sandbox '
      '${sandbox.hasNetworkTools ? _withNetworkTools : _withoutNetworkTools}'
      'and nothing from the user\'s computer except the project folder. Inside '
      'commands (run_command, terminals) the project folder is `$guestWorkspaceName` '
      'and is the current directory — use relative paths there. File tools accept '
      'and report the project\'s normal paths.';

  static const String guestWorkspaceName = ProjectSandbox.guestWorkspace;

  static const String _withNetworkTools =
      '(busybox shell + Python 3.13 with its standard library, pip and the openai SDK; '
      'curl, wget, git and ssh are available). Packages installed with pip live in the '
      'sandbox only and are gone after it restarts. There is no node or compiler, ';

  static const String _withoutNetworkTools =
      '(busybox shell + Python 3.13 with its standard library and the openai SDK). '
      'There is no git, node, compiler or package manager (pip is not installed), ';

  @override
  Future<ToolProcessResult> run(
    String script,
    List<String> args, {
    Map<String, String> env = const {},
    String? stdin,
    String? workingDirectory,
    Duration? timeout,
    void Function(ToolHandle handle)? onStart,
  }) async {
    final core = await sandbox.ready();
    final guestScript = _paths.toGuest(script) ?? script;
    final guestEnv = <String, String>{
      for (final e in env.entries) e.key: _paths.toGuest(e.value) ?? e.value,
      // 게스트에서 우리는 root 다 — 권한 상승을 요구할 일이 없다.
      'COLLABO_ELEVATED': '1',
      // 러너가 meta.json 에 남긴다 → 앱이 이 pid 를 호스트에서 kill 하지 않는다.
      'COLLABO_SANDBOX': '1',
      'PYTHONDONTWRITEBYTECODE': '1',
    };
    final cwd = workingDirectory == null
        ? ProjectSandbox.guestWorkspace
        : (_paths.toGuest(workingDirectory) ?? ProjectSandbox.guestWorkspace);
    // 엔진에는 실행 중인 exec 를 끊는 메서드가 없다 → pid 를 파일로 남기고 그걸 kill 한다.
    final pidFile = '/tmp/collabo-tool-${++_seq}.pid';
    final handle = _SandboxHandle(core, pidFile);
    onStart?.call(handle);
    try {
      final r = await core.exec(
        ['/bin/sh', '-c', 'echo \$\$ > $pidFile; exec python3 "\$@"', 'sh', guestScript, ...args],
        cwd: cwd,
        env: guestEnv,
        stdin: stdin == null ? null : utf8.encode(stdin),
        // 도구에는 기본 타임아웃이 없다(run_wait) — 엔진 기본값(2분)에 걸리지 않게 길게.
        timeout: timeout ?? const Duration(hours: 24),
      );
      if (r.timedOut) {
        return const ToolProcessResult(exitCode: -1, stdout: '', timedOut: true);
      }
      return ToolProcessResult(
        exitCode: r.exitCode ?? -1,
        stdout: r.stdoutText,
        stderr: r.stderrText,
      );
    } finally {
      handle._finish();
      unawaited(core.run('rm -f $pidFile').then((_) {}, onError: (_) {}));
    }
  }
}

class _SandboxHandle implements ToolHandle {
  _SandboxHandle(this._core, this._pidFile);
  final CollaboCore _core;
  final String _pidFile;
  final _done = Completer<void>();

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void kill() {
    if (_done.isCompleted) return;
    unawaited(_core
        .run('[ -f $_pidFile ] && kill -KILL \$(cat $_pidFile) 2>/dev/null; true')
        .then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> get done => _done.future;
}
