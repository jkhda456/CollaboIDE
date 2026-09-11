import 'tool_module.dart';
import 'tool_runner.dart';
import 'tool_source.dart';

/// 기본 모듈 + 사용자 도구 소스의 도구를 집계하고, 이름으로 실행을 라우팅한다.
class ToolRegistry {
  ToolRegistry({
    required this.runner,
    required this.baseScripts,
    required this.adaptersDir,
  });

  final ToolRunner runner;

  /// 고정 기본 모듈들(순서대로 등록 — 이름이 겹치면 앞선 모듈이 이긴다).
  final List<String> baseScripts;
  final String adaptersDir;

  /// 도구 이름 → 소유 소스(null 이면 기본 모듈).
  final Map<String, ToolSource?> _owner = {};

  /// 기본 모듈 도구 → 그 도구가 들어 있는 스크립트 경로(실행 라우팅용).
  final Map<String, String> _baseScriptOf = {};

  /// **모델에게 보여 준 이름 → 모듈이 실제로 아는 이름.**
  ///
  /// 이름이 겹치면 접두사를 붙여 노출하므로(아래 [_register]) 둘이 달라질 수 있다.
  /// 실행할 때는 반드시 원래 이름으로 되돌려 보내야 한다.
  final Map<String, String> _realName = {};
  final List<Map<String, Object?>> _tools = [];

  /// OpenAI tools 배열(요청에 그대로 넣는다).
  List<Map<String, Object?>> get openAiTools => List.unmodifiable(_tools);
  bool get isEmpty => _tools.isEmpty;

  /// 모델에게 노출된 도구 이름들(등록 순서). 프롬프트에 그대로 넣어
  /// "네가 가진 도구는 이것들" 이라고 알려 주는 데 쓴다.
  List<String> get toolNames => [
        for (final t in _tools)
          ((t['function'] as Map?)?['name'] as String?) ?? '',
      ]..removeWhere((n) => n.isEmpty);

  /// 사용자가 꺼 둔 도구들(`toolKey(소스 id, 원래 이름)`). [load] 가 채운다.
  Set<String> _disabled = const {};

  /// 기본 모듈과 각 소스를 describe 해 도구 목록을 구성한다.
  /// 이름이 겹치면 먼저 등록된 것(기본 우선)을 유지한다.
  ///
  /// [disabled] 에 든 도구는 **아예 등록하지 않는다** — 모델에게 목록으로도 가지
  /// 않고 이름으로 부를 수도 없다. 소스 자체는 설정에 그대로 남아 있다.
  Future<void> load(
    List<ToolSource> sources, {
    String? workingDirectory,
    Set<String> disabled = const {},
  }) async {
    _owner.clear();
    _baseScriptOf.clear();
    _realName.clear();
    _tools.clear();
    _disabled = disabled;

    for (final script in baseScripts) {
      final base = await runner.describe(
        script,
        isBase: true,
        workingDirectory: workingDirectory,
      );
      // 모듈 하나가 실패해도(문법 오류 등) 나머지 기본 도구는 살린다.
      if (base != null) _register(base, null, script: script);
    }

    for (final s in sources) {
      final m = await runner.describeSource(s, adaptersDir,
          workingDirectory: workingDirectory);
      if (m != null) _register(m, s);
    }
  }

  /// 모듈의 도구를 등록한다.
  ///
  /// **이름이 겹쳐도 버리지 않는다.** 예전에는 먼저 등록된 것만 남기고 조용히
  /// 건너뛰었는데, 그러면 사용자가 추가한 도구가 기본 도구와 이름이 같다는 이유로
  /// **아무 표시 없이 사라졌다**. 이제는 소유 모듈 이름을 접두사로 붙여 둘 다 살린다
  /// (`read_file` 이 이미 있으면 → `myscript_read_file`).
  void _register(ToolModule module, ToolSource? source, {String? script}) {
    final sourceId = source?.id ?? baseSourceId(script ?? '');
    for (final t in module.tools) {
      if (t.name.isEmpty) continue;
      // 꺼 둔 도구는 이름조차 잡지 않는다 — 이 자리에서 건너뛰어야 뒤따르는
      // 도구가 쓸데없이 접두사를 받지 않는다(꺼진 도구와는 이제 안 겹친다).
      if (_disabled.contains(toolKey(sourceId, t.name))) continue;
      final exposed = _uniqueName(t.name, module, source);
      _owner[exposed] = source;
      _realName[exposed] = t.name;
      if (source == null && script != null) _baseScriptOf[exposed] = script;
      _tools.add(exposed == t.name ? t.raw : _renamed(t.raw, exposed));
    }
  }

  /// 아직 안 쓰인 노출 이름을 고른다(원래 이름 → 접두사 → 접두사+번호).
  String _uniqueName(String name, ToolModule module, ToolSource? source) {
    if (!_owner.containsKey(name)) return name;
    final prefix = _prefixFor(module, source);
    var candidate = '${prefix}_$name';
    var n = 2;
    while (_owner.containsKey(candidate)) {
      candidate = '${prefix}_${name}_$n';
      n++;
    }
    return candidate;
  }

  /// 접두사: 사용자 소스는 표시 이름, 기본 모듈은 모듈 이름.
  /// function name 규칙(`[A-Za-z0-9_-]`)에 맞게 정리하고 짧게 자른다.
  static String _prefixFor(ToolModule module, ToolSource? source) {
    final raw = source?.displayName ?? module.name;
    final safe = raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final trimmed = safe.replaceAll(RegExp(r'^_+|_+$'), '');
    final short = trimmed.isEmpty ? 'tool' : trimmed;
    return short.length > 20 ? short.substring(0, 20) : short;
  }

  /// 스키마의 function.name 만 바꾼 사본(원본 맵은 건드리지 않는다).
  static Map<String, Object?> _renamed(Map<String, Object?> raw, String name) {
    final fn = (raw['function'] as Map?)?.cast<String, Object?>() ?? const {};
    return {
      ...raw,
      'function': {...fn, 'name': name},
    };
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
    // 모듈은 자기 원래 이름만 안다(접두사는 노출용).
    final real = _realName[name] ?? name;
    final source = _owner[name];
    if (source == null) {
      return runner.call(
        // 어느 기본 모듈이 가진 도구인지로 라우팅한다.
        scriptPath: _baseScriptOf[name] ?? baseScripts.first,
        tool: real,
        args: args,
        workspace: workspace,
        elevated: elevated,
        workingDirectory: workingDirectory,
      );
    }
    return runner.callSource(
      source,
      adaptersDir,
      real,
      args,
      workspace: workspace,
      elevated: elevated,
      workingDirectory: workingDirectory,
    );
  }
}
