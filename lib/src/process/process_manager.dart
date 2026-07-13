import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'launcher_process.dart';
import 'python_environment.dart';

/// 런쳐 실행 요청 명세.
class LaunchSpec {
  const LaunchSpec({
    required this.scriptPath,
    this.args = const [],
    this.elevated = false,
    this.label,
    this.workingDirectory,
  });

  final String scriptPath;
  final List<String> args;

  /// 프로세스별 on-demand 관리자 권한 상승.
  final bool elevated;
  final String? label;
  final String? workingDirectory;
}

/// 다수의 Python 런쳐 프로세스를 동시에 실행/관리한다.
///
/// Flutter(네이티브)가 실행을 책임지며, 각 프로세스의 출력은 [LauncherProcess]에
/// 누적되어 대화창으로 전달된다. 좌측 진행 상태 아이콘은 [runningCount]를 본다.
class ProcessManager extends ChangeNotifier {
  ProcessManager(this.env);

  /// 현재 Python 인터프리터 환경(사용자 선택에 따라 바뀔 수 있음).
  PythonEnvironment env;

  /// 인터프리터 선택이 바뀌면 갱신한다(이후 실행에 적용).
  void updateEnvironment(PythonEnvironment environment) => env = environment;

  final Map<String, LauncherProcess> _processes = {};
  int _seq = 0;

  List<LauncherProcess> get processes => List.unmodifiable(_processes.values);
  int get runningCount => _processes.values.where((p) => p.isRunning).length;

  /// 새 런쳐 프로세스를 시작한다. 동시에 여러 개가 실행될 수 있다.
  Future<LauncherProcess> start(LaunchSpec spec) async {
    final id = 'p${++_seq}';
    final proc = LauncherProcess(
      id: id,
      scriptPath: spec.scriptPath,
      args: spec.args,
      elevated: spec.elevated,
      label: spec.label ?? p.basename(spec.scriptPath),
      workingDirectory: spec.workingDirectory,
    );
    _processes[id] = proc;
    notifyListeners();

    if (!env.isInstalled) {
      proc.markFailed('Python 환경이 아직 구성되지 않았습니다.');
      notifyListeners();
      return proc;
    }

    // 실행은 비동기로 진행하고, 핸들/상태 변화 시 리스너에 통지한다.
    unawaited(_run(proc).whenComplete(notifyListeners));
    return proc;
  }

  Future<void> _run(LauncherProcess proc) async {
    try {
      if (proc.elevated) {
        await _runElevated(proc);
      } else {
        await _runInline(proc);
      }
    } catch (e) {
      proc.markFailed('실행 오류: $e');
    }
  }

  /// 일반 권한 실행: stdout/stderr 를 실시간 스트리밍한다.
  Future<void> _runInline(LauncherProcess proc) async {
    final process = await Process.start(
      env.executablePath,
      [proc.scriptPath, ...proc.args],
      workingDirectory: proc.workingDirectory,
    );
    proc.backingHandle = process;
    proc.markRunning();
    notifyListeners();

    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => proc.appendLine(OutputChannel.stdout, line));
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) => proc.appendLine(OutputChannel.stderr, line));

    final code = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    if (proc.status != ProcessStatus.canceled) proc.markFinished(code);
  }

  /// 관리자 권한 상승 실행(프로세스별 on-demand).
  ///
  /// 현재는 Windows 만 구현: 상승된 프로세스는 부모 파이프를 상속할 수 없으므로
  /// 출력/종료코드를 임시 파일로 중계(file relay)하고, 부모가 이를 tail 한다.
  Future<void> _runElevated(LauncherProcess proc) async {
    if (!Platform.isWindows) {
      // TODO(linux/macos): pkexec/osascript 기반 상승 구현.
      throw UnsupportedError(
        '관리자 권한 상승은 현재 Windows 에서만 지원됩니다 (${Platform.operatingSystem}).',
      );
    }
    await _runElevatedWindows(proc);
  }

  Future<void> _runElevatedWindows(LauncherProcess proc) async {
    final tmp = await Directory.systemTemp.createTemp('collabo_elev_');
    final outFile = File(p.join(tmp.path, 'out.log'));
    final errFile = File(p.join(tmp.path, 'err.log'));
    final codeFile = File(p.join(tmp.path, 'code.txt'));
    await outFile.create();
    await errFile.create();

    // 상승된 cmd 안에서 리다이렉션이 일어나 우리가 소유한 파일에 기록된다.
    final cmd = File(p.join(tmp.path, 'run.cmd'));
    final argLine = proc.args.map(_quote).join(' ');
    await cmd.writeAsString(
      '@echo off\r\n'
      '"${env.executablePath}" "${proc.scriptPath}" $argLine '
      '> "${outFile.path}" 2> "${errFile.path}"\r\n'
      'echo %ERRORLEVEL% > "${codeFile.path}"\r\n',
    );

    proc.markRunning();
    notifyListeners();

    // 상승된 출력 파일을 추적하는 tailer. 완료 직전 한 번 더 비워 누락을 막는다.
    final outTail = _FileTailer(outFile, OutputChannel.stdout, proc);
    final errTail = _FileTailer(errFile, OutputChannel.stderr, proc);
    final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      await outTail.pump();
      await errTail.pump();
    });

    // -Verb RunAs 가 UAC 동의 창을 띄우고, -Wait 로 완료까지 블록한다.
    final psArgs = [
      '-NoProfile',
      '-Command',
      "Start-Process -FilePath '${cmd.path}' -Verb RunAs "
          "-WindowStyle Hidden -Wait",
    ];
    final shell = await Process.start('powershell', psArgs);
    proc.backingHandle = shell;

    final shellCode = await shell.exitCode;
    ticker.cancel();
    await outTail.pump();
    await errTail.pump();

    if (proc.status == ProcessStatus.canceled) return;

    int code = shellCode;
    if (await codeFile.exists()) {
      code = int.tryParse((await codeFile.readAsString()).trim()) ?? shellCode;
    }
    proc.markFinished(code);
    await tmp.delete(recursive: true).catchError((_) => tmp);
  }

  /// 실행 중 프로세스를 취소한다.
  Future<void> cancel(String id) async {
    final proc = _processes[id];
    if (proc == null || !proc.isRunning) return;
    final handle = proc.backingHandle;
    if (handle is Process) handle.kill();
    proc.markCanceled();
    notifyListeners();
  }

  static String _quote(String s) =>
      s.contains(' ') ? '"${s.replaceAll('"', '\\"')}"' : s;

  @override
  void dispose() {
    for (final proc in _processes.values) {
      proc.dispose();
    }
    super.dispose();
  }
}

/// 로그 파일을 위치 기준으로 추적해 새로 추가된 줄만 프로세스 출력으로 보낸다.
class _FileTailer {
  _FileTailer(this.file, this.channel, this.proc);

  final File file;
  final OutputChannel channel;
  final LauncherProcess proc;
  int _pos = 0;

  Future<void> pump() async {
    if (!await file.exists()) return;
    final len = await file.length();
    if (len <= _pos) return;
    final raf = await file.open();
    await raf.setPosition(_pos);
    final bytes = await raf.read(len - _pos);
    await raf.close();
    _pos = len;
    for (final line in const LineSplitter().convert(utf8.decode(bytes))) {
      proc.appendLine(channel, line);
    }
  }
}
