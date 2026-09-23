/// `POST /v1/chat/completions` 요청.
public struct ChatCompletionRequest: Sendable, Equatable {
  public var model: String
  public var messages: [ChatMessage]
  public var temperature: Double?
  public var topP: Double?
  /// AFMBridge 확장 (OpenAI 표준 아님)
  public var topK: Int?
  public var seed: UInt64?
  public var maxTokens: Int?
  public var stream: Bool
  public var includeUsage: Bool
  public var stop: [String]
  public var responseFormat: ResponseFormat
  public var tools: [ToolDefinition]
  public var toolChoice: ToolChoice
  public var user: String?
  /// AFMBridge 확장: `"guardrails": "permissive"` → `.permissiveContentTransformations`
  /// (nil 이면 엔진 설정을 따른다)
  public var permissiveGuardrails: Bool?

  public init(
    model: String = AFMModelID.default,
    messages: [ChatMessage],
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    seed: UInt64? = nil,
    maxTokens: Int? = nil,
    stream: Bool = false,
    includeUsage: Bool = false,
    stop: [String] = [],
    responseFormat: ResponseFormat = .text,
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .auto,
    user: String? = nil,
    permissiveGuardrails: Bool? = nil
  ) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.seed = seed
    self.maxTokens = maxTokens
    self.stream = stream
    self.includeUsage = includeUsage
    self.stop = stop
    self.responseFormat = responseFormat
    self.tools = tools
    self.toolChoice = toolChoice
    self.user = user
    self.permissiveGuardrails = permissiveGuardrails
  }
}

public enum ChatRole: String, Sendable, Equatable {
  case system, developer, user, assistant, tool
}

public struct ChatMessage: Sendable, Equatable {
  public var role: ChatRole
  public var content: String?
  public var name: String?
  /// assistant 메시지의 도구 호출
  public var toolCalls: [ToolCall]
  /// tool 메시지가 응답하는 호출 id
  public var toolCallID: String?

  public init(
    role: ChatRole, content: String?, name: String? = nil, toolCalls: [ToolCall] = [], toolCallID: String? = nil
  ) {
    self.role = role
    self.content = content
    self.name = name
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
  }

  public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
  public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
  public static func assistant(_ content: String) -> ChatMessage { .init(role: .assistant, content: content) }
}

public struct ToolCall: Sendable, Equatable {
  public var id: String
  public var name: String
  /// JSON 문자열 (OpenAI 형식 그대로)
  public var arguments: String

  public init(id: String, name: String, arguments: String) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }

  public var json: JSONValue {
    [
      "id": .string(id),
      "type": "function",
      "function": ["name": .string(name), "arguments": .string(arguments)],
    ]
  }
}

public struct ToolDefinition: Sendable, Equatable {
  public var name: String
  public var description: String?
  /// JSON Schema (object)
  public var parameters: JSONValue

