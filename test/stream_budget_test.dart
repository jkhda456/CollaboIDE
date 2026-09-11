import 'package:collabo_ide/src/llm/stream_budget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('토큰 예산 → 시간 환산', () {
    test('느릴수록 더 오래 기다려 준다', () {
      // 이 표가 이 설계의 전부다 — 고정 초와 달리 모델 속도에 따라 의미가 변하지 않는다.
      expect(budgetToTime(90000, 100)!.inSeconds, 900);
      expect(budgetToTime(90000, 30)!.inSeconds, 3000);
      expect(budgetToTime(90000, 10)!.inSeconds, 9000);
    });

    test('예산이 0 이하면 제한 없음', () {
      expect(budgetToTime(0, 100), isNull);
      expect(budgetToTime(-1, 100), isNull);
    });

    test('속도 바닥이 상한을 무한대로 늘리지 못하게 막는다', () {
      // 병든 측정값(0에 가까운 속도)이 와도 45,000초를 넘지 않는다.
      expect(budgetToTime(90000, 0.001)!.inSeconds, 45000);
      expect(budgetToTime(90000, 0)!.inSeconds, 45000);
    });

    test('아무리 작은 예산이라도 최소 1초', () {
      expect(budgetToTime(1, 1000)!.inSeconds, greaterThanOrEqualTo(1));
    });
  });

  group('속도 실측 표본 규칙', () {
    test('표본이 없으면 아직 모른다', () {
      expect(SpeedMeter().tps, isNull);
    });

    test('짧고 빠른 라운드는 버린다 — 첫 토큰 지연이 전부라 노이즈다', () {
      final m = SpeedMeter();
      expect(m.add(completionTokens: 3, elapsedMs: 500), isFalse);
      expect(m.add(completionTokens: 500, elapsedMs: 100), isFalse);
      expect(m.sampleTokens, 0);
      expect(m.tps, isNull);
    });

    test('오래 걸린 라운드는 토큰이 적어도 버리지 않는다 ★', () {
      // "20분에 10토큰" 은 노이즈가 아니라 그 모델이 정말 느리다는 증거다.
      // 이걸 버리면 기본값(빠른 모델 가정)으로 되돌아가 멀쩡한 작업을 끊는다.
      final m = SpeedMeter();
      expect(m.add(completionTokens: 10, elapsedMs: 20 * 60 * 1000), isTrue);
      expect(m.tps, isNotNull);
      expect(m.tps, lessThan(0.1));
      // 그렇게 느려도 상한은 바닥(2 tok/s)에 걸려 45,000초를 넘지 않는다.
      expect(budgetToTime(90000, m.tps!)!.inSeconds, 45000);
    });

    test('누적 60토큰이 모이면 믿는다', () {
      final m = SpeedMeter();
      m.add(completionTokens: 30, elapsedMs: 1000);
      expect(m.tps, isNull);
      m.add(completionTokens: 30, elapsedMs: 1000);
      expect(m.tps, closeTo(30, 0.001));
    });

    test('또는 누적 60초를 지켜봤으면 믿는다', () {
      final m = SpeedMeter();
      m.add(completionTokens: 24, elapsedMs: 61000);
      expect(m.tps, isNotNull);
    });

    test('reset 하면 처음으로', () {
      final m = SpeedMeter();
      m.add(completionTokens: 100, elapsedMs: 2000);
      m.reset();
      expect(m.tps, isNull);
      expect(m.sampleTokens, 0);
    });
  });

  test('상한 문구는 왜 이 시간인지를 같이 적는다', () {
    // 숫자만 던지면 사용자는 어디를 고쳐야 할지 알 수 없다.
    final r = budgetReason(
      limit: const Duration(seconds: 1800),
      tokenBudget: 90000,
      tokPerSec: 50,
      source: 'measured',
    );
    expect(r, contains('1800s'));
    expect(r, contains('90000'));
    expect(r, contains('50 tok/s'));
    expect(r, contains('measured'));
  });
}
