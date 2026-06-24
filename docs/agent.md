# Collabo IDE — 에이전트 플로우 & 도구 모듈

LLM 과 대화하며 코딩하는 기본 에이전트의 구조. 실제 개별 작업은 **Python 도구 모듈**이
수행하고, LLM 은 **function calling** 으로만 작업을 지시한다(직접 위험한 편집을 하지 않게 가이드).

## 시스템 프롬프트 (실행 전략)

실행 전략은 **영어 시스템 프롬프트**(`lib/src/llm/system_prompt.dart`의 `kDefaultSystemPrompt`)로
정리되어, 모든 대화 시작 시 첫 system 메시지로 주입된다(대화 DB에는 저장하지 않음).
사용자가 **설정 → 프롬프트** 탭에서 편집할 수 있고(메인 DB `system_prompt`에 저장),
비우면 기본값으로 되돌아간다.

## 기본 플로우 (분기/하위 컨텍스트)

```
사용자 요구사항
   │
   ▼
메인 LLM ──(요구 실행용 프롬프트 생성)──► 하위 컨텍스트(별도 분기, 대화창 미표시)
                                            │  요구사항 수신
                                            ├─ 필요시 원래 LLM 에 재질의
                                            └─ 바로 진행 가능하면 ▼
                                         도구 호출(function calling)
                                            │
                                            ▼
                                   Python 도구 모듈(안전 실행 계층)
                                            │  파일/명령/권한상승 …
                                            ▼
                                       결과 → 도구 결과로 LLM 에 반환
```

- 프롬프트 생성·하위 에이전트 호출은 **대화 리스트에 추가하지 않고 하위 컨텍스트로 분기**한다.
  메인 컨텍스트를 아끼고 대화창에는 표시하지 않아 간략화한다.
- 하위 컨텍스트는 상위 대화/메시지를 참조한다. (스키마: [conversation-db.md](conversation-db.md) 의
  `conversations.kind=sub`, `parent_conversation_id`, `parent_message_id`)

## Python 도구 모듈 (안전 실행 계층)

LLM 이 직접 파일을 고치지 않고, 정의된 도구를 통해서만 작업한다.

- **기본 모듈은 고정**(`assets/python/collabo_tools.py`, 앱에 임베딩 → 실행 시 추출).
- **확장 가능**: **설정 → 도구** 에서 두 가지 모드로 추가 → tools 로 확장.

### 도구 추가 모드

| 모드 | 동작 | 어댑터 |
|------|------|--------|
| 일반 Python 스크립트 | 대상 스크립트의 `--help` 를 실행·파싱해 function-calling JSON 을 **자동 생성**. LLM 호출 시 인자를 CLI 인자로 변환해 실행. 생성된 JSON 은 설정의 "도구 보기"에서 확인. | `assets/python/cli_adapter.py` (env `COLLABO_TARGET`) |
| MCP 도구 | **내장 Python** 으로 MCP 서버를 stdio(JSON-RPC) 로 제어. 서버의 tools/list 를 도구로 노출하고 tools/call 로 실행. | `assets/python/mcp_adapter.py` (env `COLLABO_MCP_COMMAND`) |

두 어댑터 모두 기본 모듈과 동일한 `describe`/`call` 계약을 따르므로 동일 실행기
(`ToolRunner`)에 그대로 연결된다. 소스 설정은 `ToolSource`(kind=cli|mcp)로 저장된다.

### 모듈 계약 (contract)

```
describe:  <python> <script> describe
           → stdout(JSON): {"module","version","tools":[<OpenAI tool schema>...]}
call:      <python> <script> call <tool_name>
           ← stdin(JSON): 도구 인자(object)
           → stdout(JSON): {"ok":true,"result":...}
                         | {"ok":false,"error":"..."}
                         | {"ok":false,"needs_elevation":true,"reason":"..."}
환경변수:  COLLABO_WORKSPACE(작업 루트 밖 접근 차단), COLLABO_ELEVATED(=1 관리자 실행)
```

### 기본 모듈 도구

`read_file`, `list_directory`, `create_directory`, `create_file`(기본 덮어쓰기 금지),
`write_file`, `edit_file`(replace_all 아니면 유일 매칭 강제), `delete_path`(디렉토리는 recursive 필요),
`move_path`, `run_command`(elevated 옵션), `request_elevation`.

**안전 가이드**: 워크스페이스 밖 경로 차단, 새 파일 덮어쓰기 금지, 모호한 편집 거부,
디렉토리 삭제에 명시적 recursive 요구 — LLM 의 실수/위험 작업을 구조적으로 막는다.

### 구현 위치

| 구성요소            | 위치                                       |
|--------------------|--------------------------------------------|
| 기본 모듈(Python)   | `assets/python/collabo_tools.py`           |
| 모델/실행 계약(Dart)| `lib/src/tools/tool_module.dart`, `tool_runner.dart` |
| 모듈 추출           | `lib/src/tools/tool_assets.dart`           |
| 사용자 모듈 설정     | `WorkspaceController.userToolModules`, 설정 "도구" 탭 |

### 권한 상승 연계

도구가 `needs_elevation` 을 반환하면 native 가 [프로세스 관리](process-management.md)의
on-demand 권한 상승으로 모듈을 재실행한다(`COLLABO_ELEVATED=1`).

## 실행 루프 동작

- **재시도**: 도구 호출은 했으나 최종 응답으로 수렴하지 못하거나(반복 한도 초과) 오류가
  나면, 그 시도에 추가된 메시지를 정리하고 **최대 3회** 재시도한다(웹에 `retry n/3` 알림).
- **빈 응답 처리**: 도구만 호출하고 텍스트가 없는 턴은 빈 카드 대신 `Brewed for 12s` 같은
  **요약 문구**(임의 동사 + 처리 시간)로 표시한다. 기록 재표시 시 빈 assistant 카드는 생략.
- **호출 내역**: 대화 헤더(트리 토글 왼쪽) 아이콘 → 도구/런쳐 호출 목록 팝업
  (이름·인자·결과·시각, 실시간 갱신).

## 미구현(후속)

- function-calling 채팅 루프: LLM tool_use → `ToolRunner.call` → 도구 결과를 다시 LLM 으로.
- 하위 컨텍스트 분기 호출의 실제 오케스트레이션(프롬프트 생성 LLM ↔ 실행 LLM).
- 도구 호출/결과의 대화 DB 기록 연계(`tool_calls`/`tool_call_id` 필드는 준비됨).
- 사용자 모듈 추가 시 `describe` 검증/도구 미리보기.
