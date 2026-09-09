/// 파일/폴더 **이름** 유효성 검사.
///
/// 프로젝트 폴더명(새 프로젝트 다이얼로그)과 트리에서 만드는 파일·폴더 이름
/// (우클릭 → 새 파일 / 새 폴더 / 이름 변경)이 **같은 규칙**을 쓴다.
/// 3개 OS 어디서든 만들 수 있는 이름만 통과시킨다 — 한쪽 OS 에서만 되는 이름을
/// 허용하면 프로젝트를 옮겼을 때 열리지 않는 파일이 생긴다.
///
/// 웹(index.html)의 `validateEntryName()` 이 같은 규칙을 **한 벌 더** 갖고 있다.
/// 거기는 모달에서 즉시 번역된 메시지를 보여주기 위한 것이고, 최종 판정은
/// 항상 네이티브(이 파일)가 한다. 규칙을 고치면 양쪽을 같이 고칠 것.
library;

/// 이름 유효성 오류 종류(다국어 메시지 매핑용).
enum ProjectNameError { empty, invalidChars, invalidName, trailingDot, reserved }

/// 파일/폴더 이름 유효성 검사. 문제가 있으면 오류 종류, 없으면 null.
///
/// Windows/Linux/macOS 에서 모두 이름으로 쓸 수 없는 경우를 모두 막는다.
/// 경로 구분자(`/` `\`)를 막으므로 **이름 하나**만 받는다(경로를 넣을 수 없다).
ProjectNameError? validateProjectName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return ProjectNameError.empty;
  // 3개 OS 공통 금지: < > : " / \ | ? * 및 제어문자(0x00-0x1F).
  if (RegExp(r'[<>:"/\\|?*\x00-\x1F]').hasMatch(name)) {
    return ProjectNameError.invalidChars;
  }
  if (name == '.' || name == '..') return ProjectNameError.invalidName;
  // Windows: 마침표/공백으로 끝날 수 없음.
  if (name.endsWith('.') || name.endsWith(' ')) {
    return ProjectNameError.trailingDot;
  }
  // Windows 예약어(확장자 유무 무관).
  const reserved = {
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };
  if (reserved.contains(name.split('.').first.toUpperCase())) {
    return ProjectNameError.reserved;
  }
  return null;
}
