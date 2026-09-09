import 'package:collabo_ide/src/llm/llm_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('첫 응답(프리필) 대기 시간', () {
    test('기본값은 상수 그대로이고 Duration 으로 읽힌다', () {
      const cfg = LlmConfig();
      expect(cfg.firstResponseTimeoutSec,
          LlmConfig.defaultFirstResponseTimeoutSec);
      expect(cfg.firstResponseTimeout,
          const Duration(seconds: LlmConfig.defaultFirstResponseTimeoutSec));
    });

    test('0 은 제한 없음(null) — 프리필을 시간으로 끊지 않는다', () {
      const cfg = LlmConfig(firstResponseTimeoutSec: 0);
      expect(cfg.firstResponseTimeout, isNull);
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
}
