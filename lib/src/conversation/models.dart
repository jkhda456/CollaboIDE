/// 대화 메시지의 발화 주체.
enum MessageRole {
  user,
  assistant,
  system,
  /// function calling 의 도구 실행 결과 메시지.
  tool,
  /// 런쳐 프로세스의 출력이 대화에 누적된 메시지.
  process,
}

MessageRole _roleFromName(String name) => MessageRole.values.firstWhere(
      (r) => r.name == name,
      orElse: () => MessageRole.system,
    );

/// 대화 종류. 메인 컨텍스트 / 하위 컨텍스트.
enum ConversationKind { main, sub }

ConversationKind _kindFromName(String? name) =>
    name == 'sub' ? ConversationKind.sub : ConversationKind.main;

/// 하나의 대화 스레드(컨텍스트).
///
/// 메인 대화는 [kind] = main 이고, 개별 처리를 위해 분기한 하위 대화는 sub 이며
/// [parentConversationId]/[parentMessageId] 로 상위 대화를 참조한다.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
    this.parentConversationId,
    this.parentMessageId,
    this.tools,
    this.metadata,
  });

  final int id;
  final String title;
  final ConversationKind kind;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 상위 대화 ID(하위 대화일 때). null 이면 최상위(메인).
  final int? parentConversationId;

  /// 이 하위 대화를 분기시킨 상위 대화의 메시지 ID(있으면).
  final int? parentMessageId;

  /// 이 컨텍스트에 선언된 도구 목록(JSON 문자열).
  final String? tools;

  /// 기타 부가 정보(JSON 문자열).
  final String? metadata;

  factory Conversation.fromRow(Map<String, Object?> row) => Conversation(
        id: row['id'] as int,
        title: row['title'] as String? ?? '',
        kind: _kindFromName(row['kind'] as String?),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
        parentConversationId: row['parent_conversation_id'] as int?,
        parentMessageId: row['parent_message_id'] as int?,
        tools: row['tools'] as String?,
        metadata: row['metadata'] as String?,
      );
}

/// 대화 메시지 한 건.
///
/// function calling 지원: assistant 의 [toolCalls](tool_use 목록, JSON),
/// tool 결과 메시지의 [toolCallId]/[toolName]. 처리 출처는 [model]/[pipeline].
class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.model,
    this.provider,
    this.api,
    this.pipeline,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
    this.processId,
    this.metadata,
  });

  final int id;
  final int conversationId;
  final MessageRole role;
  final String content;
  final DateTime createdAt;

  /// 이 메시지를 생성/처리한 모델 식별자(예: claude-opus-4-8).
  final String? model;

  /// 제공자/서비스(예: anthropic, openai, local). 모델을 여러 개 쓸 수 있어 명시.
  final String? provider;

  /// 사용한 API/엔드포인트 식별자(예: messages, responses, 또는 base URL).
  final String? api;

  /// 처리 파이프라인 정보 — 다른 모델 파이프라인으로 처리했음 등(JSON/라벨).
  final String? pipeline;

  /// assistant 의 도구 호출 목록(tool_use, JSON 문자열).
  final String? toolCalls;

  /// tool 결과 메시지가 응답하는 도구 호출 ID.
  final String? toolCallId;

  /// 도구 이름(tool_use/결과).
  final String? toolName;

  /// 이 메시지를 만든 런쳐 프로세스 ID(있으면).
  final String? processId;

  /// 임의 부가 정보(JSON 문자열).
  final String? metadata;

  factory Message.fromRow(Map<String, Object?> row) => Message(
        id: row['id'] as int,
        conversationId: row['conversation_id'] as int,
        role: _roleFromName(row['role'] as String),
        content: row['content'] as String? ?? '',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        model: row['model'] as String?,
        provider: row['provider'] as String?,
        api: row['api'] as String?,
        pipeline: row['pipeline'] as String?,
        toolCalls: row['tool_calls'] as String?,
        toolCallId: row['tool_call_id'] as String?,
        toolName: row['tool_name'] as String?,
        processId: row['process_id'] as String?,
        metadata: row['metadata'] as String?,
      );
}
