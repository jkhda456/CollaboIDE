import '../agent/playbook.dart' show kPlaybookPath;

/// 에이전트가 만드는 **일회성 작업 스크립트**를 두는 위치(프로젝트 상대 경로).
///
/// 앱 작업 폴더 `.collabo` 안이라 프로젝트 전체 검색에서 제외된다
/// (`FileService._skipDirs`, `collabo_tools.search_text`) — 사용자 코드베이스와
/// 에이전트 자신의 탐색을 임시 파일이 오염시키지 않는다. 트리에는 보인다.
///
/// 프롬프트 3곳(메인 / 서브에이전트 / 검증)이 **같은 경로**를 말해야 하므로
/// 여기서 한 번만 정의한다.
const String kAgentScratchDir = '.collabo/scripts';

/// 지난 턴에서 **위임했다는 사실**만 남길 때 쓰는 마커.
///
/// 위임 결과 원문은 컨텍스트에 넣지 않는다(길어서 메인 컨텍스트를 갉아먹는다).
/// 대신 이 마커 한 줄이 남고, 실제 내용은 **턴 요약**과 **프로젝트 상태**가 전달한다.
/// 마커를 바꾸면 [kDelegationMarkerNote] 의 설명도 같이 바뀐다(같은 상수를 쓴다).
const String kDelegationMarker = '[delegated]';

/// 위 마커와 도구 결과의 `delegated_to` 를 모델에게 설명하는 문단.
///
/// **세 프롬프트가 같은 문구를 쓰도록** 여기 한 번만 적는다. 사용자가 메인 프롬프트를
/// 편집해 저장했더라도 이 설명이 사라지지 않게, 메인 컨텍스트에는 별도 system 메시지로도
/// 넣는다(`AgentLoop._buildContextMessages`).
const String kDelegationMarkerNote = '''
Markers used in this conversation
- A tool result containing `delegated_to` was produced by a separate sub-agent
  with its own context — not by you directly. Treat it as a report from someone
  else: trust the outcome, but you did not see the steps.
- Earlier turns may contain lines like `$kDelegationMarker run_subagent — <task>`.
  That means you delegated that step. **Its transcript is deliberately NOT in this
  context** (it would be far too long). What survives is the turn summary and the
  project state. If you need details of that work, inspect the project with your
  tools instead of guessing or redoing it.''';

/// 계획 메모리(`$kPlaybookPath`)를 쓰는 규율.
///
/// **세 프롬프트가 같은 문구를 써야 하므로 여기 한 번만 적는다** — 기본 프롬프트,
/// 그리고 사용자가 프롬프트를 편집해 이 문단이 사라졌을 때 별도로 주입하는 경로
/// (`AgentLoop._buildContextMessages`). 계획 메모리가 꺼져 있으면 어디에도 넣지 않는다
/// (없는 도구를 설명하지 않는다).
///
/// 요점은 **계획이 대화 밖에 있다**는 것이다. 이 앱의 어시스턴트 본문은 다음 턴에
/// 턴 요약으로 대체되고 시작점 앞은 통째로 사라진다 — 계획이 답변 안에만 있으면
/// 계획도 같이 사라진다.
const String kPlanningNote = '''
Planning (the plan lives in a file, not in this chat)
- For anything past a one-step answer, START by calling `set_goal` with the goal
  in one sentence and the steps you intend to take. Do this BEFORE the work, not
  as a summary afterwards.
- The goal and plan are stored in `$kPlaybookPath`, outside this conversation.
  Earlier turns here get replaced by short summaries as the chat grows, so that
  file — not your memory of the chat — is the record of what you set out to do.
  Trust it when the two disagree.
- Move each step along with `update_plan` as you go: DOING when you start it,
  DONE the moment it is genuinely finished, DROP if you decide against it (say
  why). Do not batch these updates up at the end.
- Do not end your turn with steps still TODO or DOING. If you are stopping
  early, mark what remains DROP and tell the user what is left and why.
- **If you need to ask the user something and wait for their answer, first mark
  that step BLOCKED with `update_plan`, then ask your question.** That is the
  only way to hand the turn back with the step unfinished — asking in prose
  alone is not enough, because nothing but the plan tells the app you are
  waiting. A BLOCKED step shows on the plan card as waiting on the user; pick it
  back up (DOING) when they answer.
- Use `note_write` for anything you would hate to rediscover: how this project
  actually works (working_model), an approach you tried that failed (ruled_out),
  or something still unknown (open_questions). Mark each one VERIFIED (you just
  checked it with a tool), ASSUMED (you believe it but have not checked) or
  REFUTED (you tried it and it does not work). Recording an assumption as
  VERIFIED poisons every decision that follows it.
- Do not plan trivia. A single question or one file read needs no plan.''';

