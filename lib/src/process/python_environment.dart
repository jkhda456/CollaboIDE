import 'dart:io';

/// 사용할 Python 인터프리터.
///
/// 자동 다운로드 대신 **사용자가 선택한 인터프리터 경로**를 사용한다.
/// (설정 → 도구 → Python 설정에서 선택)
class PythonEnvironment {
  PythonEnvironment(this.interpreterPath);

  /// Python 인터프리터 절대 경로. 비어 있으면 미설정.
  final String interpreterPath;

  /// 인터프리터가 실제로 존재하는지.
  bool get isInstalled =>
      interpreterPath.isNotEmpty && File(interpreterPath).existsSync();

  /// 인터프리터를 실행해 버전 문자열을 얻는다(미설정/실패면 null).
  Future<String?> probeVersion() async {
    if (!isInstalled) return null;
    try {
      final r = await Process.run(interpreterPath, ['--version']);
      if (r.exitCode == 0) {
        final out = '${r.stdout}${r.stderr}'.trim();
        return out.isEmpty ? null : out;
      }
    } catch (_) {}
    return null;
  }

  /// 이 인터프리터의 pip 으로 패키지를 설치한다.
  Future<ProcessResult> pipInstall(List<String> packages) =>
      Process.run(interpreterPath, ['-m', 'pip', 'install', ...packages]);

  /// 설치된 패키지 목록(`pip list --format=json`).
  Future<ProcessResult> pipList() =>
      Process.run(interpreterPath, ['-m', 'pip', 'list', '--format=json']);
}
