import 'dart:async';

/// 실행 중/완료된 런쳐 프로세스의 상태.
enum ProcessStatus { pending, running, succeeded, failed, canceled }

/// 출력 한 줄의 출처.
enum OutputChannel { stdout, stderr, system }

/// 출력 한 줄.
class OutputLine {
  const OutputLine(this.channel, this.text);
  final OutputChannel channel;
  final String text;
}

/// 하나의 Python 런쳐 프로세스. 모든 작업은 포터블 Python 으로 실행되는 스크립트다.
///
/// 결과 출력은 [output] 버퍼에 누적되며 [outputStream] 으로도 실시간 전달된다.
/// (가운데 대화창이 이를 구독해 메시지로 추가한다.)
class LauncherProcess {
  LauncherProcess({
    required this.id,
    required this.scriptPath,
    required this.args,
    required this.elevated,
    this.label,
    this.workingDirectory,
  });

  /// 프로세스 고유 ID(매니저가 부여).
  final String id;

  /// 실행할 Python 스크립트 경로.
  final String scriptPath;

  /// 스크립트에 전달할 인자.
  final List<String> args;

  /// 관리자 권한으로 상승 실행할지 여부(프로세스별 on-demand).
  final bool elevated;

  /// 표시용 라벨(없으면 스크립트 파일명을 쓴다).
  final String? label;

  /// 작업 디렉토리(보통 열린 프로젝트 경로).
  final String? workingDirectory;

  final List<OutputLine> output = [];
  final _outputController = StreamController<OutputLine>.broadcast();

  ProcessStatus _status = ProcessStatus.pending;
  int? _exitCode;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// 내부 OS 프로세스 핸들(취소용). 매니저가 설정.
  Object? backingHandle;

  Stream<OutputLine> get outputStream => _outputController.stream;
  ProcessStatus get status => _status;
  int? get exitCode => _exitCode;
  bool get isRunning =>
      _status == ProcessStatus.running || _status == ProcessStatus.pending;

  void appendLine(OutputChannel channel, String text) {
    final line = OutputLine(channel, text);
    output.add(line);
    if (!_outputController.isClosed) _outputController.add(line);
  }

  void markRunning() {
    _status = ProcessStatus.running;
    startedAt = DateTime.now();
  }

  void markFinished(int exitCode) {
    _exitCode = exitCode;
    _status = exitCode == 0 ? ProcessStatus.succeeded : ProcessStatus.failed;
    finishedAt = DateTime.now();
  }

  void markCanceled() {
    _status = ProcessStatus.canceled;
    finishedAt = DateTime.now();
  }

  void markFailed(String reason) {
    appendLine(OutputChannel.system, reason);
    _status = ProcessStatus.failed;
    finishedAt = DateTime.now();
  }

  Future<void> dispose() => _outputController.close();
}