/// 서브에이전트에 붙이는 계획 규율(한 문단). 서브는 계획의 **주인이 아니다**.
const String kSubAgentPlanningNote =
    'You are one part of a larger plan that the main agent owns — do not rewrite '
    'it. If you learn something worth keeping (how this project really works, or '
    'an approach that turned out not to work), record it as one line with '
    '`note_write` and mark it VERIFIED, ASSUMED or REFUTED honestly.';

/// 기본 시스템 프롬프트(영어) — **항상 필요한 핵심만** 담는다. 사용자가 설정에서 편집할 수 있으며,
/// 비워두거나 초기화하면 이 기본값이 쓰인다.
///
/// 도구마다 필요한 안내(위임·검증·긴 명령·터미널·큰 파일·계획)는 여기 박지 않는다 — 그 도구가
/// **실제로 켜져 있을 때만** [toolGuidesFor] 가 붙인다(2026-09-23 정리: 꺼 둔 도구 설명이 매번
/// 프롬프트를 차지하고, 없는 도구를 모델이 찾는 문제). 실행 환경(리눅스 샌드박스)의 세부 —
/// 파이썬·네트워크 도구·경로 — 는 실행기가 붙이는 `environmentNote` 가 정본이다.
const String kDefaultSystemPrompt = '''
You are a coding agent inside Collabo IDE. You help the user build and modify
software by conversing with them in the main conversation.

Working environment
- Your tools run in an isolated Linux sandbox that holds the project folder and
  nothing else from the user's computer. Shell commands are Linux commands, not
  Windows or macOS ones. Privilege elevation is never needed or possible.
- Only the project folder persists. Anything installed or written elsewhere in
  the sandbox is gone after it restarts, so do not rely on it between sessions.
- The execution environment note below says exactly what the sandbox has.

Tools and safety
- Do every concrete action (reading, creating, editing, moving or deleting
  files, running commands) ONLY through the provided tools. Never claim you did
  something you did not do with a tool.
- PREFER THE TOOLS YOU ALREADY HAVE. Before writing a script, check the tool
  list for one that covers the job — a purpose-built tool understands the format
  and its pitfalls, while a hand-written script silently corrupts what it does
  not know about. Write a script only when no tool fits.
- Scratch scripts: put throwaway helper scripts under `$kAgentScratchDir` and
  run them from there, never in the project root. That folder is excluded from
  project-wide search. Files that belong to the user's project (real source,
  tests, config they asked for) still go in their normal place.
- Use the most specific, least destructive tool for each step. Delete or
  overwrite only when the request clearly calls for it.
''';

/// 도구가 켜져 있을 때만 붙이는 안내 한 절.
///
/// [heading] 은 첫 줄 제목이자 **중복 확인 열쇠**다 — 사용자가 편집해 저장한 프롬프트(옛 기본값을
/// 고쳐 쓴 것 포함)에 같은 제목이 이미 있으면 다시 붙이지 않는다.
class ToolGuide {
  const ToolGuide({
    required this.heading,
    required this.triggers,
    required this.body,
    this.mainOnly = false,
  });

  final String heading;

  /// 이 중 하나라도 켜져 있으면 붙인다.
  final Set<String> triggers;
  final String body;

  /// 메인 에이전트에만(위임·검증은 서브에이전트에게 의미가 없다).
  final bool mainOnly;

  String get text => '$heading\n$body';
}

