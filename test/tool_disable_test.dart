import 'dart:io';

import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/app_database.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/tools/tool_module.dart';
import 'package:collabo_ide/src/tools/tool_registry.dart';
import 'package:collabo_ide/src/tools/tool_runner.dart';
import 'package:collabo_ide/src/tools/tool_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// describe 만 흉내 내는 러너 — 파이썬 없이 레지스트리 구성을 검사한다.
/// (`call` 은 쓰지 않는다. 꺼진 도구는 레지스트리가 이름 단계에서 막는다.)
class _FakeRunner extends ToolRunner {
  _FakeRunner(this.byScript, this.bySourceId) : super('python');

  final Map<String, ToolModule> byScript;
  final Map<String, ToolModule> bySourceId;

  @override
  Future<ToolModule?> describe(
    String scriptPath, {
    bool isBase = false,
    Map<String, String>? env,
    String? workingDirectory,
  }) async =>
      byScript[scriptPath];

  @override
  Future<ToolModule?> describeSource(
    ToolSource s,
    String adaptersDir, {
    String? workingDirectory,
  }) async =>
      bySourceId[s.id];
}

ToolModule _module(String name, List<String> tools, {bool isBase = false}) =>
    ToolModule(
      name: name,
      version: '1',
      scriptPath: '/x/$name.py',
      isBase: isBase,
      tools: [
        for (final t in tools)
          ToolDef(
            name: t,
            description: '$t 설명',
            parameters: const {'type': 'object'},
            raw: {
              'type': 'function',
              'function': {'name': t, 'description': '$t 설명'},
            },
          ),
      ],
    );

