# Collabo IDE

웹뷰(WebView) 기반의 크로스플랫폼 코드 개발 도구입니다. Flutter로 데스크톱 셸을 구성하고,
화면의 대부분(대화·트리·뷰어)은 임베디드 웹뷰 위에서 동작합니다. LLM과 대화하며 코딩하고,
실제 작업은 안전한 Python 도구 계층을 통해 수행됩니다.

## 아키텍처

```
┌──────┬──────────────────────────────────────────┐
│ 좌측  │            단일 WebView (Bootstrap)        │
│ 메뉴  │   가운데 대화   │  우측 트리뷰 + 파일 뷰어     │
│(네이티브)│              │                           │
└──────┴──────────────────────────────────────────┘
 Flutter │◄──────── 웹(HTML/CSS/JS) ──────────────►│
```

- **좌측 메뉴만 네이티브 Flutter** + 창 셸. 나머지(가운데 대화 + 우측 트리/뷰어)는 단일 웹뷰.
- 웹뷰 리소스(Bootstrap 포함)는 모두 앱에 **임베딩**되어 오프라인 동작.
- 웹은 OS 파일시스템에 직접 접근하지 않으며, 네이티브가 읽어 **브리지(JSON 메시지)** 로 전달.

## 주요 기능

### 좌측 메뉴 (네이티브)
- **새 프로젝트**: 경로 선택 + 이름 입력 → 폴더 생성 후 시작 (3개 OS 공통 금지 문자/예약어 차단).
- **프로젝트 열기**: 폴더 선택 → 작업 경로 지정.
- **최근 프로젝트**: 폴더명 첫 글자 모노그램(경로 기반 색). 최대 5개, **폴더 마지막 변경시간** 순 정렬.
- **진행 상태 아이콘**: 실행 중 서브프로세스 수를 힌트로 표시.
- **설정(⚙)**: 탭형 설정 창 — 모델 / 프롬프트 / 도구 / 모양.

### 대화 (웹)
- OpenAI 호환 API로 **스트리밍** 대화. 헤더에 모델명 + 누적 컨텍스트 토큰.
- 응답 중 토큰 수·속도·상태·reasoning 실시간 표시. 오류 시 재시도, 사용자 메시지 인플레이스 수정.
- 떠 있는 라운드 입력창(+첨부 / 자동 높이), 맨 아래로 가기 버튼, 입력창 높이만큼 여백 확보.

### 우측 트리 + 파일 뷰어 (웹)
- 네이티브가 파일시스템을 읽어 전달, **실시간 변경 감시**(상태 보존 — 보고 있는데 접히지 않음).
- 우클릭 메뉴(전체 경로 복사), 폭/높이 조절, 트리 토글, 파일/내용 검색(아이콘 토글).
- 파일 뷰어: **text / hex / markdown**(드롭다운), 전체화면, 대용량 파일 가드.

### 에이전트 & 도구 (안전 계층)
- 실제 작업(파일 읽기/생성/저장/수정, 명령 실행, 권한 상승 등)은 **Python 도구 모듈**이 수행하고,
  LLM은 **function calling** 으로만 지시합니다. 직접 파일을 고치지 않게 하는 **안전 가드**입니다.
- 파일 도구는 **항상 프로젝트 경로(workspace) 안으로 제약**됩니다(심링크 해석·형제 prefix·상위 탈출
  차단, 워크스페이스 미설정 시 fail-safe 차단).
- 기본 모듈은 고정, 설정에서 **일반 Python 스크립트(`--help` 자동 파싱)** 또는 **MCP 서버**를 추가해 확장.
- 실행 전략은 **시스템 프롬프트**(영어, 사용자 편집 가능)로 정리되어 대화 시작 시 주입됩니다.

### 실행 모델 (서브프로세스)
- 작업은 선택한 **Python 인터프리터**로 실행되고 출력이 대화창에 누적됩니다.
- 여러 프로세스 동시 실행, 프로세스별 on-demand 관리자 권한 상승(Windows UAC).

### 데이터 저장 (SQLite, 2계층)
- **메인 DB** (`<appSupport>/collabo.db`): 설정 + 최근 이력.
- **대화 DB** (`<project>/.collabo/conversation.db`): 프로젝트별 대화 기록(자기완결형, **가져오기 가능**).
  스키마는 function calling(도구 호출/결과), 멀티 모델/provider/API, 대화 계층(메인↔하위 컨텍스트) 지원.

### 다국어
- **Flutter UI**: ARB(en/ko) + `flutter gen-l10n` (설정 → 모양 → 언어).
- **웹 UI / Python 스크립트**: stdlib만으로 동작하도록 **JSON 언어팩**을 실행 시 전달(웹=메시지, Python=`COLLABO_LANG`).

## 지원 플랫폼

