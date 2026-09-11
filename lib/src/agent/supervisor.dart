/// 감독자 — 궤적을 지켜보다가 **정체**가 보이면 개입한다.
///
/// 에이전트 루프(`web_bridge.dart` 의 `_generate` / `_runSubAgent`)는 "지금 무엇을
/// 할까" 한 스텝만 본다. 이 클래스는 **그 턴 전체의 궤적**을 본다.
///
/// 지금까지 이 앱이 폭주를 막는 장치는 반복 상한 둘뿐이었다
/// (`_maxToolIterations`=20, `_maxSubIterations`=8). 그건 **사다리 없는 하드 컷**이라,
/// 같은 검색을 20번 반복하는 모델도 20라운드를 전부 태우고서야 멈춘다. 그 사이 비용은
/// 다 나가고 사용자는 아무 설명도 못 받는다.
///
/// 설계 출처는 `avo-arc-agi` 조사(`harness.md` 7장)다 — **감독자 / 정체 탐지**
/// (NVIDIA AVO supervisor), **에스컬레이션 사다리**(Retrodict 300액션 룰),
/// **종료 차단**(LangChain Ralph Loop). `expcode` 의 `app/services/harness.py` 가
/// 같은 패턴을 먼저 이식했고 임계값도 거기서 가져왔다.
///
/// 주입 문구는 **영어**다. 이 앱의 시스템 프롬프트가 전부 영어이므로, 개입만 한국어면
/// 모델이 지시의 출처를 오해한다(사용자 발화로 읽는다).
library;

/// 도구 한 번 실행의 관측치.
class StepObs {
  const StepObs({
    this.tool = '',
    this.args = '',
    this.errorSig = '',
    this.progress = false,
  });

  final String tool;

  /// 도구 인자 원문(JSON 문자열). 같은 호출인지 비교하는 데만 쓴다.
  final String args;

  /// 오류 지문(없으면 빈 문자열). [errorSignature] 로 만든다.
  final String errorSig;

  /// **진전**이 있었는가. 파일·계획·메모를 바꾼 것만 진전으로 센다.
  /// 읽기와 검색은 진전이 아니다 — 계속 읽고 검색만 하는 상태가 바로 잡아야 할 정체다.
  final bool progress;

  /// 같은 호출인지 판단하는 키. 인자 원문이 길면 앞부분만 본다.
  String get actionKey {
    final a = args.trim();
    return '$tool|${a.length > 400 ? a.substring(0, 400) : a}';
  }
}

/// 감독자가 넣는 개입 한 건.
class Intervention {
  const Intervention({
    required this.action,
    required this.reason,
    required this.message,
    required this.level,
    required this.halt,
  });

  /// 사다리 단계의 이름(`force_hypothesis` 등). 화면·로그 표기에 쓴다.
  final String action;

  /// 무엇을 보고 정체로 판단했는가(사람이 읽는 한 줄).
  final String reason;

  /// 모델에게 **user 메시지로 주입**할 지시문.
  ///
  /// system 으로 넣지 않는 이유: 대화 중간의 system 은 로컬 템플릿이 거부한다
  /// (§`message_shape.dart`). 도구 결과 뒤에 user 를 붙이는 것은 규격에 맞는다.
  final String message;

  final int level;

  /// 마지막 단계 — 이 턴의 도구 호출을 여기서 끝낸다.
  final bool halt;
}

/// 오류 문자열에서 **반복 판정용 지문**을 만든다.
///
/// 숫자를 지우는 것이 핵심이다. `line 12` 와 `line 15`, 포트 번호가 다른 같은 실패는
/// 사람 눈에는 같은 오류인데 문자열로는 다르다 — 지우지 않으면 영원히 안 걸린다.
String errorSignature(String? error) {
  if (error == null) return '';
  var s = error.toLowerCase();
  s = s.replaceAll(RegExp(r'\d+'), '#');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return '';
  return s.length > 120 ? s.substring(0, 120) : s;
}

