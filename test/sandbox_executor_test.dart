// 도구 계층을 collaboCore 샌드박스로: 레지스트리 → ToolRunner → SandboxToolExecutor →
// 게스트 CPython 까지 실제로 돈다. 앱이 쓰는 것과 같은 조각들을 그대로 조립한다.
//
// 런타임이 필요하다: COLLABO_CORE_RUNTIME, 없으면 리포의 collabo_core_runtime/.
// 이 플랫폼 런타임이 없으면 건너뛴다.
import 'dart:convert';
import 'dart:io';

import 'package:collabo_core/collabo_core.dart';
import 'package:collabo_ide/src/process/background_process_registry.dart';
import 'package:collabo_ide/src/sandbox/project_sandbox.dart';
import 'package:collabo_ide/src/tools/tool_executor.dart';
import 'package:collabo_ide/src/tools/tool_registry.dart';
import 'package:collabo_ide/src/tools/tool_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

CollaboRuntime? _runtime() {
  try {
    return CollaboRuntime.locate(
        directory: Platform.environment['COLLABO_CORE_RUNTIME'] ??
            Directory('collabo_core_runtime').absolute.path);
  } catch (_) {
    return null;
  }
}

Map<String, Object?> _meta(String project, String id) => (jsonDecode(
        File(p.join(project, '.collabo', 'proc', id, 'meta.json')).readAsStringSync()) as Map)
    .cast<String, Object?>();

Future<void> _until(bool Function() ok, String what, {int seconds = 20}) async {
  for (var i = 0; i < seconds * 10 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(ok(), isTrue, reason: 'timed out: $what');
}

void main() {
  final runtime = _runtime();
  final toolsDir = Directory('assets/python').absolute.path;

  late Directory project;
  late ProjectSandbox box;
  late ToolRegistry registry;
  final handles = <ToolHandle>{};

  Future<Map<String, Object?>> call(String tool, Map<String, Object?> args) async {
    final r = await registry.call(tool, args, workspace: project.path, workingDirectory: project.path);
    expect(r.ok, isTrue, reason: '$tool: ${r.error}');
    return (r.result as Map).cast<String, Object?>();
  }

  setUpAll(() async {
    if (runtime == null) return;
    project = Directory.systemTemp.createTempSync('collabo-sbx-');
    File(p.join(project.path, 'hello.txt')).writeAsStringSync('안녕 sandbox\nline2\n');
    box = ProjectSandbox(projectPath: project.path, toolsDir: toolsDir, runtime: runtime);
    registry = ToolRegistry(
      runner: ToolRunner.withExecutor(
        SandboxToolExecutor(box),
        onStart: (h) {
          handles.add(h);
          h.done.whenComplete(() => handles.remove(h));
        },
      ),
      baseScripts: [p.join(toolsDir, 'collabo_tools.py'), p.join(toolsDir, 'collabo_term.py')],
      adaptersDir: toolsDir,
    );
    await registry.load(const [], workingDirectory: project.path);
  });

  tearDownAll(() async {
    if (runtime == null) return;
    await box.close();
    try {
      project.deleteSync(recursive: true);
    } catch (_) {}
  });

  final skip = runtime == null ? 'no collaboCore runtime for this platform' : false;
  const long = Timeout(Duration(minutes: 3));

  test('레지스트리가 게스트에서 describe 한다', () {
    expect(box.state, SandboxState.running);
    expect(registry.toolNames, containsAll(['read_file', 'run_command', 'term_open']));
  }, skip: skip);

  test('경로: 모델은 호스트 경로만 본다 (인자·결과·diff)', () async {
    final hello = p.join(project.path, 'hello.txt');
    final r = await call('read_file', {'path': hello});
    expect(r['content'], '안녕 sandbox\nline2\n', reason: '한글 인자·내용이 UTF-8 로 오간다');
    expect(p.equals(r['path'] as String, hello), isTrue, reason: '${r['path']}');

    final e = await call('edit_file', {'path': 'hello.txt', 'old_string': 'line2', 'new_string': '둘째 줄'});
    expect((e['diff'] as String).split('\n').first, '--- ${e['path']}');
    expect(p.isWithin(project.path, e['path'] as String), isTrue);
    expect(File(hello).readAsStringSync(), '안녕 sandbox\n둘째 줄\n');

    final l = await call('list_directory', {'path': project.path});
    expect(p.equals(l['path'] as String, project.path), isTrue);
  }, skip: skip, timeout: long);

  test('워크스페이스 밖은 게스트에서도 막힌다', () async {
    final r = await registry.call('read_file', {'path': '/etc/passwd'}, workspace: project.path);
    expect(r.ok, isFalse);
    expect(r.error, contains('outside the workspace'));
  }, skip: skip);

  test('백그라운드 명령: 샌드박스 표시 → 호스트는 kill 하지 않고, 게스트 경로로 끝낸다', () async {
    final started = await call('run_command', {'command': 'sleep 60', 'timeout': 1});
    expect(started['running'], isTrue);
    final id = started['id'] as String;
    expect(_meta(project.path, id)['sandbox'], isTrue);

    final reg = BackgroundProcessRegistry()..attachProject(project.path);
    addTearDown(reg.dispose);
    reg.refresh();
    final proc = reg.processes.firstWhere((e) => e.id == id);
    expect(proc.sandbox, isTrue);

    // 끝낼 경로가 없으면 아무것도 하지 않는다 — 게스트 pid 를 호스트에서 쏘지 않는다.
    await reg.kill(id);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(_meta(project.path, id)['status'], 'running');

    reg.sandboxKiller = (bp) => box.killGroup(bp.pid!, terminal: bp.isTerminal);
    await reg.kill(id);
    await _until(() => _meta(project.path, id)['status'] != 'running', 'the command to end');
    expect(_meta(project.path, id)['status'], 'killed');
  }, skip: skip, timeout: long);

  test('터미널: 대화형 셸도 끝난다 (HUP)', () async {
    final t = await call('term_open', {'name': 'sbx', 'wait': 2});
    expect(t['pty'], isTrue, reason: '게스트 /init 이 devpts 를 올리니 진짜 PTY 여야 한다');
    final id = t['id'] as String;
    expect(_meta(project.path, id)['sandbox'], isTrue);
    await box.killGroup(t['pid'] as int, terminal: true);
    await _until(() => _meta(project.path, id)['status'] != 'running', 'the terminal to end');
  }, skip: skip, timeout: long);

  test('중지: 실행 중인 도구 호출을 게스트 안에서 끊는다', () async {
    final started = await call('run_command', {'command': 'sleep 60', 'timeout': 1});
    final sw = Stopwatch()..start();
    final waiting = registry.call('run_wait', {'id': started['id'], 'wait': 50},
        workspace: project.path, workingDirectory: project.path);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(handles, isNotEmpty);
    for (final h in handles.toList()) {
      h.kill();
    }
    await waiting;
    expect(sw.elapsed, lessThan(const Duration(seconds: 20)), reason: 'run_wait(50s) 를 기다리지 않았다');
    await box.killGroup(_meta(project.path, started['id'] as String)['pid'] as int);
  }, skip: skip, timeout: long);

  test('머신이 내려가면 그 안에서 돌던 기록은 끝난 것으로 고친다', () async {
    final started = await call('run_command', {'command': 'sleep 60', 'timeout': 1});
    final id = started['id'] as String;
    await box.close();
    final meta = _meta(project.path, id);
    expect(meta['status'], 'killed');
    expect('${meta['note']}', contains('sandbox'));
  }, skip: skip, timeout: long);
}
