/// LLM 스트림의 **시간 예산** — 시계가 아니라 "이 정도 토큰을 뽑을 시간" 으로 잰다.
///
/// 왜 고정 초가 아닌가: 고정 초는 모델 속도에 따라 의미가 완전히 달라진다.
/// 100 tok/s 짜리에게 900초는 9만 토큰을 뽑을 넉넉한 시간이지만, 10 tok/s 짜리에게는
/// 9천 토큰, 즉 작업 한 조각도 못 끝낼 시간이다. 그래서 기준을 뒤집는다.
///
/// ```
/// 제한 시간 = 토큰 예산 / (tok/s)      # 기본 90,000 토큰분
/// 100 tok/s → 900초 · 30 tok/s → 3,000초 · 10 tok/s → 9,000초
/// ```
///
/// 느린 모델일수록 **더 오래 기다려 준다**. 반대로 같은 문자를 무한히 뱉는 상태는
/// 속도와 무관하게 예산을 태우므로 반드시 걸린다 — 출력을 파싱해 반복을 탐지할 필요가
/// 없다는 것이 이 설계의 요점이다(§note 2026-09-11).
///
/// 출처: `expcode` 노트 3-20("시간 상한은 시계가 아니라 토큰으로 잰다").
library;

/// 스트리밍 예산을 넘겨 끊겼을 때. **재시도 대상이 아니다** — 같은 조건이면 또 걸린다.
class LlmBudgetExceeded implements Exception {
  const LlmBudgetExceeded(this.message);

  /// 사람이 읽을 수 있는 근거까지 담은 문구
  /// (예: `... 1,800s (90,000 tokens ÷ 50 tok/s measured)`).
  final String message;

  @override
  String toString() => message;
}

/// 속도를 전혀 모를 때 가정하는 값(tok/s).
const double kDefaultTokPerSec = 100;

/// 속도의 바닥. 병든 측정값이 제한 시간을 무한대로 늘리지 않게 한다
/// (90,000 예산이면 상한이 45,000초를 넘지 않는다).
const double kMinTokPerSec = 2;

// ---- 표본 규칙 ----
// 짧고 빠른 라운드는 첫 토큰 지연이 전부라 노이즈다. 반대로 **오래 걸린 라운드는
// 토큰이 적어도 버리면 안 된다** — "20분에 10토큰" 은 노이즈가 아니라 그 모델이 정말
// 느리다는 증거이고, 그걸 버리면 기본값(빠른 모델 가정)으로 되돌아가 멀쩡한 작업을 끊는다.

/// 이만큼은 나와야 표본으로 본다(단, 아래 [kSlowRoundSeconds] 예외).
const int kMinSampleTokens = 24;

/// 이보다 짧으면 무조건 버린다(측정 오차가 값보다 크다).
const double kMinSampleSeconds = 0.3;

/// 이만큼 걸린 라운드는 **토큰 수와 무관하게** 표본으로 인정한다.
const double kSlowRoundSeconds = 20;

/// 누적 토큰이 이만큼 쌓이면 실측을 믿는다.
const int kTrustAfterTokens = 60;

/// 또는 누적 시간이 이만큼 지나면 믿는다(1분쯤 지켜봤으면 느린 모델인지 알기 충분하다).
const double kTrustAfterSeconds = 60;

/// 한 프리셋(연결)의 실측 속도계. 라운드마다 표본을 더한다.
class SpeedMeter {
  int _tokens = 0;
  double _seconds = 0;

  int get sampleTokens => _tokens;
  double get sampleSeconds => _seconds;

  /// 표본 하나를 더한다. **표본으로 인정했으면 true.**
  bool add({required int completionTokens, required int elapsedMs}) {
    final seconds = elapsedMs / 1000.0;
    if (seconds < kMinSampleSeconds) return false;
    if (completionTokens < kMinSampleTokens && seconds < kSlowRoundSeconds) {
      return false;
    }
    _tokens += completionTokens;
    _seconds += seconds;
    return true;
  }

  /// 믿을 만한 실측치(아직 표본이 모자라면 null).
  double? get tps {
    if (_seconds <= 0) return null;
    if (_tokens < kTrustAfterTokens && _seconds < kTrustAfterSeconds) return null;
    final v = _tokens / _seconds;
    return v.isFinite && v > 0 ? v : null;
  }

  void reset() {
    _tokens = 0;
    _seconds = 0;
  }
}

/// 토큰 예산을 시간으로 환산한다. [tokenBudget] 이 0 이하면 **무제한**(null).
Duration? budgetToTime(int tokenBudget, double tokPerSec) {
  if (tokenBudget <= 0) return null;
  final tps = tokPerSec < kMinTokPerSec ? kMinTokPerSec : tokPerSec;
  final secs = (tokenBudget / tps).round();
  return Duration(seconds: secs < 1 ? 1 : secs);
}

/// 상한에 걸렸을 때 보여 줄 근거 문구. **왜 이 시간인지**를 같이 적는다 —
/// 숫자만 던지면 사용자는 어디를 고쳐야 할지 알 수 없다.
String budgetReason({
  required Duration limit,
  required int tokenBudget,
  required double tokPerSec,
  required String source,
}) =>
    'This response ran past its budget of ${limit.inSeconds}s '
    '($tokenBudget tokens ÷ ${tokPerSec.toStringAsFixed(0)} tok/s $source). '
    'Either the model is stuck repeating itself, or it is slower than we think — '
    'set the speed for this connection in settings, or raise the token budget.';
