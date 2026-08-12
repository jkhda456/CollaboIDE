/// 뷰어 확장자/사용 여부 설정.
///
/// 뷰어의 **정체와 기본값은 웹(JS)에 있다** — 플러그인이 `collaboViewers.register`
/// 에서 id·label·extensions 를 선언한다. 네이티브는 그 위에 덮어쓸 값만
/// 갖는다(이 파일). 그래서 설정 화면은 두 조각을 합쳐 보여 준다:
///  - [ViewerInfo] : 웹이 보고한 현재 등록 상태(기본값)
///  - [ViewerRule] : 사용자가 덮어쓴 값(메인 DB 에 저장)
library;

/// 사용자가 뷰어 하나에 대해 덮어쓴 설정.
class ViewerRule {
  const ViewerRule({this.enabled = true, this.extensions});

  /// 끄면 자동 선택에서도, 보기 방식 드롭다운에서도 사라진다.
  /// (기본 뷰어를 안 쓰고 직접 만든 뷰어만 쓰고 싶은 경우.)
  final bool enabled;

  /// 이 뷰어가 담당할 확장자.
  /// - `null`  → 뷰어가 선언한 기본값을 그대로 쓴다
  /// - `[]`    → 확장자 연결 없음(드롭다운에서 직접 골라야 열린다)
  final List<String>? extensions;

  /// 저장할 필요가 없는 상태(전부 기본값)인지.
  bool get isDefault => enabled && extensions == null;

  ViewerRule copyWith({bool? enabled, List<String>? extensions, bool clearExtensions = false}) =>
      ViewerRule(
        enabled: enabled ?? this.enabled,
        extensions: clearExtensions ? null : (extensions ?? this.extensions),
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        if (extensions != null) 'extensions': extensions,
      };

  factory ViewerRule.fromJson(Map<String, Object?> json) => ViewerRule(
        enabled: (json['enabled'] as bool?) ?? true,
        extensions: json['extensions'] is List
            ? normalizeExtensions(
                (json['extensions'] as List).whereType<String>())
            : null,
      );

  /// 사용자가 입력한 문자열을 확장자 목록으로 바꾼다.
  ///
  /// 쉼표·공백·세미콜론으로 나누고, 앞의 `*` 나 `.` 유무를 흡수해 `.md` 형태로
  /// 맞춘다(`*.MD`, `md`, `.md` → `.md`). 중복은 첫 등장만 남긴다.
  static List<String> parseExtensions(String raw) =>
      normalizeExtensions(raw.split(RegExp(r'[\s,;]+')));

  static List<String> normalizeExtensions(Iterable<String> parts) {
    final out = <String>[];
    for (final part in parts) {
      var e = part.trim().toLowerCase();
      if (e.startsWith('*')) e = e.substring(1);
      if (e.isEmpty || e == '.') continue;
      if (!e.startsWith('.')) e = '.$e';
      if (!out.contains(e)) out.add(e);
    }
    return out;
  }

  /// 입력창에 보여 줄 형태(`.md, .markdown`).
  static String formatExtensions(Iterable<String> extensions) =>
      extensions.join(', ');
}

/// 웹이 보고한 등록된 뷰어 하나(설정 화면에 줄을 그리기 위한 정보).
/// **영구 저장하지 않는다** — 웹뷰가 살아 있는 동안의 현재 상태다.
class ViewerInfo {
  const ViewerInfo({
    required this.id,
    required this.label,
    required this.dataMode,
    required this.defaultExtensions,
    this.user = false,
  });

  final String id;
  final String label;

  /// 네이티브에 요청하는 읽기 형태('text' | 'hex').
  final String dataMode;

  /// 플러그인이 선언한 확장자(사용자 override 가 없을 때 쓰이는 값).
  final List<String> defaultExtensions;

  /// 사용자가 설정에서 추가한 파일에서 온 뷰어인지(번들 뷰어면 false).
  final bool user;

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'dataMode': dataMode,
        'extensions': defaultExtensions,
        'user': user,
      };

  factory ViewerInfo.fromJson(Map<String, Object?> json) => ViewerInfo(
        id: (json['id'] as String?) ?? '',
        label: (json['label'] as String?) ?? '',
        dataMode: json['dataMode'] == 'hex' ? 'hex' : 'text',
        defaultExtensions: ViewerRule.normalizeExtensions(
            ((json['extensions'] as List?) ?? const []).whereType<String>()),
        user: json['user'] == true,
      );
}

/// 뷰어 우선순위 정렬. 규칙은 웹(`index.html` 의 `rankOf`)과 같아야 한다:
///
/// 1. 사용자가 정한 순서([order])에 있으면 그 순서대로 (앞이 이김)
/// 2. 없으면 그 **뒤**에, 등록된 순서 그대로(안정 정렬)
///
/// 같은 확장자를 여러 뷰어가 담당할 수 있으므로(예: `.md` → Markdown / Markdown
/// 편집기) 누가 먼저인지가 필요하고, 그 결정권은 전부 사용자에게 있다.
List<ViewerInfo> sortViewersByOrder(List<ViewerInfo> viewers, List<String> order) {
  final indexed = [
    for (var i = 0; i < viewers.length; i++) (viewer: viewers[i], at: i),
  ];
  int rank(ViewerInfo v) {
    final i = order.indexOf(v.id);
    // 목록에 없는 뷰어(새로 등록됨)는 정해진 것들 뒤로. 그들끼리는 등록 순서 유지.
    return i >= 0 ? i : order.length;
  }

  indexed.sort((a, b) {
    final r = rank(a.viewer).compareTo(rank(b.viewer));
    return r != 0 ? r : a.at.compareTo(b.at);
  });
  return [for (final e in indexed) e.viewer];
}
