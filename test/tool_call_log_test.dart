import 'package:collabo_ide/src/tools/tool_call_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// 저장본으로 다시 채울 때(대화를 다시 그릴 때) **돌고 있는 호출을 잃지 않는지.**
void main() {
  ToolCallRecord stored(int seq, String name, DateTime at) => ToolCallRecord(
        id: 't$seq',
        scope: 'main',
        name: name,
        args: '{}',
        startedAt: at,
      )
        ..storeId = seq
        ..ok = true
        ..finishedAt = at;

  test('저장이 끝난 실행 중 호출은 메모리의 그 객체를 그대로 쓴다', () {
    final log = ToolCallLog();
    final live = log.start(id: 'x', scope: 'main', name: 'run', args: '{}')..storeId = 7;
    log.replaceAll([stored(6, 'old', DateTime(2020)), stored(7, 'run', live.startedAt)]);
    expect(log.length, 2);
    expect(identical(log.records.first, live), isTrue,
        reason: '끝나면 이 객체가 채워진다 — 저장본 복사로 바뀌면 영원히 "실행 중" 으로 남는다');
    log.finish(live, ok: true, result: 'r');
    expect(log.records.first.running, isFalse);
  });

  test('아직 저장이 안 끝난 호출은 뒤에 붙는다(시작점 이전 것은 버린다)', () {
    final log = ToolCallLog();
    final pending = log.start(id: 'p', scope: 'main', name: 'pending', args: '{}');
    log.replaceAll([stored(1, 'a', DateTime(2020))], since: DateTime(2019));
    expect(log.records.map((r) => r.name), ['pending', 'a']);

    log.replaceAll(const [], since: pending.startedAt.add(const Duration(seconds: 1)));
    expect(log.isEmpty, isTrue);
  });

  test('결과 원문은 상한에서 자른다', () {
    final long = 'x' * (ToolCallLog.maxResultChars + 10);
    expect(ToolCallLog.clipResult(long), endsWith('(truncated)'));
    expect(ToolCallLog.clipResult('short'), 'short');
  });
}
