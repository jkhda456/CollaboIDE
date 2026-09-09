import 'package:flutter/foundation.dart';

/// 도구 호출 한 건의 기록(인자 + **결과 원문**).
class ToolCallRecord {
  ToolCallRecord({
    required this.id,
    required this.scope,
    required this.name,
    required this.args,
    required this.startedAt,
  });

  /// 호출 식별자(도구 버블/활동 tid 와 같은 값).
  final String id;

  /// 어디서 부른 호출인지: 'main' | 'subagent' | 'verify'.
  final String scope;
  final String name;

  /// function calling 인자(JSON 문자열 원문).
  final String args;
  final DateTime startedAt;

  DateTime? finishedAt;
  bool? ok;

  /// 결과 원문(JSON). 너무 길면 [ToolCallLog.maxResultChars] 에서 잘린다.
  String result = '';

  /// 한 줄 요약(목록에 표시).
  String summary = '';

  bool get running => finishedAt == null;

  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);
}

/// 이번 세션의 도구 호출 기록.
///
/// **왜 네이티브에 두는가**: 결과 원문은 수십 KB 가 되기도 한다(파일 읽기, 검색,
/// 문서 구조…). 그걸 대화 버블에 그대로 뿌리면 대화가 읽을 수 없게 되고, 웹으로
/// 전부 밀면 메시지도 커진다. 그래서 원문은 네이티브가 들고 있고, 사용자가 호출
/// 내역 창을 열 때만 보여 준다(프로세스 뷰어와 같은 방식).
///
/// 대화 DB 와 다른 점: DB 에는 **메인 에이전트의** 도구 호출만 남는다(서브에이전트
/// 내부 호출은 하위 대화에 요약만 남는다). 이 로그는 **서브에이전트 내부 호출까지**
/// 포함해 "방금 무슨 일이 있었나" 를 그대로 보여 주는 용도다. 세션 한정(휘발성).
class ToolCallLog extends ChangeNotifier {
  /// 기록 상한(오래된 것부터 버린다).
  static const int maxRecords = 300;

  /// 결과 원문 1건의 상한(32KB). 넘으면 앞부분만 남기고 잘렸다고 표시한다.
  static const int maxResultChars = 32 << 10;

  final List<ToolCallRecord> _records = [];

  /// 최신이 앞에 오는 목록.
  List<ToolCallRecord> get records => List.unmodifiable(_records.reversed);

  bool get isEmpty => _records.isEmpty;
  int get length => _records.length;

  /// 호출 시작을 기록한다.
  ToolCallRecord start({
    required String id,
    required String scope,
    required String name,
    required String args,
  }) {
    final rec = ToolCallRecord(
      id: id,
      scope: scope,
      name: name,
      args: args,
      startedAt: DateTime.now(),
    );
    _records.add(rec);
    if (_records.length > maxRecords) {
      _records.removeRange(0, _records.length - maxRecords);
    }
    notifyListeners();
    return rec;
  }

  /// 호출 완료를 기록한다(결과 원문 포함).
  void finish(
    ToolCallRecord? rec, {
    required bool ok,
    required String result,
    String summary = '',
  }) {
    if (rec == null) return;
    rec.finishedAt = DateTime.now();
    rec.ok = ok;
    rec.summary = summary;
    rec.result = result.length > maxResultChars
        ? '${result.substring(0, maxResultChars)}\n… (truncated)'
        : result;
    notifyListeners();
  }

  void clear() {
    _records.clear();
    notifyListeners();
  }
}
