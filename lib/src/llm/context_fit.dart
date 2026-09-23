import 'dart:convert';
import 'dart:math' as math;

import 'package:afm_bridge/afm_bridge.dart' show AfmBridgeException;

import 'llm_config.dart';

/// 컨텍스트 길이 초과 오류인가. **다시 보내도 같은 입력이면 또 넘친다** — 재시도에서 뺀다.
///
/// Apple 온디바이스는 `AfmBridgeException(code: context_length_exceeded)`, OpenAI 호환 서버는
/// `HTTP 400` 본문에 코드나 문구가 들어온다(OpenAI·vLLM·LM Studio·llama.cpp 등).
bool isContextLengthError(Object e) {
  if (e is AfmBridgeException) return e.code == 'context_length_exceeded';
  final text = e.toString().toLowerCase();
  return text.contains('context_length_exceeded') ||
      text.contains('maximum context length') ||
      text.contains('context length exceeded') ||
      text.contains('exceeds the context window') ||
      text.contains('exceed_context_size_error');
}

/// 컨텍스트가 **작은 모델**(Apple 온디바이스 4K 등)에 요청을 맞춘다.
///
/// 기본 구성(시스템 프롬프트 ~1.4K + 도구 32개 ~7.4K 토큰, 2026-09-23 Apple 토크나이저 실측)은
/// 대화 한 줄 없이도 4K 를 넘는다. 창이 [smallWindowLimit] 이하이고 자동 맞춤이 켜져 있으면:
///  - 도구: **도구를 가장 나중에 줄인다**(도구가 없으면 쓸모가 크게 떨어진다 — 사용자 요청 2026-09-23).
///    설명을 첫 문장으로 줄이고([compactTool] — 기본 도구 16개 2.4K→1.9K, 전체 7.4K→5.4K 실측),
///    프롬프트 몫·대화 최소 몫을 뺀 나머지를 전부 도구에 준다. 개수 상한은 없다.
///    [corePriority] 순서로 싣고, 서브에이전트·검증·계획 도구만 뺀다(4K 로는 위임할 여유가 없다).
///  - 시스템 프롬프트: **기본값을 그대로 쓰는 중이면** [kCompactSystemPrompt] 로 바꾼다.
///    사용자가 고친 프롬프트는 건드리지 않는다(길면 설정 화면이 경고만 한다).
///  - 보조 주입(프로젝트 상태·계획·사전 평가·감독자)은 끈다.
/// 대화 기록은 엔진이 넘칠 때 앞에서부터 자른다(AFMBridge `trimHistory`).
class ContextFit {
  const ContextFit._(this.window, this.active);

  /// 모델의 컨텍스트 창(토큰). 0 = 모름(맞추지 않는다).
  final int window;

  /// 작은 창이라 맞춤을 적용하는가.
  final bool active;

  /// 이 크기 이하이면 "작은 창" 으로 본다.
  static const int smallWindowLimit = 16384;

  /// 입력 중 시스템 프롬프트 몫과 대화에 남길 최소 몫. **나머지는 전부 도구**다.
  static const double promptShare = 0.15;
  static const double conversationShare = 0.25;

  /// 작은 창에서 먼저 싣는 도구(앞일수록 우선). 목록에 없는 도구는 그 뒤에 원래 순서로.
  /// 기본 모듈(파일·명령) 전체가 먼저이고, 문서·터미널·웹 도구는 남는 자리에 들어간다.
  static const List<String> corePriority = [
    'read_file',
    'list_directory',
    'edit_file',
    'write_file',
    'search_text',
    'run_command',
    'create_file',
    'read_lines',
    'replace_lines',
    'create_directory',
    'move_path',
    'delete_path',
    'run_wait',
    'check_command',
    'stop_command',
    'request_elevation',
  ];

  /// 작은 창에서 싣지 않는 도구(위임·계획 — 4K 로는 다른 모델을 부를 여유가 없다).
  static const Set<String> excludedWhenSmall = {
    'run_subagent',
    'verify_work',
    'set_goal',
    'update_plan',
    'note_write',
  };

  factory ContextFit.of(LlmConfig cfg) {
    final w = cfg.effectiveContextWindow;
    return ContextFit._(w, cfg.autoFitContext && w > 0 && w <= smallWindowLimit);
  }

  /// 응답 몫. AFMBridge 엔진이 `max_tokens` 가 없을 때 비워 두는 양과 같다.
  int get outputReserve => math.min(1024, window ~/ 4);

  /// 입력(프롬프트+도구+대화) 몫.
  int get inputBudget => math.max(0, window - outputReserve);

  int get promptBudget => (inputBudget * promptShare).floor();

  /// 대화(기록·이번 요청)에 남길 최소 몫. 넘치는 기록은 엔진이 앞에서부터 자른다.
  int get conversationFloor => (inputBudget * conversationShare).floor();

  /// 도구 몫 = 입력 − 프롬프트 몫 − 대화 최소 몫.
  int get toolBudget => math.max(0, inputBudget - promptBudget - conversationFloor);

  // ------------------------------------------------------------ 추정

