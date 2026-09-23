import Foundation

public enum FinishReason: String, Sendable {
  case stop
  case length
  case toolCalls = "tool_calls"
  case contentFilter = "content_filter"
}

public struct Usage: Sendable, Equatable {
  public var promptTokens: Int
  public var completionTokens: Int
  public var totalTokens: Int { promptTokens + completionTokens }

  public init(promptTokens: Int, completionTokens: Int) {
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
  }

  public var json: JSONValue {
    [
      "prompt_tokens": .number(Double(promptTokens)),
      "completion_tokens": .number(Double(completionTokens)),
      "total_tokens": .number(Double(totalTokens)),
    ]
  }
}

/// 비스트리밍 응답 (`object: chat.completion`)
public struct ChatCompletion: Sendable, Equatable {
  public var id: String
  public var created: Int
  public var model: String
  public var content: String?
  public var toolCalls: [ToolCall]
  public var finishReason: FinishReason
  public var usage: Usage?

  public init(
    id: String = ChatCompletion.makeID(),
    created: Int = ChatCompletion.now(),
    model: String,
    content: String?,
    toolCalls: [ToolCall] = [],
    finishReason: FinishReason,
    usage: Usage?
  ) {
    self.id = id
    self.created = created
    self.model = model
    self.content = content
    self.toolCalls = toolCalls
    self.finishReason = finishReason
    self.usage = usage
  }

  public static func makeID() -> String {
    "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
  }

  public static func now() -> Int { Int(Date().timeIntervalSince1970) }

  public var json: JSONValue {
    var message: JSONObject = ["role": "assistant"]
    message["content"] = content.map(JSONValue.string) ?? .null
    if !toolCalls.isEmpty { message["tool_calls"] = .array(toolCalls.map(\.json)) }
    message["refusal"] = .null

    var object: JSONObject = [
      "id": .string(id),
      "object": "chat.completion",
      "created": .number(Double(created)),
      "model": .string(model),
      "choices": [
        [
          "index": 0,
          "message": .object(message),
          "logprobs": nil,
          "finish_reason": .string(finishReason.rawValue),
        ]
      ],
    ]
    if let usage { object["usage"] = usage.json }
    object["system_fingerprint"] = .string(AFMBridgeInfo.fingerprint)
    return .object(object)
  }
}

/// 스트리밍 청크 (`object: chat.completion.chunk`)
public struct ChatCompletionChunk: Sendable, Equatable {
  public enum Delta: Sendable, Equatable {
    case role
    case content(String)
    case toolCalls([ToolCall])
    case finish(FinishReason)
    /// `stream_options.include_usage` 일 때 마지막에 choices 가 빈 청크
    case usage(Usage)
  }

  public var id: String
  public var created: Int
  public var model: String
  public var delta: Delta

  public init(id: String, created: Int, model: String, delta: Delta) {
    self.id = id
    self.created = created
    self.model = model
    self.delta = delta
  }

  public var json: JSONValue {
    var object: JSONObject = [
      "id": .string(id),
      "object": "chat.completion.chunk",
      "created": .number(Double(created)),
      "model": .string(model),
      "system_fingerprint": .string(AFMBridgeInfo.fingerprint),
    ]

    func choice(delta: JSONValue, finish: FinishReason? = nil) -> JSONValue {
      [
        "index": 0,
        "delta": delta,
        "logprobs": nil,
        "finish_reason": finish.map { .string($0.rawValue) } ?? .null,
      ]
    }

    switch delta {
    case .role:
      object["choices"] = [choice(delta: ["role": "assistant", "content": ""])]
    case .content(let text):
      object["choices"] = [choice(delta: ["content": .string(text)])]
    case .toolCalls(let calls):
      let items: [JSONValue] = calls.enumerated().map { index, call in
        [
          "index": .number(Double(index)),
          "id": .string(call.id),
          "type": "function",
          "function": ["name": .string(call.name), "arguments": .string(call.arguments)],
        ]
      }
      object["choices"] = [choice(delta: ["tool_calls": .array(items)])]
    case .finish(let reason):
      object["choices"] = [choice(delta: [:], finish: reason)]
    case .usage(let usage):
      object["choices"] = []
      object["usage"] = usage.json
    }
    return .object(object)
  }
}

public enum SSE {
  public static func event(_ json: JSONValue) -> String { "data: \(json.jsonString)\n\n" }
  public static let done = "data: [DONE]\n\n"
}

public enum AFMBridgeInfo {
  public static let version = "0.1.0"
  public static let fingerprint = "afmbridge-\(version)"
}