void main() {
  group('toolKey / baseSourceId', () {
    test('기본 모듈 키는 경로가 아니라 파일명으로 만든다', () {
      // 기본 모듈은 appSupport 아래로 추출되므로 전체 경로가 기기마다 다르다.
      expect(baseSourceId(r'C:\Users\a\AppData\collabo_tools.py'),
          baseSourceId('/Users/b/Library/collabo_tools.py'));
      expect(baseSourceId('/x/collabo_tools.py'), 'base:collabo_tools.py');
    });

    test('모듈이 다르면 같은 이름의 도구라도 키가 다르다', () {
      expect(toolKey('base:a.py', 'read_file'),
          isNot(toolKey('base:b.py', 'read_file')));
    });
  });

  group('ToolRegistry: 꺼 둔 도구 제외', () {
    const baseScript = '/x/collabo_tools.py';
    final userSource = ToolSource(kind: ToolSourceKind.cli, script: '/u/my.py');

    ToolRegistry build() => ToolRegistry(
          runner: _FakeRunner(
            {baseScript: _module('collabo_base', ['read_file', 'write_file'], isBase: true)},
            {userSource.id: _module('my', ['upload', 'convert'])},
          ),
          baseScripts: const [baseScript],
          adaptersDir: '/adapters',
        );

    test('비활성 목록이 비면 전부 노출된다', () async {
      final r = build();
      await r.load([userSource]);
      expect(r.toolNames, ['read_file', 'write_file', 'upload', 'convert']);
    });

    test('꺼 둔 도구는 목록·프롬프트에서 빠진다', () async {
      final r = build();
      await r.load([userSource], disabled: {
        toolKey(baseSourceId(baseScript), 'write_file'),
        toolKey(userSource.id, 'upload'),
      });
      expect(r.toolNames, ['read_file', 'convert']);
      expect(r.openAiTools, hasLength(2));
    });

    test('꺼 둔 도구는 이름으로도 부를 수 없다', () async {
      final r = build();
      await r.load([userSource],
          disabled: {toolKey(baseSourceId(baseScript), 'write_file')});
      final res = await r.call('write_file', const <String, Object?>{});
      expect(res.ok, isFalse);
      expect(res.error, contains('Unknown tool'));
    });

    test('키는 소스별이라 같은 이름의 다른 모듈 도구는 살아 있다', () async {
      final dup = ToolSource(kind: ToolSourceKind.cli, script: '/u/dup.py');
      final r = ToolRegistry(
        runner: _FakeRunner(
          {baseScript: _module('collabo_base', ['read_file'], isBase: true)},
          {dup.id: _module('dup', ['read_file'])},
        ),
        baseScripts: const [baseScript],
        adaptersDir: '/adapters',
      );
      // 둘 다 켜져 있으면 뒤에 온 쪽이 접두사를 받는다(점은 밑줄로 정리된다).
      await r.load([dup]);
      expect(r.toolNames, ['read_file', 'dup_py_read_file']);

      // 기본 쪽만 끈다.
      await r.load([dup],
          disabled: {toolKey(baseSourceId(baseScript), 'read_file')});
      // 사용자 도구가 남고, 이제 충돌이 없으므로 접두사 없이 원래 이름으로 노출된다.
      expect(r.toolNames, ['read_file']);
    });

    test('전부 끄면 레지스트리가 빈다', () async {
      final r = build();
      await r.load([userSource], disabled: {
        toolKey(baseSourceId(baseScript), 'read_file'),
        toolKey(baseSourceId(baseScript), 'write_file'),
        toolKey(userSource.id, 'upload'),
        toolKey(userSource.id, 'convert'),
      });
      expect(r.isEmpty, isTrue);
    });
  });

  group('WorkspaceController: 비활성 목록 저장', () {
    late Directory tmp;
    late AppDatabase db;

    setUpAll(initSqliteFfi);

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('collabo_tools_');
      db = await AppDatabase.open(path: p.join(tmp.path, 'collabo.db'));
    });

    tearDown(() async {
      await db.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('토글하면 메인 DB 에 남고 다시 읽힌다', () async {
      final wc = WorkspaceController();
      await wc.loadToolsForTest(db);
      expect(wc.isToolEnabled('base:collabo_tools.py', 'delete_path'), isTrue);

      await wc.setToolsEnabled('base:collabo_tools.py', ['delete_path'], false);
      expect(wc.isToolEnabled('base:collabo_tools.py', 'delete_path'), isFalse);

      final again = WorkspaceController();
      await again.loadToolsForTest(db);
      expect(again.isToolEnabled('base:collabo_tools.py', 'delete_path'), isFalse);
      expect(again.disabledTools, contains('base:collabo_tools.py::delete_path'));
    });

    test('모듈 전체를 한 번에 끄고 켠다', () async {
      final wc = WorkspaceController();
      await wc.loadToolsForTest(db);
      await wc.setToolsEnabled('base:a.py', ['x', 'y', 'z'], false);
      expect(wc.disabledTools, hasLength(3));
      await wc.setToolsEnabled('base:a.py', ['x', 'y', 'z'], true);
      expect(wc.disabledTools, isEmpty);
    });

    test('소스를 지우면 그 소스의 비활성 표시도 사라진다', () async {
      final source = ToolSource(kind: ToolSourceKind.cli, script: '/u/my.py');
      final wc = WorkspaceController();
      await wc.loadToolsForTest(db);
      await wc.addToolSource(source);
      await wc.setToolsEnabled(source.id, ['upload'], false);
      await wc.setToolsEnabled('base:collabo_tools.py', ['delete_path'], false);

      await wc.removeToolSource(source);
      // 다시 추가했을 때 예전에 꺼 둔 도구가 조용히 꺼진 채로 오면 안 된다.
      expect(wc.isToolEnabled(source.id, 'upload'), isTrue);
      // 다른 소스의 설정은 그대로.
      expect(wc.isToolEnabled('base:collabo_tools.py', 'delete_path'), isFalse);

      final again = WorkspaceController();
      await again.loadToolsForTest(db);
      expect(again.disabledTools, ['base:collabo_tools.py::delete_path']);
    });
  });
}
