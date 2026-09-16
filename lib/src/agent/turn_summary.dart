/// 예전(인라인 마커) 방식으로 저장된 본문에서 `<turn_summary>` 흔적을 걷어낸다.
///
/// 턴 요약은 이제 응답에 섞지 않고 별도 호출로 만들지만, **그 이전 대화 기록에는
/// 마커가 그대로 남아 있다**(본문으로 저장됐다). 표시·컨텍스트 재사용 시 이걸로
/// 정리한다. 새 대화에는 애초에 나타나지 않는다.
///
/// - 짝이 맞는 블록은 통째로 제거한다.
/// - 짝이 없는 태그는 **태그만** 지우고 내용은 남긴다 — 닫히지 않은 경우 그 뒤가
///   실제 답변일 수 있어, 통째로 지우면 답변을 잃는다.
///
/// > 📌 이 함수는 원래 `web_bridge.dart` 에 있었다. 루프를 `agent_loop.dart` 로
/// > 떼어내면서 양쪽(기록 표시, 컨텍스트 구성)이 다 쓰게 되어 따로 뺐다. 기존
/// > import 경로(`webview/web_bridge.dart`)도 계속 쓸 수 있도록 브리지가 re-export 한다.
String stripTurnSummary(String raw) {
  // 대부분의 메시지엔 마커가 없다 — 대소문자 무시로 한 번만 확인하고 빠져나간다.
  if (!_turnSummaryProbe.hasMatch(raw)) return raw;
  return raw
      .replaceAll(_turnSummaryBlock, '')
      .replaceAll(_turnSummaryStray, '')
      .trimLeft();
}

final RegExp _turnSummaryProbe = RegExp('turn_summary', caseSensitive: false);
final RegExp _turnSummaryBlock =
    RegExp(r'<turn_summary>[\s\S]*?</turn_summary>\s*', caseSensitive: false);
final RegExp _turnSummaryStray =
    RegExp(r'</?turn_summary>\s*', caseSensitive: false);
