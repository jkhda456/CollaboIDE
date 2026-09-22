import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 네이티브가 대화창에 보내는 문구(상태·알림·오류)의 **언어팩 키가 양쪽 언어팩에 다 있는지.**
///
/// 네이티브 루프는 화면 언어를 모르므로 영어 문구에 키를 곁들여 보내고 웹이 바꾼다
/// (`index.html` 의 `TM`). 키가 언어팩에 없으면 조용히 영어로 나온다 — 그게 바로
/// 고친 버그("새 시작점 알림이 영어로만 나온다")라서 여기서 막는다.
void main() {
  Map<String, Object?> pack(String lang) =>
      jsonDecode(File('assets/web/lang/$lang.json').readAsStringSync()) as Map<String, Object?>;

  final sources = [
    'lib/src/agent/agent_loop.dart',
    'lib/src/webview/web_bridge.dart',
  ];
  // `key: 'statusTool'` · `'key': 'noticeImageTooLarge'` · `key: verify ? 'a' : 'b'`
  final keyRe = RegExp(r"""\b(?:status|notice|error)[A-Z]\w*""");

  Set<String> usedKeys() {
    final keys = <String>{};
    for (final f in sources) {
      final src = File(f).readAsStringSync();
      for (final line in src.split('\n')) {
        if (!line.contains('key')) continue;
        for (final m in RegExp(r"'([a-z]\w+)'").allMatches(line)) {
          final k = m.group(1)!;
          if (keyRe.hasMatch(k) && keyRe.firstMatch(k)!.group(0) == k) keys.add(k);
        }
      }
    }
    return keys;
  }

  test('보내는 키는 ko/en 언어팩에 모두 있다', () {
    final keys = usedKeys();
    expect(keys, containsAll(['noticePlanCleared', 'noticeNoPlan', 'statusTool']),
        reason: '키를 찾는 식이 망가지면 아래 검사가 헛돌기 때문에 먼저 확인한다');
    for (final lang in ['ko', 'en']) {
      final p = pack(lang);
      final missing = keys.where((k) => !p.containsKey(k)).toList();
      expect(missing, isEmpty, reason: '$lang.json 에 없는 키');
    }
  });

  test('자리 표시({이름})는 두 언어가 같다', () {
    final ko = pack('ko'), en = pack('en');
    Set<String> slots(Object? v) =>
        {for (final m in RegExp(r'\{(\w+)\}').allMatches('$v')) m.group(1)!};
    for (final k in usedKeys()) {
      expect(slots(ko[k]), slots(en[k]), reason: k);
    }
  });
}
