import 'package:collabo_ide/src/tools/tool_module.dart';
import 'package:collabo_ide/src/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('describe 결과를 ToolModule 로 파싱', () {
    final json = <String, Object?>{
      'module': 'collabo_base',
      'version': '0.1.0',
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'description': '파일 읽기',
            'parameters': {
              'type': 'object',
              'properties': {'path': {'type': 'string'}},
              'required': ['path'],
            },
          },
        },
      ],
    };
    final m = ToolModule.fromDescribe(json, scriptPath: '/x/collabo_tools.py', isBase: true);
    expect(m.name, 'collabo_base');
    expect(m.isBase, isTrue);
    expect(m.tools.single.name, 'read_file');
    // 원본 스키마는 OpenAI tools 배열에 그대로 넣을 수 있어야 한다.
    expect(m.tools.single.raw['type'], 'function');
  });

  test('ToolCallResult: 성공/오류/권한상승 파싱', () {
    expect(ToolCallResult.fromJson({'ok': true, 'result': 42}).ok, isTrue);
    final err = ToolCallResult.fromJson({'ok': false, 'error': 'bad'});
    expect(err.ok, isFalse);
    expect(err.error, 'bad');
    final elev = ToolCallResult.fromJson(
        {'ok': false, 'needs_elevation': true, 'reason': '관리자 필요'});
    expect(elev.needsElevation, isTrue);
    expect(elev.reason, '관리자 필요');
  });

  test('ToolSource: cli/mcp JSON 왕복', () {
    final cli = ToolSource(kind: ToolSourceKind.cli, script: r'C:\t\foo.py');
    final back = ToolSource.fromJson(cli.toJson());
    expect(back.kind, ToolSourceKind.cli);
    expect(back.script, r'C:\t\foo.py');
    expect(back.id, r'cli:C:\t\foo.py');

    final mcp = ToolSource(
        kind: ToolSourceKind.mcp, command: 'npx', args: const ['-y', 'srv']);
    final mback = ToolSource.fromJson(mcp.toJson());
    expect(mback.kind, ToolSourceKind.mcp);
    expect(mback.command, 'npx');
    expect(mback.args, ['-y', 'srv']);
  });

  test('ToolSource.legacy: 구버전 문자열 경로는 cli 로 이주', () {
    final s = ToolSource.legacy(r'C:\old\tool.py');
    expect(s.kind, ToolSourceKind.cli);
    expect(s.script, r'C:\old\tool.py');
  });
}
