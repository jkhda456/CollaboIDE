/// 목표·계획·알아낸 것을 담는 **파일 하나** (`<project>/.collabo/PLAYBOOK.md`).
///
/// 요점은 **기억의 단위를 대화가 아니라 파일로 옮기는 것**이다. 이 앱의 대화 컨텍스트는
/// 오래 살지 못한다 — 어시스턴트 본문은 다음 턴에 **턴 요약으로 대체**되고, 시작점
/// (체크포인트)을 만들면 그 앞은 통째로 사라지며, 사용자가 위를 고치면 아래가 잘린다.
/// 계획이 답변 본문에만 있으면 계획도 같이 사라진다. 파일에 있으면 남는다.
///
/// 설계 출처는 `avo-arc-agi` 조사의 패턴 카탈로그(`harness.md` 7장)다 —
/// **영속 메모리 파일**(Retrodict `playbook.md`)과 **검증됨 vs 가정임 표기**
/// (Retrodict working model). `expcode` 의 `app/services/harness.py` 가 같은 패턴을
/// 파이썬으로 먼저 옮겼고, 이 파일은 그 구조를 Dart 로 다시 쓴 것이다.
///
/// 섹션 제목과 마커는 **영어로 고정**한다. 모델이 읽고 다시 쓰는 규격이라 UI 언어를
/// 따라가면 안 된다(한국어로 쓰면 영어 프롬프트와 어긋난다).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 프로젝트 루트 기준 PLAYBOOK 경로. 프롬프트에서도 이 상수를 인용한다.
const String kPlaybookPath = '.collabo/PLAYBOOK.md';

/// 계획 항목의 상태. **열린 항목(TODO/DOING)이 남았는지**가 종료 차단의 근거가 된다.
///
/// `BLOCKED` 는 "사용자를 기다리는 중" 이다. 열린 항목이 아니므로 종료 차단에 걸리지
/// 않는다 — 모델이 사용자에게 되묻고 턴을 끝내는 **유일하고 명시적인** 길이다.
/// (예전에는 답변 문장을 정규식으로 보고 질문이면 면제했는데, 모델이 어떻게 끝맺을지
/// 규정할 수 없어 잘못된 설계였다. 도구 호출은 모호하지 않다.)
const List<String> kStepMarkers = ['TODO', 'DOING', 'BLOCKED', 'DONE', 'DROP'];

/// 지식에 붙이는 신뢰 수준. 가정이 사실로 슬쩍 승격되는 것을 막지 못하면
/// 그 뒤의 모든 추론이 오염된다.
const List<String> kKnowledgeMarkers = ['ASSUMED', 'VERIFIED', 'REFUTED'];

const String kSecGoal = 'GOAL';
const String kSecPlan = 'PLAN';
const String kSecWorkingModel = 'WORKING MODEL';
const String kSecRuledOut = 'RULED OUT';
const String kSecOpenQuestions = 'OPEN QUESTIONS';

const List<String> kPlaybookSections = [
  kSecGoal,
  kSecPlan,
  kSecWorkingModel,
  kSecRuledOut,
  kSecOpenQuestions,
];

/// `note_write` 의 section 인자로 받는 이름 → 실제 섹션.
/// 모델이 `working_model`·`WORKING MODEL`·`ruled out` 중 무엇으로 불러도 받는다.
const Map<String, String> kNoteSectionAliases = {
  'working_model': kSecWorkingModel,
  'workingmodel': kSecWorkingModel,
  'working model': kSecWorkingModel,
  'ruled_out': kSecRuledOut,
  'ruledout': kSecRuledOut,
  'ruled out': kSecRuledOut,
  'open_questions': kSecOpenQuestions,
  'openquestions': kSecOpenQuestions,
  'open questions': kSecOpenQuestions,
};

final RegExp _itemRe = RegExp(r'^\s*-\s*\[([A-Z_ ]+)\]\s*(.+?)\s*$');

/// 그 섹션에서 허용되는 마커. **첫 값이 가장 약한 값**이다(강등 대상).
List<String> markersFor(String section) =>
    section == kSecPlan ? kStepMarkers : kKnowledgeMarkers;

/// PLAYBOOK 파일을 쓰지 못했을 때. **조용히 넘어가면 안 되는 실패**다 —
/// 계획을 적었다고 믿은 채 계획 없이 진행하게 된다.
class PlaybookWriteException implements Exception {
  const PlaybookWriteException(this.path, this.reason);
  final String path;
  final String reason;

