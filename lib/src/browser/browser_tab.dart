/// 웹 검색 탭 하나의 **상태 모델**.
///
/// 실제 페이지를 들고 있는 것은 [PlatformBrowserView] 이고, 이 클래스는 화면
/// (탭 스트립)과 에이전트(`web_tabs`)가 같이 보는 **표시용 스냅샷**이다.
/// 그래서 웹뷰 인스턴스를 참조하지 않는다 — 상태만 담는다.
library;

/// 탭을 누가 열었나. **권한이 아니라 표시용 꼬리표다.**
///
/// 사용자 탭과 에이전트 탭을 나누지 않기로 했으므로(둘 다 같은 목록·같은 쿠키),
/// 에이전트는 사용자가 연 탭도 읽고 조작할 수 있다. 이 값은 탭 스트립의 점 하나와
/// `web_tabs` 결과의 `opened_by` 로만 쓰인다.
enum TabOwner { user, agent }

/// 탭의 로드 상태.
enum TabLoad {
  /// 아직 아무것도 안 띄운 빈 탭.
  blank,

  /// 로드 중.
  loading,

  /// 로드 완료.
  ready,

  /// 로드 실패(네트워크·차단 등). [BrowserTab.error] 에 이유.
  failed,
}

/// 탭 하나의 상태 스냅샷. 불변이며 [copyWith] 로 갈아 끼운다.
class BrowserTab {
  const BrowserTab({
    required this.id,
    this.name = '',
    this.title = '',
    this.url = '',
    this.load = TabLoad.blank,
    this.owner = TabOwner.user,
    this.canGoBack = false,
    this.canGoForward = false,
    this.error = '',
  });

  /// 앱 실행 동안 안정적인 짧은 id (`t1`, `t2` …).
  ///
  /// **에이전트가 인자로 넘기는 값이므로 재사용하지 않는다** — 탭을 닫아도 그 번호는
  /// 다시 나오지 않는다. 닫힌 탭 번호로 부르면 "없는 탭" 오류가 나는 편이,
  /// 엉뚱한 탭을 조작하는 것보다 낫다.
  final String id;

  /// 에이전트가 붙인 이름. 비어 있으면 화면은 [title] 을 쓴다.
  ///
  /// 에이전트는 탭 하나를 재사용하되 무엇에 쓰는 탭인지 이름으로 관리한다
  /// (예: `flutter 문서`). 사용자가 연 탭은 이름이 없다.
  final String name;

  /// 페이지가 보고한 제목.
  final String title;

  /// 현재 URL.
  final String url;

  final TabLoad load;
  final TabOwner owner;
  final bool canGoBack;
  final bool canGoForward;

  /// 마지막 실패 이유([load] 가 [TabLoad.failed] 일 때만 의미 있다).
  final String error;

  bool get isLoading => load == TabLoad.loading;

  /// 탭 스트립과 에이전트에게 보여 줄 한 줄. 이름 → 제목 → URL → 빈 탭 순.
  String get label {
    if (name.isNotEmpty) return name;
    if (title.isNotEmpty) return title;
    if (url.isNotEmpty) return url;
    return '';
  }

  BrowserTab copyWith({
    String? name,
    String? title,
    String? url,
    TabLoad? load,
    TabOwner? owner,
    bool? canGoBack,
    bool? canGoForward,
    String? error,
  }) {
    return BrowserTab(
      id: id,
      name: name ?? this.name,
      title: title ?? this.title,
      url: url ?? this.url,
      load: load ?? this.load,
      owner: owner ?? this.owner,
      canGoBack: canGoBack ?? this.canGoBack,
      canGoForward: canGoForward ?? this.canGoForward,
      error: error ?? this.error,
    );
  }

  /// 에이전트(`web_tabs`)와 파일 통로가 주고받는 모양.
  ///
  /// 키는 **파이썬 쪽 계약**이므로 바꾸면 `collabo_web.py` 도 같이 고쳐야 한다.
  Map<String, Object?> toJson() => {
        'tab': id,
        'name': name,
        'title': title,
        'url': url,
        'status': load.name,
        'opened_by': owner.name,
        'can_go_back': canGoBack,
        'can_go_forward': canGoForward,
        if (error.isNotEmpty) 'error': error,
      };
}
