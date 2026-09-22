import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 도구 스크립트 한 번 실행한 결과.
class ToolProcessResult {
  const ToolProcessResult({
    required this.exitCode,
    required this.stdout,
    this.stderr = '',
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// 실행 중인 도구 하나 — "중지" 가 곧바로 끊을 수 있게 호출측이 들고 있는다.
///
/// 도구에는 기본 타임아웃이 없어서(`run_wait` 처럼 길게 기다리는 게 정상) 이 핸들이
/// 없으면 사용자가 중지를 눌러도 그 도구가 끝날 때까지 기다리게 된다.
abstract class ToolHandle {
  void kill();

  /// 도구가 끝나면 완료된다(성공·실패·kill 모두).
  Future<void> get done;
}

/// **도구 스크립트를 어디서 돌리는가.** 도구 계약(describe/call, stdin JSON → stdout
/// JSON)은 그대로이고, 실행 위치와 경로의 모양만 다르다.
///
/// - [HostToolExecutor] — 시스템(또는 venv) 파이썬. 예전부터의 방식.
/// - `SandboxToolExecutor` — collaboCore 게스트의 CPython (`lib/src/sandbox/`).
///
/// 경로는 **앱 쪽(호스트) 경로가 정본**이다. 트리·뷰어·`file_changes`·시스템 프롬프트가
/// 전부 호스트 경로로 말하므로, 실행 환경이 경로를 달리 부르면(게스트의 `/work/...`)
/// 들어갈 때 [execArgs] 로 바꾸고 나올 때 [hostify] 로 되돌린다.
abstract class ToolExecutor {
  /// 'system' | 'sandbox' — 로그·설정 표시용.
  String get kind;

  /// [script] 를 [args] 로 실행한다. [env]·[workingDirectory] 는 **호스트 기준**으로
  /// 받는다(경로 값은 실행기가 알아서 옮긴다). [stdin] 은 UTF-8 로 보낸다.
  Future<ToolProcessResult> run(
    String script,
    List<String> args, {
    Map<String, String> env = const {},
    String? stdin,
    String? workingDirectory,
    Duration? timeout,
    void Function(ToolHandle handle)? onStart,
  });

  /// 호스트 경로 → 실행 환경에서의 경로. 옮길 수 없으면(보이지 않는 곳) null.
  String? execPath(String hostPath) => hostPath;

  /// 호스트 바깥의 스크립트(사용자 CLI 도구)를 실행 환경이 볼 수 있게 한다.
  /// 돌려준 경로로 실행하면 된다. 실패하면 null.
  Future<String?> stageScript(String hostPath) async => hostPath;

  /// 모델이 보낸 인자 속 호스트 경로를 실행 환경 경로로.
  Map<String, Object?> execArgs(Map<String, Object?> args) => args;

  /// 도구 결과 속 실행 환경 경로를 호스트 경로로.
  Object? hostify(Object? value) => value;

  /// 모델에게 알려 줄 실행 환경 설명(없으면 null). 명령이 어디서 도는지 모르면
  /// 모델이 `git`·`node` 를 당연히 있다고 여기거나 호스트 경로로 `cd` 한다.
  String? get environmentNote => null;
}

/// 시스템(또는 venv) 파이썬으로 실행한다. 경로는 그대로다.
class HostToolExecutor extends ToolExecutor {
  HostToolExecutor(this.interpreter);

  /// 실효 파이썬 경로(venv 준비 시 venv).
  final String interpreter;

  @override
  String get kind => 'system';

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
    final proc = await Process.start(
      interpreter,
      [script, ...args],
      environment: env,
      workingDirectory: workingDirectory,
    );
    onStart?.call(_ProcessHandle(proc));
    // ★ 바이트로 보낸다. `stdin.write(String)` 은 systemEncoding(한국어 Windows 는
    // cp949)으로 인코딩되는데 파이썬은 PYTHONIOENCODING=utf-8 로 읽는다 — 한글 인자가 깨진다.
    if (stdin != null) proc.stdin.add(utf8.encode(stdin));
    await proc.stdin.close();
    // Process.run 기본은 systemEncoding 이라 한국어 Windows 에서 깨진다 → UTF-8 로 디코딩.
    final out = proc.stdout.transform(utf8.decoder).join();
    final err = proc.stderr.transform(utf8.decoder).join();
    try {
      final text = timeout == null ? await out : await out.timeout(timeout);
      final code = await proc.exitCode;
      return ToolProcessResult(exitCode: code, stdout: text, stderr: await err);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      return const ToolProcessResult(exitCode: -1, stdout: '', timedOut: true);
    }
  }
}

class _ProcessHandle implements ToolHandle {
  _ProcessHandle(this._proc);
  final Process _proc;

  @override
  void kill() => _proc.kill();

  @override
  Future<void> get done => _proc.exitCode.then((_) {});
}

/// 호스트 폴더 ↔ 실행 환경 경로의 대응(마운트 목록). 샌드박스 실행기가 쓴다.
///
/// 순수 계산이라 테스트로 잠근다(`test/sandbox_paths_test.dart`).
class PathMapping {
  PathMapping(this.pairs, {p.Context? hostContext})
      : _host = hostContext ?? p.context;

  /// (호스트 루트, 게스트 루트). 게스트 쪽은 항상 POSIX(`/work`).
  final List<(String, String)> pairs;
  final p.Context _host;

  /// 호스트 경로 → 게스트 경로. 어느 마운트에도 안 들면 null.
  String? toGuest(String hostPath) {
    if (!_host.isAbsolute(hostPath)) return null;
    for (final (host, guest) in pairs) {
      if (_host.equals(host, hostPath)) return guest;
      if (_host.isWithin(host, hostPath)) {
        final rel = _host.relative(hostPath, from: host);
        return p.posix.join(guest, _host.split(rel).join('/'));
      }
    }
    return null;
  }

  /// 게스트 경로 → 호스트 경로. 어느 마운트에도 안 들면 null.
  String? toHost(String guestPath) {
    for (final (host, guest) in pairs) {
      if (guestPath == guest) return host;
      if (guestPath.startsWith('$guest/')) {
        final rel = guestPath.substring(guest.length + 1);
        return _host.joinAll([host, ...rel.split('/').where((s) => s.isNotEmpty)]);
      }
    }
    return null;
  }

  /// 인자(JSON)의 **문자열 값**이 호스트 경로면 게스트 경로로 바꾼다.
  /// 모델이 결과에서 본 호스트 경로를 그대로 인자로 되돌려 보내는 경우다.
  Object? argsToGuest(Object? v) {
    if (v is String) return toGuest(v) ?? v;
    if (v is List) return [for (final e in v) argsToGuest(e)];
    if (v is Map) return {for (final e in v.entries) e.key: argsToGuest(e.value)};
    return v;
  }

  /// 결과(JSON)의 게스트 경로를 호스트 경로로 되돌린다.
  ///
  /// **경로를 담는 키의 값만** 바꾼다([isPathKey] — `path`·`src`·`dst`·`cwd`…).
  /// 파일 내용·명령 출력 안의 `/work/` 를 고치면 모델이 본 내용과 실제 파일이
  /// 달라진다(`edit_file` 의 old_string 이 안 맞게 된다). 한 줄짜리 파일 내용이
  /// 우연히 경로 모양이어도 마찬가지라 "값이 경로처럼 생겼나" 로는 가르지 않는다.
  /// 예외는 `diff` 의 헤더 두 줄(`--- ` / `+++ `)뿐이다. 목록은 부모 키를 물려받는다
  /// (`paths: [...]`, `entries: [{path}]` 모두 맞게 풀린다).
  Object? resultToHost(Object? v, [String? key]) {
    if (v is String) {
      if (key == 'diff') return _diffToHost(v);
      if (key == null || !isPathKey(key)) return v;
      return toHost(v) ?? v;
    }
    if (v is List) return [for (final e in v) resultToHost(e, key)];
    if (v is Map) {
      return {for (final e in v.entries) e.key: resultToHost(e.value, '${e.key}')};
    }
    return v;
  }

  static const Set<String> _pathKeys = {
    'src', 'dst', 'cwd', 'root', 'dir', 'directory', 'file', 'target', 'workspace', 'location',
  };

  /// 값이 경로인 결과 키. `*path*` 는 전부(`path`·`paths`·`saved_path`…).
  static bool isPathKey(String key) {
    final k = key.toLowerCase();
    return k.contains('path') || _pathKeys.contains(k);
  }

  String _diffToHost(String diff) {
    final lines = diff.split('\n');
    for (var i = 0; i < lines.length && i < 4; i++) {
      final l = lines[i];
      if (l.startsWith('--- ') || l.startsWith('+++ ')) {
        lines[i] = '${l.substring(0, 4)}${toHost(l.substring(4)) ?? l.substring(4)}';
      }
    }
    return lines.join('\n');
  }
}