  @override
  String toString() => 'Could not write the plan file ($path): $reason';
}

class PlaybookItem {
  PlaybookItem(this.text, this.marker);
  String text;
  String marker;

  String render() => '- [$marker] $text';
  Map<String, Object?> toJson() => {'text': text, 'marker': marker};
}

/// PLAYBOOK 파일 하나. 읽기·쓰기 실패는 **삼킨다** — 메모리를 못 써도 대화는 계속된다.
class Playbook {
  Playbook(this.file, {this.maxChars = 6000});

  /// 프로젝트 경로에서 만든다.
  factory Playbook.forProject(String projectPath) =>
      Playbook(File(p.join(projectPath, '.collabo', 'PLAYBOOK.md')));

  final File file;

  /// 이 길이를 넘으면 [curate] 가 가정부터 접는다.
  final int maxChars;

  final Map<String, List<PlaybookItem>> _data = {
    for (final s in kPlaybookSections) s: <PlaybookItem>[],
  };

  bool _exists = false;

  /// 디스크에 파일이 실제로 있는가([load] 시점 기준, [save] 성공 시 true).
  ///
  /// **비어 있음([isEmpty])과 다르다.** 계획 카드는 내용이 있을 때만 뜨지만,
  /// 트리의 "계획 파일 열기" 버튼은 **파일이 있으면** 떠야 한다 — `.collabo` 안에만
  /// 생기다 보니 사용자가 존재 자체를 모르고 지나치기 때문이다.
  bool get fileExists => _exists;

  /// 파일의 절대 경로(웹에 넘겨 뷰어로 열게 한다).
  String get path => file.path;

  /// 파일에서 읽는다. 파일이 없으면 빈 상태로 둔다(오류가 아니다).
  Future<void> load() async {
    for (final s in kPlaybookSections) {
      _data[s] = <PlaybookItem>[];
    }
    _exists = false;
    String text;
    try {
      if (!await file.exists()) return;
      _exists = true;
      text = await file.readAsString();
    } catch (_) {
      return;
    }
    String? current;
    // CRLF/CR 도 같이 가른다 — 사용자가 다른 편집기로 고쳤을 수 있다.
    for (final line in text.split(RegExp(r'\r\n|\r|\n'))) {
      if (line.startsWith('## ')) {
        current = line.substring(3).trim();
        _data.putIfAbsent(current, () => <PlaybookItem>[]);
        continue;
      }
      if (current == null) continue;
      final allowed = markersFor(current);
      final m = _itemRe.firstMatch(line);
      if (m != null) {
        final marker = m.group(1)!.trim();
        // 규격 밖 마커는 **가장 약한 값으로 강등**한다. 모르는 표시를 그대로 두면
        // 그 항목이 확인된 것인지 아닌지 판단할 수 없어진다(사용자가 손으로
        // 고쳤거나 모델이 지어낸 마커를 쓴 경우).
        _data[current]!.add(PlaybookItem(
            m.group(2)!, allowed.contains(marker) ? marker : allowed.first));
      } else if (line.trimLeft().startsWith('- ')) {
        // 마커 없는 줄도 버리지 않는다 — 사람이 손으로 적은 항목이다.
        _data[current]!
            .add(PlaybookItem(line.trim().substring(2).trim(), allowed.first));
      }
    }
  }

