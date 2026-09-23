import AFMBridgeCore
import Foundation
import FoundationModels

/// 모델이 도구를 호출하면 실행하지 않고 가로채는 에러.
struct ToolCallIntercepted: Error {}

/// 도구 호출 가로채기 + replay 결과 제공.
actor ToolCallRecorder {
  private var replay: [(result: ReplayedToolResult, consumed: Bool)]
  private(set) var intercepted: [ToolCall] = []

  init(replay: [ReplayedToolResult]) {
    self.replay = replay.map { ($0, false) }
  }

  /// replay 할 결과가 있으면 돌려주고, 없으면 호출을 기록하고 nil.
  func resolve(name: String, arguments: String) -> String? {
    let canonical = (try? JSONValue.parse(arguments))?.canonicalString ?? arguments
    // 1) 이름 + 인자 일치  2) 이름만 일치 (모델이 인자를 조금 다르게 재생성한 경우)
    let exact = replay.firstIndex {
      !$0.consumed && $0.result.name == name
        && ((try? JSONValue.parse($0.result.arguments))?.canonicalString ?? $0.result.arguments) == canonical
    }
    if let index = exact ?? replay.firstIndex(where: { !$0.consumed && $0.result.name == name }) {
      replay[index].consumed = true
      return replay[index].result.output
    }
    intercepted.append(ToolCall(id: Self.makeCallID(), name: name, arguments: arguments))
    return nil
  }

  static func makeCallID() -> String {
    "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
  }
}

/// OpenAI 함수 정의를 FM `Tool` 로 노출하는 프록시.
@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
struct ProxyTool: Tool {
  typealias Arguments = GeneratedContent
  typealias Output = String

  let name: String
  let description: String
  let parameters: GenerationSchema
  let recorder: ToolCallRecorder

  @concurrent
  func call(arguments: GeneratedContent) async throws -> String {
    if let output = await recorder.resolve(name: name, arguments: arguments.jsonString) {
      return output
    }
    // 병렬 도구 호출이 모두 기록될 수 있도록 잠시 대기 후 중단
    try? await Task.sleep(for: .milliseconds(30))
    throw ToolCallIntercepted()
  }
}
