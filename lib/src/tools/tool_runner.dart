import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import 'tool_executor.dart';
import 'tool_module.dart';
import 'tool_source.dart';

/// 도구 모듈 계약의 구현. **어디서 실행하는지는 [executor] 가 정한다**
/// (시스템 파이썬 / collaboCore 샌드박스 — `tool_executor.dart`).
///
/// 모든 모듈은 동일 계약을 따른다:
///   `<python> <script> describe`        → 도구 스키마(JSON)
///   `<python> <script> call <tool>`     → stdin(JSON 인자) → stdout(JSON 결과)
class ToolRunner {
  /// 시스템(또는 venv) 파이썬으로 실행한다 — 예전 생성자와 같은 뜻이다.
  ToolRunner(String interpreter,
      {void Function(ToolHandle handle)? onStart, Map<String, String> baseEnv = const {}})
      : this.withExecutor(HostToolExecutor(interpreter), onStart: onStart, baseEnv: baseEnv);

  const ToolRunner.withExecutor(this.executor, {this.onStart, this.baseEnv = const {}});

  final ToolExecutor executor;

  /// **모든** describe/call 에 함께 실리는 환경변수(앱 설정에서 온다).
  ///
  /// 지금 담기는 것: `COLLABO_LANG`(도구가 사람에게 보일 문구를 낼 때),
  /// `COLLABO_SEARCH_ENGINE`(기본 검색엔진). 여기 한 곳에서 넣어야 기본 모듈과
  /// 사용자 소스가 같은 환경을 본다.
  final Map<String, String> baseEnv;

  /// 도구를 띄울 때마다 호출된다(호출측이 추적해 **중지 시 죽이려는** 용도).
  ///
  /// 도구에는 기본 타임아웃이 없어서(`run_wait` 처럼 길게 기다리는 게 정상), 사용자가
  /// 중지를 눌렀을 때 이 핸들이 없으면 그 도구가 끝날 때까지 중지가 지연된다.
  final void Function(ToolHandle handle)? onStart;

  /// Python 은 UTF-8 로 출력하게 한다(비-ASCII 설명이 cp949 콘솔에서 죽지 않도록).
  Map<String, String> _env([Map<String, String>? extra]) =>
      {'PYTHONIOENCODING': 'utf-8', ...baseEnv, ...?extra};

  /// 모듈의 도구 목록을 조회한다. 실패하면 null.
  Future<ToolModule?> describe(
    String scriptPath, {
    bool isBase = false,
    Map<String, String>? env,
    String? workingDirectory,
  }) async {
    try {
      final res = await executor.run(
        scriptPath,
        const ['describe'],
        env: _env(env),
        workingDirectory: workingDirectory,
        timeout: const Duration(seconds: 30),
      );
      if (res.exitCode != 0) return null;
      final json = jsonDecode(res.stdout) as Map<String, Object?>;
      return ToolModule.fromDescribe(json, scriptPath: scriptPath, isBase: isBase);
    } catch (_) {
      return null;
    }
  }

  /// 어댑터 디렉토리(추출된 assets/python) 기준으로 소스에 맞는
  /// (어댑터 스크립트, 환경변수) 를 만든다. CLI 대상 스크립트는 실행 환경이 볼 수
  /// 있는 자리로 옮긴다([ToolExecutor.stageScript] — 샌드박스면 게스트 안으로 복사).
  Future<(String, Map<String, String>)?> _resolveSource(ToolSource s, String adaptersDir) async {
    switch (s.kind) {
      case ToolSourceKind.cli:
        final target = await executor.stageScript(s.script);
        if (target == null) return null;
        return (p.join(adaptersDir, 'cli_adapter.py'), {'COLLABO_TARGET': target});
      case ToolSourceKind.mcp:
        return (
          p.join(adaptersDir, 'mcp_adapter.py'),
          {
            'COLLABO_MCP_COMMAND': jsonEncode({'command': s.command, 'args': s.args}),
          },
        );
    }
  }

  /// 소스(일반 CLI / MCP)의 도구를 조회한다.
  Future<ToolModule?> describeSource(
    ToolSource s,
    String adaptersDir, {
    String? workingDirectory,
  }) async {
    final resolved = await _resolveSource(s, adaptersDir);
    if (resolved == null) return null;
    final (script, env) = resolved;
    return describe(script, env: env, workingDirectory: workingDirectory);
  }

  /// 소스의 도구를 실행한다.
  Future<ToolCallResult> callSource(
    ToolSource s,
    String adaptersDir,
    String tool,
    Map<String, Object?> args, {
    String? workspace,
    bool elevated = false,
    String? workingDirectory,
  }) async {
    final resolved = await _resolveSource(s, adaptersDir);
    if (resolved == null) {
      return ToolCallResult(ok: false, error: 'Tool script is not reachable: ${s.script}');
    }
    final (script, env) = resolved;
    return call(
      scriptPath: script,
      tool: tool,
      args: args,
      workspace: workspace,
      elevated: elevated,
      extraEnv: env,
      workingDirectory: workingDirectory,
    );
  }

  /// 도구를 실행한다. [workspace] 가 주어지면 모듈이 그 밖의 경로를 차단하며,
  /// 프로세스의 작업 디렉토리(cwd)도 [workingDirectory](없으면 workspace)로 잡는다.
  /// 경로는 전부 호스트 기준으로 받고 호스트 기준으로 돌려준다.
  Future<ToolCallResult> call({
    required String scriptPath,
    required String tool,
    required Map<String, Object?> args,
    String? workspace,
    bool elevated = false,
    Map<String, String>? extraEnv,
    String? workingDirectory,
    Duration? timeout,
  }) async {
    final env = _env();
    if (workspace != null) env['COLLABO_WORKSPACE'] = workspace;
    if (elevated) env['COLLABO_ELEVATED'] = '1';
    if (extraEnv != null) env.addAll(extraEnv);
    try {
      // 기본은 타임아웃 없음: 도구는 스스로 완료를 보고한다(백그라운드 명령의
      // 긴 대기(run_wait)를 여기서 죽이면 안 된다). 대기 중인 명령은 사용자가
      // 프로세스 뷰어에서 종료하면 도구도 상태 변화를 보고 즉시 반환한다.
      // [timeout] 을 지정한 호출에만 백스톱을 건다.
      final res = await executor.run(
        scriptPath,
        ['call', tool],
        env: env,
        stdin: jsonEncode(executor.execArgs(args)),
        // 상대 경로가 프로젝트 기준으로 풀리도록 cwd 를 프로젝트로 잡는다.
        workingDirectory: workingDirectory ?? workspace,
        timeout: timeout,
        onStart: onStart,
      );
      if (res.timedOut) {
        return ToolCallResult(ok: false, error: 'Tool timed out after ${timeout!.inSeconds}s');
      }
      final json = jsonDecode(res.stdout) as Map<String, Object?>;
      return ToolCallResult.fromJson(
          (executor.hostify(json) as Map).cast<String, Object?>());
    } catch (e) {
      return ToolCallResult(ok: false, error: '도구 응답을 해석하지 못했습니다: $e');
    }
  }
}
