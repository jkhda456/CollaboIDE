import AFMBridgeCore
import Foundation
import FoundationModels

@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
enum ErrorMapping {
  static func bridgeError(from error: any Error) -> BridgeError {
    if let error = error as? BridgeError { return error }
    if error is CancellationError { return .cancelled }

    if let error = error as? LanguageModelSession.ToolCallError {
      return bridgeError(from: error.underlyingError)
    }

    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
      if let mapped = mapOS27(error) { return mapped }
    }

    if let error = error as? LanguageModelSession.GenerationError {
      switch error {
      case .exceededContextWindowSize:
        return .contextLengthExceeded(
          "The conversation exceeds the on-device model's context window. Shorten the messages.")
      case .assetsUnavailable:
        return .modelUnavailable("Model assets are unavailable (still downloading or removed).")
      case .guardrailViolation:
        return .contentFilter("The request or response was blocked by Apple's safety guardrails.")
      case .unsupportedGuide:
        return .invalidRequest("The JSON schema uses a constraint the model does not support.", code: "invalid_schema")
      case .unsupportedLanguageOrLocale:
        return .invalidRequest("The language or locale is not supported by the on-device model.",
          code: "unsupported_language")
      case .decodingFailure:
        return .server("The model output could not be decoded into the requested structure.")
      case .rateLimited:
        return .rateLimited("The on-device model is rate limited (background or low-power state). Retry shortly.")
      case .concurrentRequests:
        return .rateLimited("The model is busy with another request.")
      case .refusal:
        return .contentFilter("The model refused to answer this request.")
      @unknown default:
        return .server(error.localizedDescription)
      }
    }

    return .server(String(describing: error))
  }

  @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
  private static func mapOS27(_ error: any Error) -> BridgeError? {
    if let error = error as? LanguageModelError {
      switch error {
      case .contextSizeExceeded:
        return .contextLengthExceeded(
          "The conversation exceeds the on-device model's context window. Shorten the messages.")
      case .rateLimited:
        return .rateLimited("The model is rate limited. Retry shortly.")
      case .refusal:
        return .contentFilter("The model refused to answer this request.")
      case .guardrailViolation:
        return .contentFilter("The request or response was blocked by Apple's safety guardrails.")
      case .timeout:
        return .timeout("The model timed out.")
      case .unsupportedLanguageOrLocale:
        return .invalidRequest("The language or locale is not supported by the on-device model.",
          code: "unsupported_language")
      case .unsupportedGenerationGuide:
        return .invalidRequest("The JSON schema uses a constraint the model does not support.", code: "invalid_schema")
      default:
        return .server(String(describing: error))
      }
    }
    if let error = error as? LanguageModelSession.Error {
      switch error {
      case .concurrentRequests: return .rateLimited("The model is busy with another request.")
      default: return .server(String(describing: error))
      }
    }
    if error is SystemLanguageModel.Error {
      return .modelUnavailable("Model assets are unavailable (still downloading or removed).")
    }
    return nil
  }
}
