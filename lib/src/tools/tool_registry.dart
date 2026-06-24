import 'tool_module.dart';
import 'tool_runner.dart';
import 'tool_source.dart';

/// 기본 모듈 + 사용자 도구 소스의 도구를 집계하고, 이름으로 실행을 라우팅한다.
class ToolRegistry {
  ToolRegistry({
    required this.runner,
    required this.baseScript,
    required this.adaptersDir,
  });

  final ToolRunner runner;
  final String baseScript;
  final String adaptersDir;

  /// 도구 이름 → 소유 소스(null 이면 기본 모듈).
  final Map<String, ToolSource?> _owner = {};
  final List<Map<String, Object?>> _tools = [];

  /// OpenAI tools 배열(요청에 그대로 넣는다).
  List<Map<String, Object?>> get openAiTools => List.unmodifiable(_tools);
  bool get isEmpty => _tools.isEmpty;

  /// 기본 모듈과 각 소스를 describe 해 도구 목록을 구성한다.
  /// 이름이 겹치면 먼저 등록된 것(기본 우선)을 유지한다.
  Future<void> load(List<ToolSource> sources, {String? workingDirectory}) async {
    _owner.clear();
    _tools.clear();

    final base = await runner.describe(
      baseScript,
      isBase: true,
      workingDirectory: workingDirectory,
    );
    if (base != null) _register(base, null);

    for (final s in sources) {
      final m = await runner.describeSource(s, adaptersDir,
          workingDirectory: workingDirectory);
      if (m != null) _register(m, s);
    }
  }

  void _register(ToolModule module, ToolSource? source) {
    for (final t in module.tools) {
      if (t.name.isEmpty || _owner.containsKey(t.name)) continue;
      _owner[t.name] = source;
      _tools.add(t.raw);
    }
  }

  /// 이름으로 도구를 실행한다(소유 모듈로 라우팅).
  Future<ToolCallResult> call(
    String name,
    Map<String, Object?> args, {
    String? workspace,
    bool elevated = false,
    String? workingDirectory,
  }) {
    if (!_owner.containsKey(name)) {
      return Future.value(ToolCallResult(ok: false, error: 'Unknown tool: $name'));
    }
    final source = _owner[name];
    if (source == null) {
      return runner.call(
        scriptPath: baseScript,
        tool: name,
        args: args,
        workspace: workspace,
        elevated: elevated,
        workingDirectory: workingDirectory,
      );
    }
    return runner.callSource(
      source,
      adaptersDir,
      name,
      args,
      workspace: workspace,
      elevated: elevated,
      workingDirectory: workingDirectory,
    );
  }
}
