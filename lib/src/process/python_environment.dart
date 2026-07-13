import 'dart:io';

import 'package:path/path.dart' as p;

/// 사용할 Python 인터프리터.
///
/// 자동 다운로드 대신 **사용자가 선택한 인터프리터 경로**(base)를 사용한다
/// (설정 → 도구 → Python 설정에서 선택).
///
/// [venvPath] 를 주면 그 base 로 만든 **프로젝트별 가상환경(venv)** 을 쓴다:
/// pip 설치·스크립트 실행이 모두 venv 파이썬을 거쳐, mac/Linux 에서 시스템
/// 파이썬의 PEP 668(externally-managed) 차단·권한 문제를 피한다.
class PythonEnvironment {
  PythonEnvironment(this.interpreterPath, {this.venvPath});

  /// base Python 인터프리터 절대 경로. 비어 있으면 미설정.
  final String interpreterPath;

  /// 프로젝트별 venv 디렉토리. null/빈 값이면 venv 미사용(base 직접 실행).
  final String? venvPath;

  /// base 인터프리터가 실제로 존재하는지.
  bool get isInstalled =>
      interpreterPath.isNotEmpty && File(interpreterPath).existsSync();

  /// venv 실행 파일 경로(플랫폼별). venvPath 미지정이면 null.
  String? get venvPython {
    final vp = venvPath;
    if (vp == null || vp.isEmpty) return null;
    return Platform.isWindows
        ? p.join(vp, 'Scripts', 'python.exe')
        : p.join(vp, 'bin', 'python');
  }

  /// venv 가 실제로 생성돼 있는지.
  bool get venvReady {
    final vp = venvPython;
    return vp != null && File(vp).existsSync();
  }

  /// 실행에 쓸 **실효 파이썬**. venv 가 준비됐으면 venv, 아니면 base 인터프리터.
  String get executablePath => venvReady ? venvPython! : interpreterPath;

  /// 인터프리터를 실행해 버전 문자열을 얻는다(미설정/실패면 null).
  Future<String?> probeVersion() async {
    if (!isInstalled) return null;
    try {
      final r = await Process.run(executablePath, ['--version']);
      if (r.exitCode == 0) {
        final out = '${r.stdout}${r.stderr}'.trim();
        return out.isEmpty ? null : out;
      }
    } catch (_) {}
    return null;
  }

  /// venv 를 생성한다. 이미 있거나 [venvPath] 미지정이면 no-op.
  /// base 인터프리터로 `python -m venv <venvPath>` 를 실행한다.
  Future<VenvResult> ensureVenv() async {
    final vp = venvPath;
    if (vp == null || vp.isEmpty) return const VenvResult.skipped();
    if (venvReady) return const VenvResult.ok();
    if (!isInstalled) {
      return const VenvResult.error('Base Python interpreter is not set.');
    }
    try {
      final r = await Process.run(interpreterPath, ['-m', 'venv', vp]);
      if (r.exitCode == 0 && venvReady) return const VenvResult.ok();
      return VenvResult.error(_venvHint('${r.stdout}\n${r.stderr}'.trim()));
    } catch (e) {
      return VenvResult.error('$e');
    }
  }

  /// venv 생성 실패 메시지를 사용자 친화적으로 다듬는다(흔한 원인 안내).
  static String _venvHint(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('ensurepip') ||
        low.contains('no module named venv') ||
        low.contains('venv module')) {
      // Debian/Ubuntu 계열은 venv 가 별도 패키지(python3-venv).
      return 'Python venv module is unavailable. On Debian/Ubuntu install it '
          '(e.g. `sudo apt install python3-venv`) and try again.\n\n$raw';
    }
    return raw.isEmpty ? 'Failed to create venv.' : raw;
  }

  /// 이 인터프리터(venv 준비 시 venv)의 pip 으로 패키지를 설치한다.
  Future<ProcessResult> pipInstall(List<String> packages) =>
      Process.run(executablePath, ['-m', 'pip', 'install', ...packages]);

  /// 설치된 패키지 목록(`pip list --format=json`).
  Future<ProcessResult> pipList() =>
      Process.run(executablePath, ['-m', 'pip', 'list', '--format=json']);
}

/// venv 준비 결과.
class VenvResult {
  const VenvResult.ok()
      : ok = true,
        skipped = false,
        error = null;
  const VenvResult.skipped()
      : ok = true,
        skipped = true,
        error = null;
  const VenvResult.error(this.error)
      : ok = false,
        skipped = false;

  /// 성공(생성됨) 또는 건너뜀(venv 미사용)이면 true.
  final bool ok;

  /// venv 를 쓰지 않아 아무것도 안 한 경우.
  final bool skipped;

  /// 실패 메시지(성공이면 null).
  final String? error;
}
