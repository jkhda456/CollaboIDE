import AFMBridgeCore
import Foundation
import FoundationModels

/// OpenAI 메시지 → `Transcript.Entry`
@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
enum TranscriptBuilder {
  static func entries(from messages: [ChatMessage]) -> [Transcript.Entry] {
    var toolNames: [String: String] = [:]
    var entries: [Transcript.Entry] = []

    for message in messages {
      switch message.role {
      case .user:
        entries.append(.prompt(.init(segments: [text(message.content ?? "")])))

      case .assistant:
        if let content = message.content, !content.isEmpty {
          entries.append(.response(.init(assetIDs: [], segments: [text(content)])))
        }
        if !message.toolCalls.isEmpty {
          let calls = message.toolCalls.map { call in
            toolNames[call.id] = call.name
            return Transcript.ToolCall(id: call.id, toolName: call.name, arguments: generatedContent(call.arguments))
          }
          entries.append(.toolCalls(.init(calls)))
        }

      case .tool:
        let id = message.toolCallID ?? UUID().uuidString
        let name = toolNames[id] ?? message.name ?? "tool"
        entries.append(.toolOutput(.init(id: id, toolName: name, segments: [text(message.content ?? "")])))

      case .system, .developer:
        break  // instructions 로 합쳐짐
      }
    }
    return entries
  }

  /// 가장 오래된 턴(prompt 부터 다음 prompt 직전까지)을 제거한다.
  static func dropOldestTurn(from entries: inout [Transcript.Entry], historyStart: Int) {
    guard entries.count > historyStart else { return }
    var end = historyStart + 1
    while end < entries.count {
      if case .prompt = entries[end] { break }
      end += 1
    }
    entries.removeSubrange(historyStart..<end)
  }

  static func text(_ content: String) -> Transcript.Segment {
    .text(.init(content: content))
  }

  static func generatedContent(_ json: String) -> GeneratedContent {
    if let content = try? GeneratedContent(json: json) { return content }
    return (try? GeneratedContent(json: "{}")) ?? GeneratedContent(json)
  }
}
