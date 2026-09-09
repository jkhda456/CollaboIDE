/// 채팅 메시지 배열의 **모양**에 대한 규칙.
///
/// OpenAI 호환 API 는 role 배치에 관대해서 system 이 여러 개여도, 배열이 system 으로
/// 끝나도 받아 준다. 반면 **로컬 서버(llama.cpp 등)는 GGUF 안의 Jinja 템플릿을 그대로
/// 렌더링**하므로 템플릿이 정한 규칙이 곧 에러가 된다:
///
/// - Mistral 계열: system 은 맨 앞 하나만. 그 밖이면
///   `Conversation roles must alternate user/assistant/…` 예외.
/// - 대부분의 템플릿: **마지막이 user 여야** 생성 프롬프트가 붙는다. 배열이 system 으로
///   끝나면 아무 생성도 시작되지 않거나 예외가 난다.
///
/// 그래서 이 앱은 **더 엄격한 쪽에 맞춰서** 만든다 — 양쪽 다 통과하는 모양이다.
library;

/// 여러 조각의 지시를 **하나의 system 메시지**로 합친다(빈 조각은 버린다).
///
/// system 을 늘리고 싶으면 여기에 블록을 더할 것 — 별도 메시지로 추가하지 말 것.
List<Map<String, Object?>> systemHead(List<String?> blocks) {
  final parts = <String>[
    for (final b in blocks)
      if (b != null && b.trim().isNotEmpty) b.trim(),
  ];
  if (parts.isEmpty) return const [];
  return [
    {'role': 'system', 'content': parts.join('\n\n')}
  ];
}

/// 보내기 전 모양 검사. 문제가 없으면 null, 있으면 사람이 읽을 수 있는 이유.
///
/// 개발 중에는 `assert` 로 잡고(릴리스에서는 제거된다), 테스트가 이 규칙을 고정한다.
String? chatShapeProblem(List<Map<String, Object?>> messages) {
  if (messages.isEmpty) return 'no messages';
  var seenNonSystem = false;
  var systems = 0;
  var users = 0;
  for (final m in messages) {
    final role = m['role'];
    if (role == 'system') {
      systems++;
      if (seenNonSystem) return 'system message after the conversation started';
    } else {
      seenNonSystem = true;
      if (role == 'user') users++;
    }
  }
  if (systems > 1) return 'more than one system message ($systems)';
  if (users == 0) return 'no user message';
  if (messages.last['role'] == 'system') return 'ends with a system message';
  return null;
}