  Future<void> save() async {
    final out = <String>[
      '# PLAYBOOK',
      '',
      '<!-- Collabo IDE 가 관리하는 파일입니다. 목표와 계획, 알아낸 것이 여기 남아',
      '     대화가 요약되거나 잘려도 사라지지 않습니다. 직접 고치셔도 됩니다.',
      '     규격에 없는 마커는 다음에 읽을 때 가장 약한 값으로 내려갑니다. -->',
      '',
    ];
    for (final section in kPlaybookSections) {
      out.add('## $section');
      out.addAll((_data[section] ?? const []).map((i) => i.render()));
      out.add('');
    }
    // **쓰기 실패를 삼키지 않는다.** 삼키면 도구가 `ok: true` 를 돌려주고 모델은
    // 계획을 적었다고 믿는데 파일에는 아무것도 없다 — 아무도 모르는 채로 계획이
    // 사라진다. 여기서 던지면 `_runPlanTool` 이 도구 오류로 바꿔 모델과 화면 양쪽에
    // 이유가 보인다. (읽기는 반대로 관대하다 — 없는 파일은 오류가 아니다.)
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(out.join('\n'));
      _exists = true;
    } on FileSystemException catch (e) {
      throw PlaybookWriteException(file.path, e.osError?.message ?? e.message);
    }
  }

  // ------------------------------------------------------------------ 조작

  /// 보관본이 쌓이는 폴더(`.collabo/playbook-archive/`).
  static const String archiveDirName = 'playbook-archive';

  /// 계획을 **비운다** — 대화 시작점을 만들 때, 또는 "계획만 초기화".
  ///
  /// 파일이 있으면 지우지 않고 `.collabo/playbook-archive/PLAYBOOK-<시각>.md` 로
  /// **옮겨 보관**한다. 초기화는 되돌리는 버튼이 없다(시작점은 원복할 수 있어도 계획은
  /// 그렇지 않다) — 잘못 눌렀을 때 손으로라도 되살릴 길을 남긴다.
  /// 파일이 없어지므로 [fileExists] 는 false 가 된다(트리의 "계획 파일 열기" 도 사라진다).
  ///
  /// 돌려주는 값: 보관한 경로. 파일이 없었으면 null. 옮기지 못하면
  /// [PlaybookWriteException] — 비웠다고 믿었는데 옛 계획이 남아 있으면 안 된다.
  Future<String?> reset({DateTime? now}) async {
    for (final s in kPlaybookSections) {
      _data[s] = <PlaybookItem>[];
    }
    _data.removeWhere((k, _) => !kPlaybookSections.contains(k));
    if (!await file.exists()) {
      _exists = false;
      return null;
    }
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    try {
      final dir = Directory(p.join(file.parent.path, archiveDirName));
      await dir.create(recursive: true);
      var dest = File(p.join(dir.path, 'PLAYBOOK-$stamp.md'));
      for (var n = 2; await dest.exists(); n++) {
        dest = File(p.join(dir.path, 'PLAYBOOK-$stamp-$n.md'));
      }
      try {
        await file.rename(dest.path);
      } on FileSystemException {
        // 다른 볼륨·잠금 등으로 rename 이 안 되면 복사 후 지운다.
        await file.copy(dest.path);
        await file.delete();
      }
      _exists = false;
      return dest.path;
    } on FileSystemException catch (e) {
      throw PlaybookWriteException(file.path, e.osError?.message ?? e.message);
    }
  }

  Future<void> setGoal(String goal) async {
    final g = goal.trim();
    if (g.isEmpty) return;
    _data[kSecGoal] = [PlaybookItem(g, 'ASSUMED')];
    await save();
  }

  /// 계획을 통째로 갈아 끼운다. 기존 항목의 상태는 남지 않는다 —
  /// "다른 방향으로 다시 세운다" 가 이 함수를 부르는 이유이기 때문이다.
  Future<void> setPlan(List<String> steps) async {
    _data[kSecPlan] = [
      for (final s in steps)
        if (s.trim().isNotEmpty) PlaybookItem(s.trim(), 'TODO'),
    ];
    await save();
  }

  /// 계획 항목 하나의 상태를 바꾼다.
  /// [ref] 는 **번호(1부터)** 또는 항목 텍스트의 일부.
  Future<PlaybookItem?> updateStep(String ref, String marker,
      {String note = ''}) async {
    final steps = _data[kSecPlan] ?? const <PlaybookItem>[];
    if (steps.isEmpty) return null;
    var mk = marker.trim().toUpperCase();
    if (!kStepMarkers.contains(mk)) mk = 'DONE';

    final r = ref.trim();
    PlaybookItem? target;
    final n = int.tryParse(r);
    if (n != null && n >= 1 && n <= steps.length) target = steps[n - 1];
    if (target == null && r.isNotEmpty) {
      final lowered = r.toLowerCase();
      for (final s in steps) {
        if (s.text.toLowerCase().contains(lowered)) {
          target = s;
          break;
        }
      }
    }
    if (target == null) return null;

    target.marker = mk;
    if (note.trim().isNotEmpty) target.text = '${target.text} — ${note.trim()}';
    await save();
    return target;
  }

  /// 메모 한 줄. 같은 문장이 이미 있으면 **마커만 갱신**한다(같은 말을 쌓지 않는다).
  Future<PlaybookItem?> note(String section, String text,
      {String marker = ''}) async {
    final key = section.trim().toLowerCase();
    var sec = kNoteSectionAliases[key] ?? section.trim().toUpperCase();
    if (!_data.containsKey(sec) || sec == kSecGoal || sec == kSecPlan) {
      // 목표·계획은 전용 도구로만 바꾼다. 그 밖의 이름은 WORKING MODEL 로 모은다.
      sec = kSecWorkingModel;
    }
    final t = text.trim();
    if (t.isEmpty) return null;

    final allowed = markersFor(sec);
    var mk = marker.trim().toUpperCase();
    if (!allowed.contains(mk)) {
      // RULED OUT 에 들어오는 것은 기본이 REFUTED 다 — 배제했다는 뜻이니까.
      mk = sec == kSecRuledOut ? 'REFUTED' : allowed.first;
    }

    for (final existing in _data[sec]!) {
      if (existing.text == t) {
        existing.marker = mk;
        await save();
        return existing;
      }
    }
    final item = PlaybookItem(t, mk);
    _data[sec]!.add(item);
    curate();
    await save();
    return item;
  }

  // ------------------------------------------------------------------ 조회

  /// 아직 **끝내야 할** 단계. `BLOCKED`(사용자 대기)와 `DONE`/`DROP` 은 빠진다.
  /// 종료 차단이 보는 값이다.
  List<String> get openSteps => [
        for (final i in _data[kSecPlan] ?? const <PlaybookItem>[])
          if (i.marker == 'TODO' || i.marker == 'DOING') i.text,
      ];

  /// 사용자를 기다리는 단계. 계획 카드가 따로 표시한다.
  List<String> get blockedSteps => [
        for (final i in _data[kSecPlan] ?? const <PlaybookItem>[])
          if (i.marker == 'BLOCKED') i.text,
      ];

  bool get hasPlan => (_data[kSecPlan] ?? const []).isNotEmpty;

  String get goalText {
    final items = _data[kSecGoal] ?? const <PlaybookItem>[];
    return items.isEmpty ? '' : items.first.text;
  }

  bool get isEmpty =>
      kPlaybookSections.every((s) => (_data[s] ?? const []).isEmpty);

  List<PlaybookItem> section(String name) =>
      List.unmodifiable(_data[name] ?? const <PlaybookItem>[]);

  /// 웹(계획 카드)으로 보낼 형태.
  Map<String, Object?> toJson() => {
        'goal': goalText,
        'steps': [
          for (final i in _data[kSecPlan] ?? const <PlaybookItem>[]) i.toJson(),
        ],
        'notes': {
          'working_model': [
            for (final i in _data[kSecWorkingModel] ?? const <PlaybookItem>[])
              i.toJson(),
          ],
          'ruled_out': [
            for (final i in _data[kSecRuledOut] ?? const <PlaybookItem>[])
              i.toJson(),
          ],
          'open_questions': [
            for (final i in _data[kSecOpenQuestions] ?? const <PlaybookItem>[])
              i.toJson(),
          ],
        },
      };

  String render() {
    final blocks = <String>[];
    for (final section in kPlaybookSections) {
      final items = _data[section] ?? const <PlaybookItem>[];
      if (items.isEmpty) continue;
      blocks.add('## $section\n${items.map((i) => i.render()).join('\n')}');
    }
    return blocks.join('\n\n');
  }

  /// 매 턴 컨텍스트에 고정할 요약. 비어 있으면 null(아무것도 주입하지 않는다).
  String? digest({int limit = 1800}) {
    final text = render();
    if (text.isEmpty) return null;
    if (text.length <= limit) return text;
    return '${text.substring(0, limit)}\n…(전문은 $kPlaybookPath)';
  }

  /// 넘치면 **VERIFIED 는 남기고 가정부터 접는다**.
  ///
  /// 저널처럼 계속 쌓으면 결국 컨텍스트를 다시 잡아먹는다. 쌓지 말고 큐레이션된
  /// 브리핑으로 유지하는 것이 Retrodict playbook 의 요점이었다.
  /// 목표·계획은 건드리지 않는다(그건 짧고, 짧아야 한다).
  bool curate() {
    if (render().length <= maxChars) return false;
    for (final section in [kSecWorkingModel, kSecRuledOut, kSecOpenQuestions]) {
      final items = _data[section] ?? const <PlaybookItem>[];
      if (items.length <= 6) continue;
      final verified = items.where((i) => i.marker == 'VERIFIED').toList();
      final rest = items.where((i) => i.marker != 'VERIFIED').toList();
      _data[section] = [
        ...verified.length > 20 ? verified.sublist(verified.length - 20) : verified,
        ...rest.length > 6 ? rest.sublist(rest.length - 6) : rest,
      ];
    }
    return true;
  }
}
