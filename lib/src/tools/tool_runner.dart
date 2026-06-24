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
  const ToolRunner(this.interpreter);

  /// Python 인터프리터 경로(포터블 환경).
  final String interpreter;

  /// 모듈의 도구 목록을 조회한다. 실패하면 null.
  Future<ToolModule?> describe(
    String scriptPath, {
    bool isBase = false,
    Map<String, String>? env,
    String? workingDirectory,
  }) async {
    try {
      final res = await Process.run(
        interpreter,
        [scriptPath, 'describe'],
        environment: env,
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
    Duration timeout = const Duration(seconds: 300),
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
    proc.stdin.write(jsonEncode(args));
    await proc.stdin.close();
    try {
      // 멈춘(응답 없는) 도구가 영원히 대기하지 않도록 전체 실행에 타임아웃을 건다.
      final out =
          await proc.stdout.transform(utf8.decoder).join().timeout(timeout);
      await proc.stderr.drain<void>();
      await proc.exitCode;
      return ToolCallResult.fromJson(jsonDecode(out) as Map<String, Object?>);
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
      return ToolCallResult(
          ok: false, error: 'Tool timed out after ${timeout.inSeconds}s');
    } catch (e) {
      return ToolCallResult(ok: false, error: '도구 응답 파싱 실패: $e');
    }
  }
}
