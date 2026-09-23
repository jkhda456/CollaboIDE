import Foundation


/// OpenAI `messages` 를 Foundation Models 세션 구성으로 나눈 계획.
///
/// - system/developer 메시지는 모두 모아 instructions 로 합친다.
/// - 마지막 user 메시지가 `respond(to:)` 의 prompt 가 된다.
/// - 그 이전 메시지는 transcript history 가 된다.
/// - 마지막 user 메시지 **이후**의 assistant(tool_calls)/tool 메시지는 도구 호출 라운드트립 결과다.
///   FM 은 도구 결과 뒤에 새 prompt 없이 이어서 생성하는 API 가 없으므로, prompt 를 다시 실행하고
///   모델이 같은 도구를 호출하면 클라이언트가 준 결과를 돌려주는 방식(replay)으로 이어간다.
public struct ConversationPlan: Sendable, Equatable {
  public var instructions: String?
  public var history: [ChatMessage]
  public var prompt: String
  public var replayedToolResults: [ReplayedToolResult]

  public init(
    instructions: String?, history: [ChatMessage], prompt: String, replayedToolResults: [ReplayedToolResult]
  ) {
    self.instructions = instructions
    self.history = history
    self.prompt = prompt
    self.replayedToolResults = replayedToolResults
  }
}

public struct ReplayedToolResult: Sendable, Equatable {
  public var callID: String
  public var name: String
  public var arguments: String
  public var output: String

  public init(callID: String, name: String, arguments: String, output: String) {
    self.callID = callID
    self.name = name
    self.arguments = arguments
    self.output = output
  }
}

extension ConversationPlan {
  public static func make(from messages: [ChatMessage]) throws(BridgeError) -> ConversationPlan {
    let systemTexts = messages.filter { $0.role == .system || $0.role == .developer }.compactMap(\.content)
      .filter { !$0.isEmpty }
    let conversation = messages.filter { $0.role != .system && $0.role != .developer }

    guard let promptIndex = conversation.lastIndex(where: { $0.role == .user }) else {
      throw .invalidRequest("At least one user message is required.", param: "messages")
    }

    let trailing = conversation[(promptIndex + 1)...]
    var outputs: [String: String] = [:]
    for message in trailing {
      switch message.role {
      case .tool:
        if let id = message.toolCallID { outputs[id] = message.content ?? "" }
      case .assistant:
        if message.toolCalls.isEmpty {
          throw .invalidRequest(
            "The conversation must end with a user message or tool results.", param: "messages")
        }
      default:
        break
      }
    }

    var replayed: [ReplayedToolResult] = []
    for message in trailing where message.role == .assistant {
      for call in message.toolCalls {
        guard let output = outputs[call.id] else {
          throw .invalidRequest("Missing tool result for tool_call_id '\(call.id)'.", param: "messages")
        }
        replayed.append(.init(callID: call.id, name: call.name, arguments: call.arguments, output: output))
      }
    }

    return ConversationPlan(
      instructions: systemTexts.isEmpty ? nil : systemTexts.joined(separator: "\n\n"),
      history: Array(conversation[..<promptIndex]),
      prompt: conversation[promptIndex].content ?? "",
      replayedToolResults: replayed
    )
  }
}

extension JSONValue {
  /// 키를 정렬한 직렬화. 도구 인자 비교 등에 사용.
  public var canonicalString: String {
    switch self {
    case .object(let object):
      let sorted = object.entries.sorted { $0.key < $1.key }
      var result = "{"
      for (offset, entry) in sorted.enumerated() {
        if offset > 0 { result += "," }
        JSONValue.writeString(entry.key, to: &result)
        result += ":" + entry.value.canonicalString
      }
      return result + "}"
    case .array(let values):
      return "[" + values.map(\.canonicalString).joined(separator: ",") + "]"
    default:
      return jsonString
    }
  }
}

public enum TextCleanup {
  /// ```json ... ``` 코드 펜스를 제거한다 (json_object 모드).
  public static func stripCodeFences(_ text: String) -> String {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    if let newline = trimmed.firstIndex(of: "\n") {
      trimmed = String(trimmed[trimmed.index(after: newline)...])
    } else {
      trimmed = String(trimmed.dropFirst(3))
    }
    if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)) }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
