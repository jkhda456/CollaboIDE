import 'dart:io';

import 'package:collabo_ide/src/process/python_environment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// venvPath 안에 플랫폼에 맞는 가짜 python 실행 파일을 만들어 venvReady 를 흉내낸다.
File _fakeVenvPython(String venvPath) {
  final rel = Platform.isWindows
      ? p.join('Scripts', 'python.exe')
      : p.join('bin', 'python');
  final f = File(p.join(venvPath, rel));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('');
  return f;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('collabo_py_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('venvPath 미지정: executablePath 는 base, venvReady=false', () {
    final env = PythonEnvironment('/usr/bin/python3');
    expect(env.venvPath, isNull);
    expect(env.venvPython, isNull);
    expect(env.venvReady, isFalse);
    expect(env.executablePath, '/usr/bin/python3');
  });

  test('venvPath 지정했지만 아직 생성 전: base 로 폴백', () {
    final venv = p.join(tmp.path, '.collabo', 'venv');
    final env = PythonEnvironment('/usr/bin/python3', venvPath: venv);
    expect(env.venvReady, isFalse);
    expect(env.executablePath, '/usr/bin/python3'); // 아직 venv 없음 → base
    // venvPython 은 플랫폼별 경로를 계산해 준다.
    expect(env.venvPython, isNotNull);
    expect(env.venvPython, startsWith(venv));
  });

  test('venv 가 생성돼 있으면 executablePath 는 venv 파이썬', () {
    final venv = p.join(tmp.path, '.collabo', 'venv');
    final py = _fakeVenvPython(venv);
    final env = PythonEnvironment('/usr/bin/python3', venvPath: venv);
    expect(env.venvReady, isTrue);
    expect(env.executablePath, py.path);
  });

  test('ensureVenv: venvPath 없으면 skipped(ok)', () async {
    final env = PythonEnvironment('/usr/bin/python3');
    final r = await env.ensureVenv();
    expect(r.ok, isTrue);
    expect(r.skipped, isTrue);
  });

  test('ensureVenv: base 인터프리터가 없으면 error', () async {
    final venv = p.join(tmp.path, 'venv');
    final env = PythonEnvironment(p.join(tmp.path, 'no_such_python'),
        venvPath: venv);
    final r = await env.ensureVenv();
    expect(r.ok, isFalse);
    expect(r.error, isNotNull);
  });

  test('ensureVenv: 이미 준비됐으면 즉시 ok(재생성 안 함)', () async {
    final venv = p.join(tmp.path, 'venv');
    _fakeVenvPython(venv);
    final env = PythonEnvironment(p.join(tmp.path, 'no_such_python'),
        venvPath: venv);
    // base 가 없어도 이미 venvReady 면 생성 시도 없이 ok.
    final r = await env.ensureVenv();
    expect(r.ok, isTrue);
    expect(r.skipped, isFalse);
  });
}
