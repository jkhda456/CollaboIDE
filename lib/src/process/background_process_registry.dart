import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// 백그라운드 명령의 상태.
enum BackgroundStatus { running, exited, killed, unknown }

/// `.collabo/proc/<id>/meta.json` 한 건을 표현하는 백그라운드 프로세스.
///
/// 실제 실행/로깅은 Python `proc_runner.py` 가 담당하고, 여기서는 그 파일
/// 레지스트리를 읽기만 한다(단일 진실원은 디스크의 meta.json/로그 파일).
class BackgroundProcess {
  const BackgroundProcess({
    required this.id,
    required this.dir,
    required this.pid,
    required this.command,
    required this.cwd,
    required this.status,
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
  final DateTime? startedAt;
  final int? exitCode;
  final DateTime? endedAt;

  bool get isRunning => status == BackgroundStatus.running;

  String get stdoutPath => p.join(dir, 'stdout.log');
  String get stderrPath => p.join(dir, 'stderr.log');
  String get stdinPath => p.join(dir, 'stdin');

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

  /// 실행 중 프로세스의 stdin 파일에 입력을 append 한다(proc_runner 가 tail 해 전달).
  Future<void> sendInput(String id, String text) async {
    final proc = _byId(id);
    if (proc == null) return;
    final data = text.endsWith('\n') ? text : '$text\n';
    try {
      await File(proc.stdinPath)
          .writeAsString(data, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _watch?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
