import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_module.dart';
import 'tool_source.dart';

/// 도구 모듈을 포터블 Python 으로 실행하는 계약 구현.
///
/// 모든 모듈은 동일 계약을 따른다:
///   `<python> <script> describe`        → 도구 스키마(JSON)
///   `<python> <script> call <tool>`     → stdin(JSON 인자) → stdout(JSON 결과)
class ToolRunner {
  const ToolRunner(this.interpreter, {this.onProcessStart});

  /// Python 인터프리터 경로(포터블 환경).
  final String interpreter;

  /// 도구 프로세스를 띄울 때마다 호출된다(호출측이 추적해 **중지 시 죽이려는** 용도).
  ///
  /// 도구에는 기본 타임아웃이 없어서(`run_wait` 처럼 길게 기다리는 게 정상), 사용자가
  /// 중지를 눌렀을 때 이 핸들이 없으면 그 도구가 끝날 때까지 중지가 지연된다.
  final void Function(Process proc)? onProcessStart;

  /// 모듈의 도구 목록을 조회한다. 실패하면 null.
  Future<ToolModule?> describe(
    String scriptPath, {
    bool isBase = false,
    Map<String, String>? env,
    String? workingDirectory,
  }) async {
    try {
      // Python 은 UTF-8 로 출력하게 하고(비-ASCII 설명이 cp949 콘솔에서 죽지
      // 않도록), Dart 도 stdout 을 UTF-8 로 디코딩한다(Process.run 기본은
      // systemEncoding 이라 한국어 Windows 에서 깨진다).
      final res = await Process.run(
        interpreter,
        [scriptPath, 'describe'],
        environment: {'PYTHONIOENCODING': 'utf-8', ...?env},
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        workingDirectory: workingDirectory,
      ).timeout(const Duration(seconds: 30));
      if (res.exitCode != 0) return null;
      final json = jsonDecode(res.stdout as String) as Map<String, Object?>;
      return ToolModule.fromDescribe(json, scriptPath: scriptPath, isBase: isBase);
    } catch (_) {
      return null;
    }
  }

  /// 어댑터 디렉토리(추출된 assets/python) 기준으로 소스에 맞는
  /// (어댑터 스크립트, 환경변수) 를 만든다.
  (String, Map<String, String>) _resolveSource(ToolSource s, String adaptersDir) {
    switch (s.kind) {
      case ToolSourceKind.cli:
        return (
          p.join(adaptersDir, 'cli_adapter.py'),
          {'COLLABO_TARGET': s.script},
        );
      case ToolSourceKind.mcp:
        return (
          p.join(adaptersDir, 'mcp_adapter.py'),
          {
            'COLLABO_MCP_COMMAND':
                jsonEncode({'command': s.command, 'args': s.args}),
          },
        );
    }
  }

  /// 소스(일반 CLI / MCP)의 도구를 조회한다.
  Future<ToolModule?> describeSource(
    ToolSource s,
    String adaptersDir, {
    String? workingDirectory,
  }) {
    final (script, env) = _resolveSource(s, adaptersDir);
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
  }) {
    final (script, env) = _resolveSource(s, adaptersDir);
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
    final env = <String, String>{'PYTHONIOENCODING': 'utf-8'};
    if (workspace != null) env['COLLABO_WORKSPACE'] = workspace;
    if (elevated) env['COLLABO_ELEVATED'] = '1';
    if (extraEnv != null) env.addAll(extraEnv);
    final proc = await Process.start(
      interpreter,
      [scriptPath, 'call', tool],
      environment: env,
      // 상대 경로가 프로젝트 기준으로 풀리도록 cwd 를 프로젝트로 잡는다.
      workingDirectory: workingDirectory ?? workspace,
    );
    onProcessStart?.call(proc);
    proc.stdin.write(jsonEncode(args));
    await proc.stdin.close();
    try {
      // 기본은 타임아웃 없음: 도구는 스스로 완료를 보고한다(백그라운드 명령의
      // 긴 대기(run_wait)를 여기서 죽이면 안 된다). 대기 중인 명령은 사용자가
      // 프로세스 뷰어에서 종료하면 도구도 상태 변화를 보고 즉시 반환한다.
      // [timeout] 을 지정한 호출에만 백스톱을 건다.
      final stdoutText = proc.stdout.transform(utf8.decoder).join();
      final out =
          timeout == null ? await stdoutText : await stdoutText.timeout(timeout);
      await proc.stderr.drain<void>();
      await proc.exitCode;
      return ToolCallResult.fromJson(jsonDecode(out) as Map<String, Object?>);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      return ToolCallResult(
          ok: false, error: 'Tool timed out after ${timeout!.inSeconds}s');
    } catch (e) {
      return ToolCallResult(ok: false, error: '도구 응답 파싱 실패: $e');
    }
  }
}