/// 사다리. 각 단계가 모델에게 **구체적인 지시문**을 주입한다 —
/// "더 잘해봐" 류는 아무 효과가 없다는 것이 조사의 일관된 결론이었다.
///
/// 마지막 단계만 두 갈래다. 메인 대화에서는 **사용자에게 묻는 것**이 가장 싸고 확실한
/// 탈출구지만, 서브에이전트에는 사용자가 없다 — 부모에게 보고하고 끝내야 한다.
const List<({String action, String message})> kLadder = [
  (
    action: 'force_hypothesis',
    message: '[supervisor] You are going in circles. Before calling another '
        'tool, write down what you do NOT know. Use `note_write` to record the '
        'unverified assumptions as [ASSUMED], then pick the single cheapest one '
        'to check and check that one first. Do not repeat the call you just made.',
  ),
  (
    action: 'force_replan',
    message: '[supervisor] This approach is not working. Drop the current plan. '
        'Use `note_write` to record the failed approach under RULED OUT as '
        '[REFUTED], then use `update_plan` to lay out a DIFFERENT approach and '
        'start its first step. Trying the same direction again is not allowed.',
  ),
  (
    action: 'ask_user',
    message: '[supervisor] Automatic recovery has run out. Stop calling tools '
        'and ask the user. In three lines, say what you tried, what is blocking '
        'you, and what decision you need from them.',
  ),
];

/// 서브에이전트용 마지막 단계 — 사용자가 없으므로 부모에게 보고하고 끝낸다.
const String kLadderSubFinal =
    '[supervisor] Automatic recovery has run out. Stop calling tools and write '
    'your report now. In three lines, say what you tried, what is blocking you, '
    'and what you recommend the main agent do next.';

class Supervisor {
  Supervisor({
    this.enabled = true,
    this.noProgressRounds = 4,
    this.repeatWindow = 8,
    this.repeatThreshold = 3,
    this.sameErrorThreshold = 3,
    this.exitGuard = true,
    this.maxReinjections = 2,
    this.asksUserOnLastRung = true,
  });

  /// 서브에이전트용 — 임계값은 같고 마지막 단계만 다르다.
  /// 라운드 상한이 8이라 진전 없는 라운드 임계값은 조금 낮춘다.
  factory Supervisor.forSubAgent({bool enabled = true}) => Supervisor(
        enabled: enabled,
        noProgressRounds: 3,
        exitGuard: false, // 종료 차단은 메인만 — 서브는 부모가 결과를 본다
        asksUserOnLastRung: false,
      );

  final bool enabled;
  final int noProgressRounds;
  final int repeatWindow;
  final int repeatThreshold;
  final int sameErrorThreshold;
  final bool exitGuard;
  final int maxReinjections;
  final bool asksUserOnLastRung;

  int _roundsSinceProgress = 0;
  final List<String> _recentActions = [];
  final Map<String, int> _errorCounts = {};
  int level = 0;
  int reinjections = 0;
  final List<Map<String, Object?>> events = [];

  // ------------------------------------------------------------------ 관측

  /// 도구 실행 하나를 관측한다.
  Intervention? observe(StepObs obs) {
    if (!enabled) return null;
    if (obs.progress) {
      _roundsSinceProgress = 0;
      _errorCounts.clear();
    }
    if (obs.tool.isNotEmpty) {
      _recentActions.add(obs.actionKey);
      while (_recentActions.length > repeatWindow) {
        _recentActions.removeAt(0);
      }
    }
    if (obs.errorSig.isNotEmpty) {
      _errorCounts[obs.errorSig] = (_errorCounts[obs.errorSig] ?? 0) + 1;
    }
    return _maybeIntervene();
  }

  /// 한 라운드(모델 호출 + 그 라운드의 도구 실행)가 끝났을 때.
  Intervention? roundDone({required bool progress}) {
    if (!enabled) return null;
    _roundsSinceProgress = progress ? 0 : _roundsSinceProgress + 1;
    return _maybeIntervene();
  }