웹뷰 백엔드는 `PlatformWebView` 인터페이스로 추상화되어 플랫폼별 어댑터로 분기합니다
(`lib/src/webview/platform_web_view.dart`).

| 플랫폼      | WebView 백엔드                | 상태             |
|-------------|------------------------------|------------------|
| Windows     | `webview_windows` (WebView2)  | 1차 대상         |
| macOS       | `webview_flutter` (WKWebView) | 지원 (실기기 검증 필요) |
| Android/iOS | `webview_flutter`             | 향후 (플랫폼 폴더 추가 시) |
| Linux       | `webview_cef` (예정)          | 미지원 (플레이스홀더) |

> Windows 웹뷰는 휠 스크롤 등 일부 동작을 JS 주입으로 보정합니다(`needsWheelWorkaround`).
> 메시지 브리지는 Windows=네이티브 메시지 채널, `webview_flutter`=JS 채널(`Collabo`) +
> `runJavaScript`(base64)로 동일한 프로토콜을 주고받습니다.
> macOS 는 외부 통신을 위해 `com.apple.security.network.client` 엔타이틀먼트가 필요합니다(설정됨).

## 사전 요구사항

- [Flutter SDK](https://docs.flutter.dev/get-started/install) (데스크톱 지원)
- **Windows**: [WebView2 런타임](https://developer.microsoft.com/microsoft-edge/webview2/) (대개 기본 설치됨)
- 도구 실행용 **Python 3** (설정 → 도구 → Python 설정에서 인터프리터 선택; 자동 다운로드 없음)

## 빌드 / 실행

```bash
flutter pub get
flutter gen-l10n           # 다국어 코드 생성(빌드 시 자동 실행되기도 함)
flutter run -d windows     # 실행
flutter build windows      # 빌드
```

## 폴더 구조

```
collabo_ide/
├── lib/
│   ├── main.dart
│   ├── l10n/                 # ARB(en/ko) + 생성된 AppLocalizations
│   └── src/
│       ├── app/              # WorkspaceController (전역 상태)
│       ├── conversation/     # 대화 DB(SQLite) + 모델
│       ├── data/             # 메인 DB, SQLite 초기화
│       ├── fs/               # 파일시스템 서비스(트리/뷰어)
│       ├── llm/              # OpenAI 호환 클라이언트, 설정, 시스템 프롬프트
│       ├── process/          # 런쳐 프로세스 매니저, Python 환경
│       ├── tools/            # 도구 모듈 계약/실행/소스
│       ├── ui/               # 좌측 메뉴, 설정/콘솔/새 프로젝트 다이얼로그, 테마
│       └── webview/          # 웹뷰 패널, 브리지, 에셋 추출
├── assets/
│   ├── web/                  # 웹 UI(index.html), vendor(Bootstrap/marked), lang(JSON)
│   └── python/               # 기본 도구 모듈, CLI/MCP 어댑터, env_check, lang(JSON)
├── docs/                     # 설계 문서
└── README.md
```

## 문서

| 문서 | 내용 |
|------|------|
| [docs/layout.md](docs/layout.md) | 화면 레이아웃·메뉴·설정 창 |
| [docs/tree-and-bridge.md](docs/tree-and-bridge.md) | 트리뷰 + Flutter↔Web 브리지 프로토콜 |
| [docs/conversation-db.md](docs/conversation-db.md) | 데이터 저장 구조(메인 DB + 대화 DB 스키마) |
| [docs/process-management.md](docs/process-management.md) | 서브프로세스 관리, Python 인터프리터, 권한 상승 |
| [docs/llm.md](docs/llm.md) | LLM 연동(설정·스트리밍·오류 처리) |
| [docs/agent.md](docs/agent.md) | 에이전트 플로우, 도구 모듈 계약, 시스템 프롬프트 |

## 현황 / 다음 단계

UI·데이터·도구·LLM 연동의 기반이 갖춰진 상태입니다. 남은 핵심 작업:

- [x] function-calling 실행 루프 (LLM tool_use → 도구 실행 → 결과 회신 반복)
- [x] 하위 컨텍스트 분기 오케스트레이션 (네이티브 도구 `run_subagent`/`verify_work` 기반 위임)
- [x] 파일/내용 검색 (`search_text`) 및 부분 읽기/편집 (`read_lines`/`replace_lines`) 도구
- [x] macOS 웹뷰 백엔드 (`webview_flutter`) + `PlatformWebView` 추상화 *(실기기 검증 필요)*
- [ ] 대용량 파일 뷰어 가상 스크롤
- [ ] Linux 웹뷰 백엔드 (`webview_cef`)
- [ ] Linux / macOS 권한 상승 (pkexec / osascript)
- [ ] 모바일(Android/iOS) 플랫폼 폴더 추가 및 검증