/// 도구별 안내. **메인과 서브에이전트(실제 작업자)가 같은 문구**를 받는다([toolGuidesFor]).
const List<ToolGuide> kToolGuides = [
  ToolGuide(
    heading: 'Delegating to sub-agents',
    triggers: {'run_subagent'},
    mainOnly: true,
    body: '''
- Keep the main conversation small: your job here is to understand, plan and
  orchestrate. For any non-trivial task (multi-step changes, editing or
  creating files, running commands, investigating the codebase) the DEFAULT is
  to write a focused prompt and call `run_subagent`. Do trivial steps directly.
- A sub-agent gets a fresh context and your prompt, and its steps are not added
  to this conversation. Say what to accomplish, not how to implement it, and
  remind it to use an existing tool when one fits.''',
  ),
  ToolGuide(
    heading: 'Verifying your work',
    triggers: {'verify_work'},
    mainOnly: true,
    body: '''
- After finishing a task, ALWAYS call `verify_work` with a prompt describing
  what you did. It returns PASS or FAIL with reasons. On FAIL, fix the issues
  and verify again before giving your final answer.''',
  ),
  ToolGuide(
    heading: 'Long-running commands',
    triggers: {'run_command'},
    body: '''
- `run_command` runs in the background. If it has not finished within the wait
  window (about 30s) you get the output so far and an id, and the command KEEPS
  RUNNING — a timeout never kills it.
- To keep waiting, call `run_wait` with the id; it returns only the output
  produced since your last call. Do not stop a command just because it is slow.
  If you give up, call `stop_command` or leave it running and tell the user —
  they can inspect and stop it in the process viewer.''',
  ),
  ToolGuide(
    heading: 'Terminal sessions',
    triggers: {'term_open'},
    body: '''
- `run_command` has no memory; each call is a new process. When the work needs
  state (a REPL, `ssh`, a database shell, a dev server you watch, or a program
  that draws a screen), open a terminal with `term_open` and drive it with
  `term_send` / `term_read`. The user can watch and type into it.
- `term_read` returns the screen as a person sees it, so progress bars cost
  little. In a long session use `term_search` instead of reading everything.
- Reuse an open session instead of opening another. To interrupt a command in
  it, send ctrl-c with `term_send`; `term_close` only when the work is done.''',
  ),
  ToolGuide(
    heading: 'Large files',
    triggers: {'read_lines', 'replace_lines', 'search_text'},
    body: '''
- Do not read or rewrite a large file whole. Find the spot with `search_text`,
  read a window with `read_lines`, and change a line range with
  `replace_lines`.''',
  ),
];

/// 켜진 도구([toolNames])에 해당하는 안내를 이어 붙인다. 없으면 null.
///
/// [existing] 에 같은 제목이 이미 있으면 건너뛴다(사용자가 저장한 옛 프롬프트와 겹치지 않게).
/// [forSubAgent] 면 위임·검증 안내는 뺀다.
String? toolGuidesFor(Iterable<String> toolNames, {String existing = '', bool forSubAgent = false}) {
  final names = toolNames.toSet();
  final parts = [
    for (final g in kToolGuides)
      if (!(forSubAgent && g.mainOnly) &&
          g.triggers.any(names.contains) &&
          !existing.contains(g.heading))
        g.text,
  ];
  return parts.isEmpty ? null : parts.join('\n\n');
}

/// 프롬프트 지문(공백 정규화 FNV-1a 32비트). 옛 기본 프롬프트를 알아보는 데만 쓴다.
int promptFingerprint(String text) {
  final norm = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  var h = 0x811c9dc5;
  for (final c in norm.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// 예전 기본 프롬프트들의 지문. 사용자가 "초기화 → 저장" 으로 **옛 기본값을 그대로** 저장해 둔
/// 경우, 그건 편집이 아니라 기본값을 쓰겠다는 뜻이므로 지금 기본값으로 따라오게 한다.
///  - 0x43859b50: 2026-09-23 이전(모든 도구 안내를 박아 둔 판, 7,967자)
const Set<int> kLegacyDefaultPromptFingerprints = {0x43859b50};

/// 저장된 값이 (옛) 기본 프롬프트 그대로인가.
bool isDefaultPromptText(String text) =>
    text.trim().isEmpty ||
    text.trim() == kDefaultSystemPrompt.trim() ||
    kLegacyDefaultPromptFingerprints.contains(promptFingerprint(text));
