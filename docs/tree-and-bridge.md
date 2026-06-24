# Collabo IDE — 트리뷰 & Flutter↔Web 브리지

우측 트리뷰/파일 뷰어는 **네이티브가 파일시스템을 읽어 웹으로 전달**하고 웹이 렌더링한다.
웹은 OS 파일시스템에 직접 접근하지 않는다.

## 브리지 (메시지 프로토콜)

`webview_windows` 의 메시지 채널 위에서 JSON 으로 통신한다.

| 방향          | 메시지              | 페이로드                         | 용도                       |
|---------------|--------------------|----------------------------------|----------------------------|
| Web → Dart    | `ready`            | —                                | 웹 준비 완료(현재 프로젝트 요청) |
| Web → Dart    | `dir.list`         | `{path}`                         | 디렉토리 직속 항목 요청     |
| Web → Dart    | `file.open`        | `{path, mode?}`                  | 파일 내용 요청             |
| Web → Dart    | `clipboard.write`  | `{text}`                         | 클립보드 복사(우클릭 메뉴)  |
| Dart → Web    | `project.changed`  | `{path}`                         | 프로젝트 변경 → 트리 리셋   |
| Dart → Web    | `dir.children`     | `{path, entries[]}`              | 디렉토리 항목 응답         |
| Dart → Web    | `fs.change`        | `{paths[]}`                      | 변경된 디렉토리(실시간 감시) |
| Dart → Web    | `file.content`     | `{path, mode, content, size, truncated}` | 파일 내용 응답  |
| Dart → Web    | `file.error`       | `{path, message}`                | 파일 열기 실패             |

- 구현: `lib/src/webview/web_bridge.dart`, `lib/src/fs/file_service.dart`, `assets/web/index.html`.
- 테마는 별도로 네이티브가 `executeScript('collaboSetTheme(...)')` 로 직접 전달.

## 실시간 트리 (상태 보존)

- 네이티브가 프로젝트 루트를 `Directory.watch(recursive: true)` 로 감시한다.
- 변경 이벤트는 **영향받은 부모 디렉토리** 단위로 200ms 디바운스 후 `fs.change` 로 통지.
- 웹은 **이미 펼쳐/조회한 디렉토리만** 다시 `dir.list` 요청해 그 부분만 갱신한다.
  → 사용자가 보고 있는 트리가 멋대로 접히지 않는다(펼침 상태/선택 유지).
- 디렉토리 나열은 **지연 로딩**(펼칠 때 요청)이라 큰 프로젝트도 한 번에 다 읽지 않는다.

## 우클릭 메뉴

- 트리 항목 우클릭 → 컨텍스트 메뉴.
- 현재 항목: **전체 경로 복사** (`clipboard.write` → 네이티브 `Clipboard.setData`).
- 이후 항목(이름 변경/삭제/새 파일 등)은 확장 예정.

## 파일 뷰어 (text / hex / md)

- 트리에서 파일 클릭 → `file.open` → 하단 뷰어에 표시.
- 모드 전환 탭: **Text / Hex / MD**(md 는 `marked` 로 렌더). 기본 모드는 확장자로 추정.
- **대용량 파일 가드**: 한 번에 읽는 상한 — text/md `1MB`, hex `256KB`.
  초과 시 앞부분만 표시하고 전체 크기와 함께 잘림(truncated) 안내를 띄운다.

### 미구현(후속)

- 편집/저장: 현재는 **읽기 전용 표시**. 대용량 파일의 부분 편집은 청크 읽기/쓰기 +
  가상 스크롤 에디터로 별도 단계에서 확장(상한 구조는 이미 마련).
- 파일 이름/내용 검색의 실제 동작(현재 UI 토글만).
- Linux/macOS 웹뷰 백엔드.
