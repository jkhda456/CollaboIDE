import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 백그라운드 명령의 상태.
enum BackgroundStatus { running, exited, killed, unknown }

/// 레지스트리에 들어오는 두 종류.
///
/// 같은 폴더(`.collabo/proc`)를 쓰는 이유는 **사용자에게 둘 다 "돌고 있는 것"**
/// 이기 때문이다 — 좌측 배지도 진행 상태 화면도 합쳐서 보여 주는 편이 맞다.
/// 다른 것은 안을 들여다보는 방법뿐이다(로그 꼬리 ↔ 렌더된 화면).
enum BackgroundKind {
  /// `run_command` — `proc_runner.py` 가 stdout/stderr 를 로그로 흘린다.
  command,

  /// `term_open` — `term_runner.py` 가 PTY 를 열고 화면을 렌더한다.
  terminal,
}

/// `.collabo/proc/<id>/meta.json` 한 건을 표현하는 백그라운드 프로세스.
///
/// 실제 실행/로깅은 Python (`proc_runner.py` / `term_runner.py`)이 담당하고,
/// 여기서는 그 파일 레지스트리를 읽기만 한다(단일 진실원은 디스크의 meta.json).
class BackgroundProcess {
  const BackgroundProcess({
    required this.id,
    required this.dir,
    required this.pid,
    required this.command,
    required this.cwd,
    required this.status,
    this.kind = BackgroundKind.command,
    this.name = '',
    this.hasPty = true,
    this.startedAt,
    this.exitCode,
    this.endedAt,
  });

  final String id;

  /// `<project>/.collabo/proc/<id>` 디렉토리.
  final String dir;
  final int? pid;
  final String command;
  final String cwd;
  final BackgroundStatus status;

  /// 명령인가 터미널인가(meta.json 의 `kind`).
  final BackgroundKind kind;

  /// 터미널에 붙인 짧은 이름(`term_open(name:)`). 없으면 빈 문자열.
  final String name;

  /// 터미널이 진짜 PTY 위에서 도는지. false 면 파이프 폴백이라 대화형이 안 된다.
  final bool hasPty;

  final DateTime? startedAt;
  final int? exitCode;
  final DateTime? endedAt;

  bool get isRunning => status == BackgroundStatus.running;
  bool get isTerminal => kind == BackgroundKind.terminal;

  /// 목록에 보일 이름(터미널은 붙여 둔 이름을 우선한다).
  String get label => name.isNotEmpty ? name : command;

  String get stdoutPath => p.join(dir, 'stdout.log');
  String get stderrPath => p.join(dir, 'stderr.log');
  String get stdinPath => p.join(dir, 'stdin');

  /// 터미널의 렌더된 화면(`term_runner.py` 가 주기적으로 다시 쓴다).
  String get screenPath => p.join(dir, 'screen.json');

  /// 터미널에서 위로 밀려난 줄(ANSI 제거됨).
  String get scrollbackPath => p.join(dir, 'scrollback.txt');

  /// 터미널 제어 통로(줄 단위 JSON — 지금은 `{"resize":[cols,rows]}` 뿐).
  String get ctrlPath => p.join(dir, 'ctrl');

  /// procdir 의 meta.json 을 파싱한다. 없거나 손상됐으면 null.
  static BackgroundProcess? fromDir(String dir) {
    try {
      final f = File(p.join(dir, 'meta.json'));
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      return BackgroundProcess(
        id: (m['id'] as String?) ?? p.basename(dir),
        dir: dir,
        pid: (m['pid'] as num?)?.toInt(),
        command: (m['command'] as String?) ?? '',
        cwd: (m['cwd'] as String?) ?? '',
        status: _parseStatus(m['status'] as String?),
        // 예전 기록에는 `kind` 가 없다 — 없으면 명령으로 읽는다.
        kind: m['kind'] == 'terminal'
            ? BackgroundKind.terminal
            : BackgroundKind.command,
        name: (m['name'] as String?) ?? '',
        hasPty: m['pty'] != false,
        startedAt: _epoch(m['started_at']),
        exitCode: (m['exit_code'] as num?)?.toInt(),
        endedAt: _epoch(m['ended_at']),
      );
    } catch (_) {
      return null;
    }
  }

  static BackgroundStatus _parseStatus(String? s) {
    switch (s) {
      case 'running':
        return BackgroundStatus.running;
      case 'exited':
        return BackgroundStatus.exited;
      case 'killed':
        return BackgroundStatus.killed;
      default:
        return BackgroundStatus.unknown;
    }
  }

  static DateTime? _epoch(Object? v) {
    if (v is num) {
      return DateTime.fromMillisecondsSinceEpoch((v * 1000).round());
    }
    return null;
  }
}

