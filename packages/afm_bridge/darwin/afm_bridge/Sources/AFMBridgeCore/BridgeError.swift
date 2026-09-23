/// OpenAI 호환 에러. HTTP 상태 코드와 `{"error": {...}}` 본문으로 변환된다.
public struct BridgeError: Error, Sendable, Equatable, CustomStringConvertible {
  public var status: Int
  public var type: String
  public var code: String?
  public var param: String?
  public var message: String

  public init(status: Int, type: String, code: String? = nil, param: String? = nil, message: String) {
    self.status = status
    self.type = type
    self.code = code
    self.param = param
    self.message = message
  }

  public var description: String { "[\(status) \(code ?? type)] \(message)" }

  public var json: JSONValue {
    var error: JSONObject = [
      "message": .string(message),
      "type": .string(type),
    ]
    error["param"] = param.map(JSONValue.string) ?? .null
    error["code"] = code.map(JSONValue.string) ?? .null
    return ["error": .object(error)]
  }
}

extension BridgeError {
  public static func invalidRequest(_ message: String, param: String? = nil, code: String? = nil) -> BridgeError {
    BridgeError(status: 400, type: "invalid_request_error", code: code, param: param, message: message)
  }

  public static func notFound(_ message: String) -> BridgeError {
    BridgeError(status: 404, type: "invalid_request_error", code: "not_found", message: message)
  }

  public static func unauthorized(_ message: String = "Invalid API key.") -> BridgeError {
    BridgeError(status: 401, type: "authentication_error", code: "invalid_api_key", message: message)
  }

  public static func contextLengthExceeded(_ message: String) -> BridgeError {
    BridgeError(status: 400, type: "invalid_request_error", code: "context_length_exceeded", message: message)
  }

  public static func contentFilter(_ message: String) -> BridgeError {
    BridgeError(status: 400, type: "invalid_request_error", code: "content_filter", message: message)
  }

  public static func rateLimited(_ message: String) -> BridgeError {
    BridgeError(status: 429, type: "rate_limit_error", code: "rate_limited", message: message)
  }

  public static func modelUnavailable(_ message: String, code: String = "model_unavailable") -> BridgeError {
    BridgeError(status: 503, type: "server_error", code: code, message: message)
  }

  public static func server(_ message: String) -> BridgeError {
    BridgeError(status: 500, type: "server_error", code: "internal_error", message: message)
  }

  public static func timeout(_ message: String) -> BridgeError {
    BridgeError(status: 504, type: "server_error", code: "timeout", message: message)
  }

  public static let cancelled = BridgeError(
    status: 499, type: "server_error", code: "cancelled", message: "The request was cancelled.")
}
