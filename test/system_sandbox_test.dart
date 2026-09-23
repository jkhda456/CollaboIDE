// 프로젝트에 속하지 않는 도구 작업은 **앱에 하나 고정인 시스템 머신**이 맡는다(설정 → 도구의 목록).
// 예전에는 활성 프로젝트의 머신을 띄우거나(설정 창을 여는 것만으로!) 시스템 파이썬으로 물러섰다
// — 격리를 골라 둔 설정에서 호스트 파이썬이 돌고, 파이썬이 없는 컴퓨터에서는 목록이 비었다.
// 런타임이 필요하다(COLLABO_CORE_RUNTIME, 없으면 리포의 collabo_core_runtime/).
import 'dart:io';

import 'package:collabo_core/collabo_core.dart';
import 'package:collabo_ide/src/app/workspace_controller.dart';
import 'package:collabo_ide/src/data/sqlite_init.dart';
import 'package:collabo_ide/src/sandbox/project_sandbox.dart';
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

void main() {
  setUpAll(initSqliteFfi);

  final runtime = _runtime();
  final toolsDir = Directory('assets/python').absolute.path;
  final script = p.join(toolsDir, 'collabo_tools.py');

  test('시스템 Python 모드에서는 시스템 머신을 만들지 않는다', () {
    final wc = WorkspaceController();
    expect(wc.systemSandbox(), isNull, reason: '기본값은 시스템 모드');
  });

  test('첫 실행 마법사는 Python 선택 여부를 보지 않는다', () async {
    final wc = WorkspaceController()..debugMarkInitialized();
    expect(wc.needsFirstRunSetup, isTrue, reason: 'LLM 미설정 + 최근 프로젝트 없음');

    // 예전에는 파이썬을 고른 적 있으면 마법사를 건너뛰었다 — 파이썬 설정 자체가 없어졌다.
    await wc.markSetupComplete();
    expect(wc.needsFirstRunSetup, isFalse, reason: '한 번 마치면 다시 뜨지 않는다');
  });

  test('샌드박스 모드: 프로젝트가 없어도 게스트 파이썬이 도구 목록을 준다', () async {
    final wc = WorkspaceController()
      ..debugUseSandbox(runtime: runtime!, baseModules: [script]);
    final box = wc.systemSandbox();
    expect(box, isNotNull);
    expect(identical(wc.systemSandbox(), box), isTrue, reason: '한 대만 쓴다');

    final scratch = Directory(box!.projectPath);
    expect(scratch.existsSync(), isTrue);
    expect(scratch.listSync(), isEmpty, reason: '프로젝트가 아니라 빈 폴더가 /work 다');

    final module = await ToolRunner.withExecutor(SandboxToolExecutor(box)).describe(script, isBase: true);
    expect(module, isNotNull, reason: '시스템 머신이 부팅되고 describe 가 돈다');
    expect([for (final t in module!.tools) t.name], contains('read_file'));
    expect(wc.systemSandboxRunning, isTrue);

    // 화면에서 끄면 머신만 내려가고 자리는 남는다(다시 시작할 수 있다).
    await box.stop();
    expect(wc.systemSandboxRunning, isFalse);
    expect(identical(wc.systemSandbox(), box), isTrue, reason: '껐다고 새로 만들지 않는다');
    expect(scratch.existsSync(), isTrue);

    // 앱을 닫을 때만 자리와 임시 폴더를 치운다.
    await wc.stopSystemSandbox();
    expect(wc.systemSandboxOrNull, isNull);
    expect(scratch.existsSync(), isFalse, reason: '임시 폴더는 치운다');
    wc.dispose();
  },
      skip: runtime == null ? 'collabo_core_runtime 없음' : false,
      timeout: const Timeout(Duration(minutes: 3)));
}