/// 프로젝트의 `.collabo/proc` 디렉토리를 읽어 백그라운드 명령을 추적한다.
///
/// `run_command`(Python)가 detached 로 명령을 띄우고 이 폴더에 상태/로그를
/// 쌓으면, 이 레지스트리가 그것을 목록화하고(좌측 활동 배지 + 프로세스 뷰어),
/// 종료(트리 kill)·표준입력 전달을 제공한다.
class BackgroundProcessRegistry extends ChangeNotifier {
  String? _procRoot;
  List<BackgroundProcess> _processes = const [];
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _debounce;

  List<BackgroundProcess> get processes => List.unmodifiable(_processes);
  int get runningCount => _processes.where((e) => e.isRunning).length;

  /// 프로젝트를 바꾼다(열기/전환/닫기). procRoot 를 재설정하고 감시를 재시작한다.
  void attachProject(String? projectPath) {
    _watch?.cancel();
    _watch = null;
    _debounce?.cancel();
    if (projectPath == null || projectPath.isEmpty) {
      _procRoot = null;
      _processes = const [];
      notifyListeners();
      return;
    }
    _procRoot = p.join(projectPath, '.collabo', 'proc');
    _startWatch();
    refresh();
  }

  void _startWatch() {
    final root = _procRoot;
    if (root == null) return;
    try {
      final dir = Directory(root);
      dir.createSync(recursive: true);
      _watch = dir.watch(recursive: true).listen(
            (_) => _scheduleRefresh(),
            onError: (_) {},
          );
    } catch (_) {
      // watch 미지원/실패 시엔 수동 refresh(패널 오픈)로만 갱신.
    }
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), refresh);
  }

  /// procRoot 를 다시 스캔한다(실행 중 우선, 그다음 최신 시작순).
  void refresh() {
    final root = _procRoot;
    final list = <BackgroundProcess>[];
    if (root != null) {
      final dir = Directory(root);
      if (dir.existsSync()) {
        for (final e in dir.listSync()) {
          if (e is Directory) {
            final bp = BackgroundProcess.fromDir(e.path);
            if (bp != null) list.add(bp);
          }
        }
      }
    }
    list.sort((a, b) {
      if (a.isRunning != b.isRunning) return a.isRunning ? -1 : 1;
      final at = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bt = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bt.compareTo(at);
    });
    _processes = list;
    notifyListeners();
  }

  BackgroundProcess? _byId(String id) {
    for (final e in _processes) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 프로세스 트리를 종료한다. proc_runner 가 곧 meta.json 을 killed/exited 로 갱신한다.
  Future<void> kill(String id) async {
    final pid = _byId(id)?.pid;
    if (pid == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/T', '/F', '/PID', '$pid']);
      } else {
        // 자식은 새 세션/그룹의 리더(pgid == pid)라 음수 pid 로 그룹 전체를 종료.
        final r = await Process.run('kill', ['-TERM', '-$pid']);
        if (r.exitCode != 0) {
          Process.killPid(pid, ProcessSignal.sigterm);
        }
      }
    } catch (_) {
      // best-effort.
    }
    _scheduleRefresh();
  }

  /// 실행 중 프로세스의 stdin 파일에 한 줄을 append 한다(러너가 tail 해 전달).
  ///
  /// 터미널이면 줄 끝을 **CR**(`\r`)로 보낸다 — 터미널에서 Enter 는 CR 이고,
  /// LF 를 보내면 셸이 줄을 실행하지 않고 그대로 앉아 있는 것처럼 보인다.
  Future<void> sendInput(String id, String text) async {
    final proc = _byId(id);
    if (proc == null) return;
    final eol = proc.isTerminal ? '\r' : '\n';
    final data = text.endsWith('\n') || text.endsWith('\r') ? text : '$text$eol';
    await sendRaw(id, data);
  }

  /// 줄바꿈을 **붙이지 않고** 그대로 보낸다(터미널의 ctrl-c·방향키·ESC 용).
  Future<void> sendRaw(String id, String data) async {
    final proc = _byId(id);
    if (proc == null) return;
    try {
      await File(proc.stdinPath)
          .writeAsString(data, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// 터미널의 창 크기를 바꾼다(제어 통로 `ctrl` 에 줄 단위 JSON 으로 붙인다).
  ///
  /// 화면 폭이 달라지면 셸의 줄바꿈 계산이 어긋나므로, 패널이 크기를 알게 되면
  /// 알려 준다. 명령(터미널 아님)에는 창 크기라는 것이 없어 아무것도 하지 않는다.
  Future<void> resizeTerminal(String id, int cols, int rows) async {
    final proc = _byId(id);
    if (proc == null || !proc.isTerminal || !proc.isRunning) return;
    final line = jsonEncode({
      'resize': [cols, rows],
    });
    try {
      await File(proc.ctrlPath)
          .writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
