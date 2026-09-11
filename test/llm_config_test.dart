import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('첫 응답(프리필) 대기 시간', () {
    test('기본은 제한 없음 — 프리필은 시계로 판단할 수 없다', () {
      // 프리필 중에는 서버가 아무것도 내보내지 않으므로 "일하는 중" 과 "죽은 연결" 을
      // 시계로 구분할 수 없다. 구분도 못 하면서 멀쩡한 작업을 죽이지 않는다.
      const cfg = LlmConfig();
      expect(cfg.firstResponseTimeoutSec, 0);
      expect(cfg.firstResponseTimeout, isNull);
    });

    test('값을 넣으면 그만큼만 기다린다', () {
      const cfg = LlmConfig(firstResponseTimeoutSec: 300);
      expect(cfg.firstResponseTimeout, const Duration(minutes: 5));
    });

    test('JSON 왕복에서 보존된다', () {
      const cfg = LlmConfig(
        baseUrl: 'http://127.0.0.1:8080/v1',
        model: 'local',
        firstResponseTimeoutSec: 1800,
      );
      final back = LlmConfig.fromJson(cfg.toJson());
      expect(back.firstResponseTimeoutSec, 1800);
      expect(back.firstResponseTimeout, const Duration(minutes: 30));
    });

    test('키가 없는 예전 설정은 기본값으로 읽는다', () {
      // 이 필드가 생기기 전에 저장된 프리셋(예전 동작은 5분 고정).
      final back = LlmConfig.fromJson(const {
        'baseUrl': 'http://x/v1',
        'model': 'm',
      });
      expect(back.firstResponseTimeoutSec,
          LlmConfig.defaultFirstResponseTimeoutSec);
    });

    test('음수는 0(제한 없음)으로 정규화한다', () {
      final back = LlmConfig.fromJson(const {'firstResponseTimeoutSec': -5});
      expect(back.firstResponseTimeoutSec, 0);
      expect(back.firstResponseTimeout, isNull);
    });

    test('실수로 저장돼 있어도 정수로 읽는다', () {
      // 설정이 다른 경로로 쓰이면 60.0 처럼 들어올 수 있다(num 으로 받는다).
      final back = LlmConfig.fromJson(const {'firstResponseTimeoutSec': 60.0});
      expect(back.firstResponseTimeoutSec, 60);
    });

    test('copyWith: 지정하지 않으면 유지, 지정하면 바뀐다', () {
      const cfg = LlmConfig(firstResponseTimeoutSec: 120);
      expect(cfg.copyWith(model: 'other').firstResponseTimeoutSec, 120);
      expect(cfg.copyWith(firstResponseTimeoutSec: 0).firstResponseTimeoutSec, 0);
    });
  });

  group('토큰 예산 · 처리 속도', () {
    test('기본 예산은 90,000 토큰', () {
      expect(const LlmConfig().responseTokenBudget, 90000);
      expect(LlmConfig.defaultResponseTokenBudget, 90000);
    });

    test('속도는 기본이 미지정(0)이고 그때는 기본값 100 으로 읽힌다', () {
      const cfg = LlmConfig();
      expect(cfg.speedTps, 0);
      expect(cfg.measuredTps, 0);
      expect(cfg.storedTps, 100);
    });

    test('storedTps: 사용자 지정 → 저장된 실측 → 기본값 순', () {
      expect(const LlmConfig(measuredTps: 42).storedTps, 42);
      expect(const LlmConfig(speedTps: 7, measuredTps: 42).storedTps, 7);
    });

    test('JSON 왕복에서 셋 다 보존된다', () {
      const cfg = LlmConfig(
        baseUrl: 'http://127.0.0.1:8080/v1',
        model: 'local',
        responseTokenBudget: 120000,
        speedTps: 12.5,
        measuredTps: 9.5,
      );
      final back = LlmConfig.fromJson(cfg.toJson());
      expect(back.responseTokenBudget, 120000);
      expect(back.speedTps, 12.5);
      expect(back.measuredTps, 9.5);
    });

    test('키가 없는 예전 설정은 기본값으로 읽는다', () {
      final back = LlmConfig.fromJson(const {'model': 'm'});
      expect(back.responseTokenBudget, LlmConfig.defaultResponseTokenBudget);
      expect(back.speedTps, 0);
      expect(back.measuredTps, 0);
    });

    test('이상한 속도 값은 미지정(0)으로 떨어뜨린다', () {
      for (final bad in [-3, 0, 'fast']) {
        expect(LlmConfig.fromJson({'speedTps': bad}).speedTps, 0, reason: '$bad');
      }
    });

    test('예산 음수는 0(제한 없음)으로 정규화', () {
      expect(
        LlmConfig.fromJson(const {'responseTokenBudget': -5}).responseTokenBudget,
        0,
      );
    });
  });
}
