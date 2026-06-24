# Collabo IDE — LLM 연동 & 설정

LLM 클라이언트는 **네이티브(Dart)** 에 두고, 스트리밍 결과를 브리지로 웹에 전달한다
(IO/키 보안/DB 일관성). 지금은 **OpenAI 호환 API**, 추후 자체 런쳐 연결을 추가한다.

## 설정 (모델 탭)

좌측 ⚙ → 설정 창(네이티브 다이얼로그, 탭: **모델 / 모양**).

- **모델 탭**: 연결 방식(OpenAI 호환), Base URL, API Key, 모델 이름.
  - **연결 상태 확인** 버튼: `GET {baseUrl}/models` 로 점검 → 성공/실패 표시.
  - 저장 시 메인 DB(`settings`)의 `llm` 키에 JSON 으로 보관.
- **모양 탭**: 테마(라이트/다크/시스템). 기본 라이트.

구현: `lib/src/ui/settings_dialog.dart`, `lib/src/llm/llm_config.dart`,
`lib/src/llm/openai_client.dart`, `WorkspaceController`.

## 대화 연동 (스트리밍)

웹 입력창 전송 → 네이티브가 OpenAI 호환 Chat Completions 를 **스트리밍** 호출 →
델타를 브리지로 웹에 전달 → 완료 시 대화 DB 에 저장.

| 방향        | 메시지              | 내용                                            |
|-------------|--------------------|-------------------------------------------------|
| Web → Dart  | `chat.send`        | `{text}` 사용자 메시지 전송                        |
| Web → Dart  | `chat.retry`       | 현재 기록으로 응답 재생성                          |
| Web → Dart  | `chat.truncateFrom`| `{messageId}` 해당 메시지부터 삭제(수정용)         |
| Dart → Web  | `chat.history`     | 대화 기록 일괄 전달                               |
| Dart → Web  | `chat.message`     | 새 사용자 메시지 에코                             |
| Dart → Web  | `chat.begin`       | assistant 스트리밍 시작                          |
| Dart → Web  | `chat.delta`       | `{content}` / `{reasoning}` 증분                  |
| Dart → Web  | `chat.stats`       | `{status, tokens, speed, elapsedMs, exact}`      |
| Dart → Web  | `chat.done`        | `{id}` 완료(스트리밍 버블 확정)                   |
| Dart → Web  | `chat.error`       | `{message}` 오류(웹에 재시도 버튼)               |

- **실시간 표기**: 상태(connecting/streaming/done), 토큰 수, 속도(tok/s), 경과 시간,
  그리고 **reasoning**(o1/deepseek 등 호환 필드)을 분리 표시.
  - 토큰은 스트리밍 중 근사치(`~`), `usage` 수신 시 정확값으로 대체.
- **저장**: assistant 메시지에 `model`/`provider`/`api`/`pipeline` 기록, reasoning·usage 는
  `metadata`(JSON)에. (스키마: [conversation-db.md](conversation-db.md))

## 오류 처리 / 수정

- **오류 시 재시도**: 오류 버블의 "다시 시도" → `chat.retry` 로 현재 기록 기준 재생성.
- **대화 내용 수정**: 사용자 메시지의 "수정" → 그 메시지부터 잘라내고(`chat.truncateFrom`)
  내용을 입력창으로 되돌림 → 편집 후 다시 전송.

## 미구현(후속)

- 자체 런쳐 기반 연결.
- function calling 실제 실행(스키마/필드는 준비됨), 도구 호출 → 런쳐 프로세스 연계.
- 첨부(+ 버튼) 파일/리소스 업로드.
- 정확한 토크나이저(현재 스트리밍 토큰은 근사치).
- 하위 컨텍스트 분기 호출(메인 컨텍스트 절약 전략)과 대화 UI 연결.
