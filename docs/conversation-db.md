# Collabo IDE — 데이터 저장 구조

DB는 두 계층으로 나뉜다.

| DB             | 위치                              | 내용                          |
|----------------|-----------------------------------|-------------------------------|
| **메인 DB**    | `<appSupport>/collabo.db`         | 최근 이력(MRU) + 설정          |
| **대화 DB**    | `<project>/.collabo/conversation.db` | 프로젝트별 대화 기록(자기완결형) |

- 메인 DB는 앱 전역 1개. 프로젝트 대화 기록은 **여기 저장하지 않고** 각 프로젝트의
  독립 파일에 남긴다 → 파일을 옮기거나 **다른 프로젝트로 가져오기(import)** 할 수 있다.
- 구현/스키마: 메인 DB는 `lib/src/data/app_database.dart`, 대화 DB는 아래.

## 메인 DB 스키마 (v1)

```sql
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL    -- JSON 문자열
);
CREATE TABLE recent_projects (
  path           TEXT PRIMARY KEY,
  label          TEXT NOT NULL DEFAULT '',
  last_opened_at INTEGER NOT NULL  -- epoch millis
);
```

- 설정은 KV(JSON) 형태 — 모델 설정/런쳐 옵션 등을 키별로 저장.
- 최근 프로젝트는 MRU, **최대 5개**(`touchRecentProject` 가 초과분 정리).

---

# 대화 기록 DB

가운데 대화창의 내용은 **SQLite** 로 기록되며, **프로젝트 단위**로 보관된다.

## 저장 위치

DB 파일은 프로젝트 폴더 안에 둔다 — 프로젝트와 함께 이동한다.

```
<project>/
└── .collabo/
    └── conversation.db
```

## 백엔드

- 데스크톱(Windows/Linux/macOS)이므로 `sqflite_common_ffi` + `sqlite3_flutter_libs`(네이티브 lib 번들) 사용.
- 앱 시작 시 `ConversationStore.initSqliteFfi()` 로 FFI 백엔드를 1회 활성화한다 (`main()`).

## 스키마 (v2)

```sql
CREATE TABLE meta (              -- 가져오기 검증용 식별 표식
  key   TEXT PRIMARY KEY,        --  kind = 'collabo-conversation'
  value TEXT NOT NULL            --  schema_version = '2'
);

CREATE TABLE conversations (
  id                     INTEGER PRIMARY KEY AUTOINCREMENT,
  title                  TEXT NOT NULL DEFAULT '',
  kind                   TEXT NOT NULL DEFAULT 'main',  -- main | sub
  parent_conversation_id INTEGER REFERENCES conversations(id) ON DELETE CASCADE,
  parent_message_id      INTEGER,   -- 이 하위 대화를 분기시킨 상위 메시지(soft ref)
  tools                  TEXT,       -- 이 컨텍스트에 선언된 도구(JSON)
  metadata               TEXT,       -- 기타(JSON)
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL
);

CREATE TABLE messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  role            TEXT NOT NULL,  -- user | assistant | system | tool | process
  content         TEXT NOT NULL,
  model           TEXT,           -- 처리 모델(예: claude-opus-4-8)
  provider        TEXT,           -- 제공자/서비스(예: anthropic, openai, local)
  api             TEXT,           -- 사용한 API/엔드포인트(예: messages)
  pipeline        TEXT,           -- 처리 파이프라인 정보(다른 모델 파이프라인 등)
  tool_calls      TEXT,           -- assistant 의 tool_use 목록(JSON)
  tool_call_id    TEXT,           -- tool 결과가 응답하는 호출 ID
  tool_name       TEXT,           -- 도구 이름
  process_id      TEXT,           -- 런쳐 프로세스가 만든 메시지면 그 프로세스 ID
  metadata        TEXT,           -- 임의 부가 정보(JSON)
  created_at      INTEGER NOT NULL
);

CREATE INDEX idx_messages_conv ON messages(conversation_id, created_at);
CREATE INDEX idx_conv_parent   ON conversations(parent_conversation_id);
```

### 대화 계층 (메인 ↔ 하위 컨텍스트)

기본 전략: **메인 대화 컨텍스트**는 작게 유지하고, 개별 처리(도구 실행, 무거운 분석 등)는
**하위 대화(컨텍스트)** 로 분기해 별도 호출로 진행 → 메인 컨텍스트를 절약한다.

- 하위 대화는 `kind='sub'`, `parent_conversation_id` 로 상위 대화를, `parent_message_id`
  로 분기 지점(상위 메시지)을 참조한다.
- 상위 대화 삭제 시 하위 대화도 함께 삭제(`ON DELETE CASCADE`).

### function calling / 멀티 모델

- 모델을 여러 개 쓸 수 있으므로 메시지마다 `model`/`provider`/`api` 로 **무엇으로 처리했는지** 명시.
- 도구 호출은 `tool_calls`(assistant), 결과는 `role='tool'` + `tool_call_id`/`tool_name`.
- 컨텍스트에 선언된 도구 집합은 `conversations.tools`.

### 기타

- 런쳐 프로세스의 출력은 `role='process'`, `process_id` 로 연결된 메시지로 누적된다
  (참고: [process-management.md](process-management.md)).
- 스키마 버전은 sqflite 가 `PRAGMA user_version` 으로 관리. v1→v2 는 `onUpgrade` 에서
  `ALTER TABLE ADD COLUMN` 으로 마이그레이션.

## 구현 위치

| 구성요소            | 위치                                          |
|--------------------|-----------------------------------------------|
| 데이터 모델         | `lib/src/conversation/models.dart`            |
| 저장소(Store)       | `lib/src/conversation/conversation_store.dart` |

## API 요약 (`ConversationStore`)

- `openForProject(projectPath)` — 프로젝트 DB 열기/생성.
- `createConversation(...)` / `createSubConversation(parentConversationId, parentMessageId, ...)`.
- `listConversations()` / `listMainConversations()` / `subConversations(parentId)` / `conversation(id)`.
- `renameConversation()` / `deleteConversation()`.
- `addMessage(conversationId, role, content, model, provider, api, pipeline, toolCalls, toolCallId, toolName, processId, metadata)` — 메시지 추가(대화 updated_at 갱신).
- `messages(conversationId)` — 시간순 메시지 조회.

## 가져오기 (import)

대화 DB는 자기완결형 파일이라 다른 프로젝트로 가져올 수 있다.

- `isConversationDb(path)` — `meta.kind == 'collabo-conversation'` 으로 대화 DB 인지 검증.
- `importFrom(sourcePath)` — 외부 대화 DB 의 모든 대화/메시지를 현재 저장소로 **병합**한다.
  `ATTACH DATABASE` 로 원본을 붙이고 ID 를 새로 부여해 충돌 없이 복사하며, 가져온 대화 수를 반환.

## 미결정 사항

- 대화 ↔ 웹뷰(대화창) 연동: 메시지 추가/조회를 브리지로 어떻게 노출할지.
- 런쳐 프로세스 출력의 메시지 단위(라인별 vs 청크별 vs 실행 단위 1건).
- 첨부/코드블록 등 메시지 본문 포맷(현재 평문 + metadata JSON).
