import 'package:path/path.dart' as p;

/// 사용자가 추가하는 도구 소스 종류.
/// - [cli]: 일반 Python 스크립트(`--help` 자동 파싱으로 도구 생성)
/// - [mcp]: MCP 서버(내장 Python 으로 제어, 서버의 tools 를 노출)
enum ToolSourceKind { cli, mcp }

/// 추가된 도구 소스 설정. 메인 DB 에 JSON 으로 저장된다.
class ToolSource {
  const ToolSource({
    required this.kind,
    this.label = '',
    this.script = '',
    this.command = '',
    this.args = const [],
  });

  final ToolSourceKind kind;
  final String label;

  /// cli: 대상 Python 스크립트 경로.
  final String script;

  /// mcp: 서버 실행 명령 + 인자.
  final String command;
  final List<String> args;

  String get id => kind == ToolSourceKind.cli
      ? 'cli:$script'
      : 'mcp:$command ${args.join(' ')}';

  String get displayName {
    if (label.isNotEmpty) return label;
    return kind == ToolSourceKind.cli ? p.basename(script) : command;
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'label': label,
        'script': script,
        'command': command,
        'args': args,
      };

  factory ToolSource.fromJson(Map<String, Object?> json) => ToolSource(
        kind: json['kind'] == 'mcp' ? ToolSourceKind.mcp : ToolSourceKind.cli,
        label: (json['label'] as String?) ?? '',
        script: (json['script'] as String?) ?? '',
        command: (json['command'] as String?) ?? '',
        args: ((json['args'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
      );

  /// 구버전(문자열 경로)에서의 이주: 일반 CLI 스크립트로 본다.
  factory ToolSource.legacy(String scriptPath) =>
      ToolSource(kind: ToolSourceKind.cli, script: scriptPath);
}