  /// 텍스트 토큰 추정(보수적). 영문 ~3.9자/토큰, 한글 등 비 ASCII 는 거의 글자당 1토큰.
  static int estimateText(String text) {
    var ascii = 0;
    var other = 0;
    for (final r in text.runes) {
      if (r < 0x80) {
        ascii++;
      } else {
        other++;
      }
    }
    return (ascii / 3.6 + other * 0.9).ceil();
  }

  /// 도구 정의 하나의 토큰 추정. 스키마 JSON 은 ~2.8~3.6자/토큰(실측) → 2.9 + 도구당 10.
  static int estimateTool(Map<String, Object?> tool) => (jsonEncode(tool).length / 2.9).ceil() + 10;

  /// 도구 정의를 줄인다: 도구 설명은 첫 문장(최대 120자), 인자 설명은 첫 문장(최대 60자).
  /// 이름·인자·타입·필수 여부는 그대로라 호출 방법은 변하지 않는다.
  static Map<String, Object?> compactTool(Map<String, Object?> tool) {
    final fn = tool['function'];
    if (fn is! Map) return tool;
    return {
      ...tool,
      'function': {
        ...fn.cast<String, Object?>(),
        'description': _firstSentence(fn['description'], 120),
        if (fn['parameters'] is Map) 'parameters': _compactSchema(fn['parameters'] as Map),
      },
    };
  }

  static Map<String, Object?> _compactSchema(Map schema) {
    final out = <String, Object?>{};
    schema.forEach((k, v) {
      final key = k as String;
      if (key == 'description') {
        out[key] = _firstSentence(v, 60);
      } else if (key == 'properties' && v is Map) {
        out[key] = {for (final e in v.entries) e.key as String: e.value is Map ? _compactSchema(e.value as Map) : e.value};
      } else if (key == 'items' && v is Map) {
        out[key] = _compactSchema(v);
      } else {
        out[key] = v;
      }
    });
    return out;
  }

  static String _firstSentence(Object? text, int max) {
    final s = (text is String ? text : '').trim();
    final m = RegExp(r'^.*?[.!?](?=\s|$)', dotAll: true).firstMatch(s);
    final first = (m?.group(0) ?? s).trim();
    return first.length <= max ? first : '${first.substring(0, max - 1).trimRight()}…';
  }

  static String toolName(Map<String, Object?> tool) {
    final fn = tool['function'];
    if (fn is Map && fn['name'] is String) return fn['name'] as String;
    return (tool['name'] as String?) ?? '';
  }

  // ------------------------------------------------------------ 결정

  /// 실을 도구를 고른다(줄인 정의로). [active] 가 아니면 그대로 돌려준다.
  List<Map<String, Object?>> selectTools(List<Map<String, Object?>> tools) {
    if (!active) return tools;
    final candidates = [
      for (final t in tools)
        if (!excludedWhenSmall.contains(toolName(t))) compactTool(t),
    ];
    // 우선순위: corePriority 순, 나머지는 원래 순서(정렬 전에 위치를 고정해 둔다).
    final original = {for (var i = 0; i < candidates.length; i++) toolName(candidates[i]): i};
    int rank(Map<String, Object?> t) {
      final i = corePriority.indexOf(toolName(t));
      return i < 0 ? corePriority.length + original[toolName(t)]! : i;
    }

    final byPriority = [...candidates]..sort((a, b) => rank(a).compareTo(rank(b)));
    final out = <Map<String, Object?>>[];
    var used = 0;
    for (final t in byPriority) {
      final cost = estimateTool(t);
      if (used + cost > toolBudget) continue; // 큰 도구는 건너뛰고 작은 것을 더 싣는다
      out.add(t);
      used += cost;
    }
    // 원래 순서를 유지해 보낸다(모델에게 보이는 순서가 매번 흔들리지 않게).
    final chosen = {for (final t in out) toolName(t)};
    return [for (final t in candidates) if (chosen.contains(toolName(t))) t];
  }

  /// 보낼 시스템 프롬프트. 기본 프롬프트를 쓰는 중이면 간결판으로 바꾼다.
  String systemPrompt(String prompt, {required bool isDefault}) =>
      active && isDefault ? kCompactSystemPrompt : prompt;

  /// 사용자가 고친 프롬프트가 프롬프트 몫을 넘는가(설정 화면 경고용).
  bool promptTooLong(String prompt) => active && estimateText(prompt) > promptBudget;
}

/// 작은 컨텍스트(≤16K) 모델용 기본 시스템 프롬프트. 기본 프롬프트(~1.4K 토큰)의 핵심만 남겼다(~200 토큰).
const String kCompactSystemPrompt = '''
You are a coding assistant inside Collabo IDE, helping the user with the project that is open.
- Reply in the user's language. Be brief and concrete.
- Use the provided tools to look at and change files; never guess file contents. Paths are relative to the project root.
- Read a file before editing it, and change only what the request needs.
- After changing files, say in one or two sentences what you changed.
- If a task clearly needs more than a few files or steps, do the first useful part and tell the user that a larger model (Settings > Model) will handle the whole task better.''';
