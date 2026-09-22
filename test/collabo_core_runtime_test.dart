// collaboCore 복사본 점검: 리포에 복사해 둔 런타임(collabo_core_runtime/)과
// Dart 패키지(packages/collabo_core)가 짝이 맞고 실제로 부팅되는가.
//
// 도구 계층을 샌드박스로 옮길 수 있는지는 CollaboCore/flutter/collabo_core_demo/test/
// collabo_ide_tools_test.dart 가 본다. 여기서는 "이 앱에 넣은 것이 도는가" 만 본다.
// 복사해 둔 런타임은 darwin-arm64 · win-x64 뿐이다 — 그 밖의 플랫폼에서는 건너뛴다.
import 'dart:io';

import 'package:collabo_core/collabo_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final runtimeDir =
      Directory(Platform.environment['COLLABO_CORE_RUNTIME'] ?? 'collabo_core_runtime').absolute.path;
  final platform = () {
    try {
      return CollaboRuntime.currentPlatform;
    } catch (_) {
      return 'unknown';
    }
  }();
  final available = File('$runtimeDir/collabo-core-$platform/manifest.json').existsSync();

  test('복사한 런타임이 부팅되고 마운트한 폴더를 게스트 파이썬이 읽는다', () async {
    final ws = Directory.systemTemp.createTempSync('collabo-core-rt-');
    File('${ws.path}/a.txt').writeAsStringSync('from host');
    final sandbox = await CollaboCore.start(
      CollaboConfig(quiet: true, networkEnabled: false, mounts: [Mount(hostPath: ws.path, guestPath: '/work')]),
      runtime: CollaboRuntime.locate(directory: runtimeDir),
    );
    try {
      final r = await sandbox.exec(['python3', '-c', 'print(open("/work/a.txt").read())']);
      expect(r.exitCode, 0, reason: r.stderrText);
      expect(r.stdoutText.trim(), 'from host');
    } finally {
      await sandbox.stop();
      ws.deleteSync(recursive: true);
    }
  }, skip: available ? false : 'collabo_core_runtime/collabo-core-$platform 없음 (복사된 것은 darwin-arm64 · win-x64)',
      timeout: const Timeout(Duration(minutes: 3)));
}
