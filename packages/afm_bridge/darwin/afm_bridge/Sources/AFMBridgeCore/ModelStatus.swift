/// 모델 사용 가능 상태 + 사람이 읽을 안내 문구.
///
/// Apple 은 availability 이유 코드만 주고 설정 안내나 진행률을 제공하지 않으므로
/// 브리지가 이유별 안내를 채워 앱/클라이언트에 전달한다.
public struct ModelStatus: Sendable, Equatable {
  public enum Reason: String, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    case unsupportedOS
    case unknown
  }

  public var available: Bool
  public var reason: Reason?
  public var contextSize: Int?
  public var supportedLanguages: [String]
  public var osVersion: String
  /// 온디바이스 모델 세대. "2" (iOS/macOS 26.4+), "3" (27+ AFM 3). OS 미지원이면 nil.
  public var modelVersion: String?
  /// 27+ 에서 시스템이 고른 변형: "core3"(3B) / "coreAdvanced3"(20B sparse). 26 에는 변형이 없어 nil.
  public var modelVariant: String?
  /// 사람이 읽을 모델 이름(예: "Apple Foundation Model v2", 27 은 시스템의 displayName).
  public var modelName: String?

  public init(
    available: Bool, reason: Reason?, contextSize: Int?, supportedLanguages: [String], osVersion: String,
    modelVersion: String? = nil, modelVariant: String? = nil, modelName: String? = nil
  ) {
    self.available = available
    self.reason = reason
    self.contextSize = contextSize
    self.supportedLanguages = supportedLanguages
    self.osVersion = osVersion
    self.modelVersion = modelVersion
    self.modelVariant = modelVariant
    self.modelName = modelName
  }

  public var message: (ko: String, en: String) {
    switch reason {
    case nil:
      return ("사용 가능합니다.", "The on-device model is ready.")
    case .deviceNotEligible?:
      return (
        "이 기기는 Apple Intelligence 를 지원하지 않습니다. (Apple Silicon Mac, iPhone 15 Pro 이상 등 필요)",
        "This device does not support Apple Intelligence."
      )
    case .appleIntelligenceNotEnabled?:
      return (
        "Apple Intelligence 가 꺼져 있습니다. 시스템 설정 > Apple Intelligence & Siri 에서 켜 주세요.",
        "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
      )
    case .modelNotReady?:
      return (
        "모델을 준비(다운로드) 중입니다. 잠시 후 다시 시도해 주세요. 전원과 Wi-Fi 연결을 유지하면 빨라집니다.",
        "The model is still being prepared (downloading). Try again shortly."
      )
    case .unsupportedOS?:
      return ("macOS/iOS 26.4 이상이 필요합니다.", "Requires macOS/iOS 26.4 or later.")
    case .unknown?:
      return ("알 수 없는 이유로 모델을 사용할 수 없습니다.", "The model is unavailable for an unknown reason.")
    }
  }

  public var json: JSONValue {
    var object: JSONObject = [
      "available": .bool(available),
      "reason": reason.map { .string($0.rawValue) } ?? .null,
      "message": .string(message.en),
      "message_ko": .string(message.ko),
      "context_size": contextSize.map { .number(Double($0)) } ?? .null,
      "supported_languages": .array(supportedLanguages.map(JSONValue.string)),
      "os_version": .string(osVersion),
      "model_version": modelVersion.map(JSONValue.string) ?? .null,
      "model_variant": modelVariant.map(JSONValue.string) ?? .null,
      "model_name": modelName.map(JSONValue.string) ?? .null,
    ]
    object["bridge_version"] = .string(AFMBridgeInfo.version)
    return .object(object)
  }
}

public enum ModelList {
  public static func json(created: Int = 0) -> JSONValue {
    ["object": "list", "data": .array(AFMModelID.all.map { model(id: $0, created: created) })]
  }

  public static func model(id: String, created: Int = 0) -> JSONValue {
    ["id": .string(id), "object": "model", "created": .number(Double(created)), "owned_by": "apple"]
  }
}