  public init(name: String, description: String?, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

public enum ToolChoice: Sendable, Equatable {
  case auto
  case none
  case required
  case function(String)
}

public enum ResponseFormat: Sendable, Equatable {
  case text
  case jsonObject
  case jsonSchema(name: String, schema: JSONValue)
}

/// 모델 id
public enum AFMModelID {
  /// SystemLanguageModel(useCase: .general)
  public static let `default` = "apple-on-device"
  /// SystemLanguageModel(useCase: .contentTagging)
  public static let contentTagging = "apple-on-device-content-tagging"

  public static let all = [`default`, contentTagging]

  /// 클라이언트가 보낸 model 문자열을 정규화한다. 모르는 이름은 기본 모델로 간주한다
  /// (OpenAI 클라이언트들이 "gpt-4o" 등 기본값을 보내는 경우가 많기 때문).
  public static func normalize(_ model: String) -> String {
    all.contains(model) ? model : `default`
  }
}

// MARK: - Parsing

extension ChatCompletionRequest {
  public static func parse(_ json: JSONValue) throws(BridgeError) -> ChatCompletionRequest {
    guard let body = json.objectValue else { throw .invalidRequest("Request body must be a JSON object.") }

    guard let rawMessages = body["messages"]?.arrayValue else {
      throw .invalidRequest("'messages' is required and must be an array.", param: "messages")
    }
    guard !rawMessages.isEmpty else {
      throw .invalidRequest("'messages' must contain at least one message.", param: "messages")
    }
    var messages: [ChatMessage] = []
    for (index, raw) in rawMessages.enumerated() {
      messages.append(try ChatMessage.parse(raw, index: index))
    }

    var request = ChatCompletionRequest(model: body["model"]?.stringValue ?? AFMModelID.default, messages: messages)

    request.temperature = try optionalNumber(body, "temperature", range: 0...2)
    request.topP = try optionalNumber(body, "top_p", range: 0...1)
    if let topK = body["top_k"], !topK.isNull {
      guard let value = topK.intValue, value > 0 else {
        throw .invalidRequest("'top_k' must be a positive integer.", param: "top_k")
      }
      request.topK = value
    }
    if let seed = body["seed"], !seed.isNull {
      guard let value = seed.intValue else { throw .invalidRequest("'seed' must be an integer.", param: "seed") }
      request.seed = UInt64(bitPattern: Int64(value))
    }
    for key in ["max_completion_tokens", "max_tokens"] {
      if let value = body[key], !value.isNull {
        guard let tokens = value.intValue, tokens > 0 else {
          throw .invalidRequest("'\(key)' must be a positive integer.", param: key)
        }
        request.maxTokens = tokens
        break
      }
    }
    if let n = body["n"], !n.isNull, n.intValue != 1 {
      throw .invalidRequest("Only n=1 is supported.", param: "n")
    }
    if body["logprobs"]?.boolValue == true {
      throw .invalidRequest("logprobs is not supported by the on-device model.", param: "logprobs")
    }

    request.stream = body["stream"]?.boolValue ?? false
    request.includeUsage = body["stream_options"]?["include_usage"]?.boolValue ?? false
    request.user = body["user"]?.stringValue
    switch body["guardrails"]?.stringValue {
    case "permissive"?: request.permissiveGuardrails = true
    case "default"?: request.permissiveGuardrails = false
    case nil: break
    default: throw .invalidRequest("'guardrails' must be 'default' or 'permissive'.", param: "guardrails")
    }

    switch body["stop"] {
    case .string(let value)?: request.stop = [value]
    case .array(let values)?: request.stop = values.compactMap(\.stringValue).filter { !$0.isEmpty }
    default: break
    }

    request.responseFormat = try ResponseFormat.parse(body["response_format"])

    if let rawTools = body["tools"]?.arrayValue {
      for (index, rawTool) in rawTools.enumerated() {
        request.tools.append(try ToolDefinition.parse(rawTool, index: index))
      }
    }
    request.toolChoice = try ToolChoice.parse(body["tool_choice"])
    if case .function(let name) = request.toolChoice, !request.tools.contains(where: { $0.name == name }) {
      throw .invalidRequest("tool_choice references unknown function '\(name)'.", param: "tool_choice")
    }
    if request.toolChoice == .required, request.tools.isEmpty {
      throw .invalidRequest("tool_choice 'required' needs at least one tool.", param: "tool_choice")
    }
    return request
  }

  private static func optionalNumber(
    _ body: JSONObject, _ key: String, range: ClosedRange<Double>
  ) throws(BridgeError) -> Double? {
    guard let value = body[key], !value.isNull else { return nil }
    guard let number = value.doubleValue, range.contains(number) else {
      throw .invalidRequest(
        "'\(key)' must be a number between \(range.lowerBound) and \(range.upperBound).", param: key)
    }
    return number
  }
}

extension ChatMessage {
  static func parse(_ json: JSONValue, index: Int) throws(BridgeError) -> ChatMessage {
    let param = "messages[\(index)]"
    guard let object = json.objectValue else { throw .invalidRequest("Message must be an object.", param: param) }
    guard let roleString = object["role"]?.stringValue, let role = ChatRole(rawValue: roleString) else {
      throw .invalidRequest("Invalid or missing role.", param: "\(param).role")
    }

    let content = try parseContent(object["content"], param: "\(param).content")

    var toolCalls: [ToolCall] = []
    if role == .assistant, let rawCalls = object["tool_calls"]?.arrayValue {
      for (callIndex, rawCall) in rawCalls.enumerated() {
        guard let function = rawCall["function"], let name = function["name"]?.stringValue else {
          throw .invalidRequest("tool_call.function.name is required.", param: "\(param).tool_calls[\(callIndex)]")
        }
        let arguments: String
        switch function["arguments"] {
        case .string(let value)?: arguments = value
        case .object?, .array?: arguments = function["arguments"]!.jsonString
        default: arguments = "{}"
        }
        let id = rawCall["id"]?.stringValue ?? "call_\(index)_\(callIndex)"
        toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
      }
    }

    let toolCallID = object["tool_call_id"]?.stringValue
    if role == .tool, toolCallID == nil {
      throw .invalidRequest("tool messages require 'tool_call_id'.", param: "\(param).tool_call_id")
    }
    if role != .assistant, content == nil {
      throw .invalidRequest("Message content is required.", param: "\(param).content")
    }

    return ChatMessage(
      role: role, content: content, name: object["name"]?.stringValue, toolCalls: toolCalls, toolCallID: toolCallID)
  }

  /// content 는 문자열 또는 content part 배열.
  private static func parseContent(_ json: JSONValue?, param: String) throws(BridgeError) -> String? {
    switch json {
    case nil, .null?: return nil
    case .string(let text)?: return text
    case .array(let parts)?:
      var texts: [String] = []
      for part in parts {
        switch part["type"]?.stringValue {
        case "text", "input_text", "output_text":
          texts.append(part["text"]?.stringValue ?? "")
        case "image_url", "input_image":
          throw .invalidRequest("Image input is not supported yet.", param: param, code: "unsupported_content")
        default:
          throw .invalidRequest("Unsupported content part type.", param: param, code: "unsupported_content")
        }
      }
      return texts.joined(separator: "\n")
    default:
      throw .invalidRequest("content must be a string or an array of content parts.", param: param)
    }
  }
}

extension ResponseFormat {
  static func parse(_ json: JSONValue?) throws(BridgeError) -> ResponseFormat {
    guard let json, !json.isNull else { return .text }
    switch json["type"]?.stringValue {
    case "text"?: return .text
    case "json_object"?: return .jsonObject
    case "json_schema"?:
      guard let spec = json["json_schema"], let schema = spec["schema"], schema.objectValue != nil else {
        throw .invalidRequest("response_format.json_schema.schema is required.", param: "response_format")
      }
      return .jsonSchema(name: spec["name"]?.stringValue ?? "Response", schema: schema)
    default:
      throw .invalidRequest("Unsupported response_format type.", param: "response_format")
    }
  }
}

extension ToolDefinition {
  static func parse(_ json: JSONValue, index: Int) throws(BridgeError) -> ToolDefinition {
    let param = "tools[\(index)]"
    guard json["type"]?.stringValue == "function", let function = json["function"] else {
      throw .invalidRequest("Only function tools are supported.", param: param)
    }
    guard let name = function["name"]?.stringValue, !name.isEmpty else {
      throw .invalidRequest("function.name is required.", param: "\(param).function.name")
    }
    let parameters = function["parameters"] ?? ["type": "object", "properties": [:]]
    return ToolDefinition(name: name, description: function["description"]?.stringValue, parameters: parameters)
  }
}

extension ToolChoice {
  static func parse(_ json: JSONValue?) throws(BridgeError) -> ToolChoice {
    switch json {
    case nil, .null?, .string("auto")?: return .auto
    case .string("none")?: return .none
    case .string("required")?: return .required
    case .object?:
      if let name = json?["function"]?["name"]?.stringValue { return .function(name) }
      throw .invalidRequest("Invalid tool_choice.", param: "tool_choice")
    default:
      throw .invalidRequest("Invalid tool_choice.", param: "tool_choice")
    }
  }
}
