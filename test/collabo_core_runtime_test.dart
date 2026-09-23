// collaboCore 복사본 점검: 리포에 복사해 둔 런타임(collabo_core_runtime/)과
// Dart 패키지(packages/collabo_core)가 짝이 맞고 실제로 부팅되는가.
//
// 도구 계층을 샌드박스로 옮길 수 있는지는 CollaboCore/flutter/collabo_core_demo/test/
// collabo_ide_tools_test.dart 가 본다. 여기서는 "이 앱에 넣은 것이 도는가" 만 본다.
// 복사해 둔 런타임은 darwin-arm64 · win-x64 뿐이다 — 그 밖의 플랫폼에서는 건너뛴다.
import 'dart:convert';
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

  // 2026-09-22 밤 릴리스부터: /init 이 devpts 를 올리고 콘솔 셸에 제어 터미널을 주며,
  // pip 과 네트워크 도구(tools.cpio)가 들었다. 앱은 이제 이걸 전제한다 — 부팅 직후 하던
  // 보완(devpts mount, 콘솔 셸 `setsid -c`)을 지웠다. tools 이미지가 없는 옛 런타임
  // (`COLLABO_CORE_RUNTIME` 으로 가리킨 경우)에서는 건너뛴다.
  final hasTools = available &&
      CollaboRuntime.locate(directory: runtimeDir).arguments.contains('--tools-image');
  test('새 이미지: 콘솔 제어 터미널 · devpts · pip · curl/git/ssh', () async {
    final sandbox = await CollaboCore.start(
      const CollaboConfig(quiet: true, networkEnabled: false),
      runtime: CollaboRuntime.locate(directory: runtimeDir),
    );
    try {
      // init(pid 1)의 자식 sh 가 제어 터미널을 가졌다(tty_nr ≠ 0) — 앱의 보완이 할 일이 없다.
      final tty = await sandbox.run(
        r'for d in /proc/[0-9]*; do s=$(cat $d/stat 2>/dev/null) || continue; '
        r'set -- $s; [ "$4" = 1 ] && [ "$2" = "(sh)" ] && echo "$7"; done; true',
      );
      final ttys = tty.stdoutText.trim().split('\n').where((s) => s.isNotEmpty).toList();
      expect(ttys, isNotEmpty, reason: '콘솔 셸을 못 찾았다');
      expect(ttys, everyElement(isNot('0')));

      final pty = await sandbox.exec(['python3', '-c', 'import os; m, s = os.openpty(); print(os.ttyname(s))']);
      expect(pty.stdoutText.trim(), startsWith('/dev/pts/'), reason: pty.stderrText);

      final pip = await sandbox.exec(['python3', '-m', 'pip', '--version']);
      expect(pip.exitCode, 0, reason: pip.stderrText);

      for (final cmd in ['curl --version', 'git --version', 'ssh -V']) {
        final r = await sandbox.run('$cmd 2>&1');
        expect(r.exitCode, 0, reason: '$cmd: ${r.stdoutText}');
      }
    } finally {
      await sandbox.stop();
    }
  }, skip: hasTools ? false : 'tools 이미지가 없는 옛 런타임',
      timeout: const Timeout(Duration(minutes: 3)));

  // 콘솔에 한글을 치면 **화면에** 한글로 보여야 한다. busybox defconfig 는 U+02FF 위를 못 찍는
  // 글자로 보고 '?' 로 바꿨다 — 게스트에 간 바이트는 멀쩡한데 줄 편집기 에코와 ls 가 `??` 였다
  // (CollaboCore userspace/build-busybox.sh 의 LAST_SUPPORTED_WCHAR=0 으로 고침).
  //
  // 콘솔(진짜 tty)로 본다 — busybox 는 tty 로 나갈 때만 바꿔 치운다. `ls | od` 같은 파이프는
  // 옛 이미지에서도 바이트가 멀쩡해서 알아보지 못한다.
  test('콘솔: 한글 입력이 그대로 보이고 ls 도 한글 이름을 찍는다', () async {
    final core = await CollaboCore.start(
      const CollaboConfig(quiet: true, networkEnabled: false),
      runtime: CollaboRuntime.locate(directory: runtimeDir),
    );
    final out = <int>[];
    final sub = core.console.listen(out.addAll);
    try {
      await core.run('mkdir -p /tmp/uni && touch /tmp/uni/한글.txt');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      out.clear();
      await core.writeConsole('ls /tmp/uni # 가나다\r');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      String text() => utf8.decode(out, allowMalformed: true);
      while (DateTime.now().isBefore(deadline) && !text().contains('한글.txt')) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(text(), contains('# 가나다'), reason: '줄 편집기 에코: ${text()}');
      expect(text(), contains('한글.txt'), reason: 'ls: ${text()}');
      expect(text(), isNot(contains('??')));
    } finally {
      await sub.cancel();
      await core.stop();
    }
  }, skip: available ? false : 'collabo_core_runtime/collabo-core-$platform 없음',
      timeout: const Timeout(Duration(minutes: 3)));
}