  Intervention? _maybeIntervene() {
    final reason = _stagnationReason();
    if (reason == null) return null;
    level++;
    // 개입했으면 탐지기를 비운다 — 안 그러면 다음 스텝에서 같은 이유로 또 걸려
    // 사다리를 순식간에 끝까지 타 버린다.
    _resetDetectors();
    final rung = kLadder[(level < kLadder.length ? level : kLadder.length) - 1];
    final isLast = rung.action == 'ask_user';
    final body =
        (isLast && !asksUserOnLastRung) ? kLadderSubFinal : rung.message;
    events.add({'level': level, 'reason': reason, 'action': rung.action});
    return Intervention(
      action: rung.action,
      reason: reason,
      message: '$body\n\n(detected stagnation: $reason)',
      level: level,
      halt: isLast,
    );
  }

  String? _stagnationReason() {
    if (_roundsSinceProgress >= noProgressRounds) {
      return 'no progress for $_roundsSinceProgress rounds';
    }
    if (_recentActions.length >= repeatWindow) {
      String? top;
      var topCount = 0;
      for (final a in _recentActions.toSet()) {
        final n = _recentActions.where((x) => x == a).length;
        if (n > topCount) {
          top = a;
          topCount = n;
        }
      }
      if (top != null && topCount >= repeatThreshold) {
        final name = top.split('|').first;
        return 'the same `$name` call repeated $topCount times '
            'in the last ${_recentActions.length}';
      }
    }
    for (final e in _errorCounts.entries) {
      if (e.value >= sameErrorThreshold) {
        return 'the same error ${e.value} times: ${e.key}';
      }
    }
    return null;
  }

  void _resetDetectors() {
    _roundsSinceProgress = 0;
    _recentActions.clear();
    _errorCounts.clear();
  }

  // ------------------------------------------------------------- 종료 차단

  /// 모델이 턴을 끝내려 할 때 **정말 끝났는지** 본다. 위반 목록(비면 통과).
  ///
  /// 대화형 IDE 라 기준을 **좁게** 잡았다. 도구를 한 번도 쓰지 않은 턴(순수 대화)과
  /// 사용자에게 되묻는 답변은 검사하지 않는다 — 질문을 막아 세우면 제품이 망가진다.
  /// 계획이 없으면 위반도 없다. 즉 계획을 안 쓰는 사용자에게는 아무 영향이 없다.
  List<String> exitViolations({
    required List<String> openSteps,
    required bool usedTools,
    required String finalText,
  }) {
    if (!enabled || !exitGuard || !usedTools || asksUser(finalText)) {
      return const [];
    }
    if (openSteps.isEmpty) return const [];
    final shown = openSteps.take(4).join(', ');
    final more = openSteps.length > 4 ? ' (+${openSteps.length - 4} more)' : '';
    return [
      'The plan still has unfinished steps: $shown$more. Either finish them, '
          'or mark them DONE/DROP with `update_plan` and say why.',
    ];
  }

  bool get mayReinject => reinjections < maxReinjections;
  void noteReinjection() => reinjections++;

  Map<String, Object?> snapshot() => {
        'level': level,
        'events': events.length,
        'reinjections': reinjections,
      };
}

/// 마지막 문장이 사용자에게 되묻는 형태인가.
///
/// 프롬프트는 영어지만 **모델은 사용자 언어로 답한다** — 한국어 종결형도 같이 본다.
/// 종결형까지 포함해야 한다 — `알려 주세요.` 는 `알려\s*주` 로는 안 걸린다
/// (뒤에 `세요.` 가 남아 `$` 에 닿지 못한다). 실제로 테스트에서 걸린 지점이다.
final RegExp _questionRe = RegExp(
  r'(\?|드릴까요|할까요|하시겠|주시겠|주세요|주십시오|어느\s*쪽|무엇을\s*할)'
  r'\s*[.!]*\s*$',
);

bool asksUser(String? text) {
  final t = (text ?? '').trim();
  if (t.isEmpty) return false;
  final tail = t.length > 160 ? t.substring(t.length - 160) : t;
  return _questionRe.hasMatch(tail);
}
