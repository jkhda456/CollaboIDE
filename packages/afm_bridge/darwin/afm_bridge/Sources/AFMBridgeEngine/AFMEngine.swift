import AFMBridgeCore
import Foundation
import FoundationModels

/// Apple 온디바이스 모델을 OpenAI Chat Completions 방식으로 호출하는 엔진.
///
/// 요청마다 메시지로부터 `Transcript` 를 재구성해 새 `LanguageModelSession` 을 만든다(무상태).
/// 모든 OS 에서 생성할 수 있으며, Foundation Models 는 macOS/iOS/visionOS 26.4+ 에서만 동작한다
/// (그 이하에서는 status 가 `unsupportedOS`, 호출은 503 에러).
public final class AFMEngine: Sendable {
  public struct Configuration: Sendable {
    /// 동시에 실행할 생성 수. 나머지는 큐에서 대기한다.
    public var maxConcurrentRequests: Int
    /// 컨텍스트 윈도우를 넘으면 오래된 턴부터 잘라낸다.
    public var trimHistory: Bool
    /// `.permissiveContentTransformations` 가드레일 사용 (요약/재작성 등 변환 작업용)
    public var permissiveGuardrails: Bool
    /// 모든 요청의 instructions 앞에 붙는 기본 지시문
    public var defaultInstructions: String?

    public init(
      maxConcurrentRequests: Int = 1,
      trimHistory: Bool = true,
      permissiveGuardrails: Bool = false,
      defaultInstructions: String? = nil
    ) {
      self.maxConcurrentRequests = maxConcurrentRequests
      self.trimHistory = trimHistory
      self.permissiveGuardrails = permissiveGuardrails
      self.defaultInstructions = defaultInstructions
    }
  }

  public let configuration: Configuration
  private let limiter: AsyncLimiter
  /// prewarm 한 세션을 붙잡아 둔다 (LanguageModelSession, 26.4+)
  private let warmSession = Locked<AnyObject?>(nil)

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
    self.limiter = AsyncLimiter(limit: configuration.maxConcurrentRequests)
  }

  /// 이 OS 에서 Foundation Models 를 쓸 수 있는지 (26.4+)
  public static var isSupportedOS: Bool {
    if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) { return true }
    return false
  }

  // MARK: - Status

  public func status(model id: String = AFMModelID.default) -> ModelStatus {
    if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
      return systemStatus(model: id)
    }
    return ModelStatus(
      available: false, reason: .unsupportedOS, contextSize: nil, supportedLanguages: [],
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
  }

  /// 모델을 미리 메모리에 올린다. 첫 응답 지연을 줄이려면 사용자 입력 전에 호출.
  public func prewarm(instructions: String? = nil) {
    guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else { return }
    let model = systemModel(for: AFMModelID.default)
    guard model.isAvailable else { return }
    let session = LanguageModelSession(model: model, instructions: instructions ?? configuration.defaultInstructions)
    session.prewarm()
    warmSession.withLock { $0 = session }
  }

  // MARK: - Chat completions

  /// 비스트리밍 호출. 실패 시 항상 `BridgeError` 를 던진다.
  public func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletion {
    guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else { throw Self.unsupportedOSError }
    do {
      return try await limiter.withPermit { try await self.runCompletion(request) }
    } catch {
      throw ErrorMapping.bridgeError(from: error)
    }
  }

  /// 스트리밍 호출. 스트림 에러는 항상 `BridgeError`.
  /// 첫 청크(role) 전에 발생한 에러는 HTTP 에러 응답으로 돌려줄 수 있다.
  public func streamChatCompletion(_ request: ChatCompletionRequest) -> AsyncThrowingStream<ChatCompletionChunk, any Error>
  {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: ChatCompletionChunk.self)
    let task = Task {
      guard #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) else {
        continuation.finish(throwing: Self.unsupportedOSError)
        return
      }
      do {
        try await limiter.withPermit { try await self.runStream(request, into: continuation) }
        continuation.finish()
      } catch {
        continuation.finish(throwing: ErrorMapping.bridgeError(from: error))
      }
    }
    continuation.onTermination = { _ in task.cancel() }
    return stream
  }

  static var unsupportedOSError: BridgeError {
    let status = ModelStatus(available: false, reason: .unsupportedOS, contextSize: nil, supportedLanguages: [],
      osVersion: "")
    return .modelUnavailable(status.message.en, code: ModelStatus.Reason.unsupportedOS.rawValue)
  }
}

// MARK: - Foundation Models (26.4+)

@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
extension AFMEngine {
  func systemStatus(model id: String) -> ModelStatus {
    let model = systemModel(for: AFMModelID.normalize(id))
    var reason: ModelStatus.Reason?
    switch model.availability {
    case .available:
      reason = nil
    case .unavailable(let unavailable):
      switch unavailable {
      case .deviceNotEligible: reason = .deviceNotEligible
      case .appleIntelligenceNotEnabled: reason = .appleIntelligenceNotEnabled
      case .modelNotReady: reason = .modelNotReady
      @unknown default: reason = .unknown
      }
    }
    let contextSize = model.contextSize
    let info = Self.modelInfo(model)
    return ModelStatus(
      available: reason == nil,
      reason: reason,
      contextSize: contextSize > 0 ? contextSize : nil,
      supportedLanguages: model.supportedLanguages.map(\.minimalIdentifier).sorted(),
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      modelVersion: info.version,
      modelVariant: info.variant,
      modelName: info.name
    )
  }

  /// 모델 세대·변형. 26.4~26.x 는 v2 하나뿐이고, 27+ 는 시스템이 기기에 맞춰 Core / Core Advanced 를 고른다.
  static func modelInfo(_ model: SystemLanguageModel) -> (version: String, variant: String?, name: String) {
    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
      let variant = model.variant
      let id: String? =
        variant == .coreAdvanced3 ? "coreAdvanced3" : (variant == .core3 ? "core3" : nil)
      let name = variant.displayName.isEmpty ? "Apple Foundation Model 3" : variant.displayName
      return ("3", id, name)
    }
    return ("2", nil, "Apple Foundation Model v2")
  }

  func systemModel(for id: String, permissive: Bool? = nil) -> SystemLanguageModel {
    let isPermissive = permissive ?? configuration.permissiveGuardrails
    let guardrails: SystemLanguageModel.Guardrails = isPermissive ? .permissiveContentTransformations : .default
    if id == AFMModelID.contentTagging {
      return SystemLanguageModel(useCase: .contentTagging, guardrails: guardrails)
    }
    return isPermissive ? SystemLanguageModel(useCase: .general, guardrails: guardrails) : .default
  }

  private struct Prepared: @unchecked Sendable {
    let modelID: String
    let model: SystemLanguageModel
    let session: LanguageModelSession
    let prompt: String
    let options: GenerationOptions
    let schema: GenerationSchema?
    let schemaDocument: SchemaDocument?
    let jsonObjectMode: Bool
    let recorder: ToolCallRecorder
    let promptTokens: Int?

    func structuredJSON(_ content: GeneratedContent) -> String {
      let raw = content.jsonString
      guard let schemaDocument, let parsed = try? JSONValue.parse(raw) else { return raw }
      return schemaDocument.reordered(parsed).jsonString
    }
  }

  private func prepare(_ request: ChatCompletionRequest) async throws -> Prepared {
    let modelID = AFMModelID.normalize(request.model)
    let model = systemModel(for: modelID, permissive: request.permissiveGuardrails)
    let currentStatus = status(model: modelID)
    guard currentStatus.available else {
      throw BridgeError.modelUnavailable(
        currentStatus.message.en, code: currentStatus.reason?.rawValue ?? "model_unavailable")
    }

    let plan = try ConversationPlan.make(from: request.messages)

    // 도구
    var activeTools = request.tools
    var forcedToolInstruction: String?
    switch request.toolChoice {
    case .none:
      activeTools = []
    case .function(let name):
      activeTools = request.tools.filter { $0.name == name }
      forcedToolInstruction = "You must call the tool `\(name)`."
    case .required:
      forcedToolInstruction = "You must call one of the available tools."
    case .auto:
      break
    }
    if !plan.replayedToolResults.isEmpty {
      guard !activeTools.isEmpty else {
        throw BridgeError.invalidRequest(
          "Tool results were provided but no tools are enabled for this request.", param: "tools")
      }
      forcedToolInstruction = nil  // 결과를 받은 뒤에는 답변을 허용
    }

    let recorder = ToolCallRecorder(replay: plan.replayedToolResults)
    var toolDefinitions: [Transcript.ToolDefinition] = []
    var proxyTools: [any Tool] = []
    for tool in activeTools {
      let parameters = try SchemaBuilder.generationSchema(from: tool.parameters, name: "\(tool.name)_arguments")
      let description = tool.description ?? tool.name
      toolDefinitions.append(.init(name: tool.name, description: description, parameters: parameters))
      proxyTools.append(
        ProxyTool(name: tool.name, description: description, parameters: parameters, recorder: recorder))
    }

    // 응답 형식
    var schema: GenerationSchema?
    var schemaDocument: SchemaDocument?
    var jsonObjectMode = false
    switch request.responseFormat {
    case .text: break
    case .jsonObject: jsonObjectMode = true
    case .jsonSchema(let name, let json): (schema, schemaDocument) = try SchemaBuilder.build(from: json, name: name)
    }

    // instructions
    var instructionParts = [configuration.defaultInstructions, plan.instructions].compactMap { $0 }
    if let forcedToolInstruction { instructionParts.append(forcedToolInstruction) }
    if jsonObjectMode {
      instructionParts.append("Respond only with a single valid JSON object. Do not include any other text.")
    }

    var entries: [Transcript.Entry] = []
    if !instructionParts.isEmpty || !toolDefinitions.isEmpty {
      let segments: [Transcript.Segment] =
        instructionParts.isEmpty ? [] : [.text(.init(content: instructionParts.joined(separator: "\n\n")))]
      entries.append(.instructions(.init(segments: segments, toolDefinitions: toolDefinitions)))
    }
    let historyStart = entries.count
    entries.append(contentsOf: TranscriptBuilder.entries(from: plan.history))

    // 생성 옵션
    var samplingMode: GenerationOptions.SamplingMode?
    var temperature = request.temperature
    if request.temperature == 0 {
      samplingMode = .greedy
      temperature = nil
    } else if let topP = request.topP {
      samplingMode = .random(probabilityThreshold: topP, seed: request.seed)
    } else if let topK = request.topK {
      samplingMode = .random(top: topK, seed: request.seed)
    } else if let seed = request.seed {
      samplingMode = .random(probabilityThreshold: 1.0, seed: seed)
    }
    var options = GenerationOptions(
      samplingMode: samplingMode, temperature: temperature, maximumResponseTokens: request.maxTokens)
    if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
      switch request.toolChoice {
      case .none: options.toolCallingMode = .disallowed
      case .required, .function:
        if plan.replayedToolResults.isEmpty { options.toolCallingMode = .required }
      case .auto: break
      }
    }

    // 컨텍스트 윈도우 맞추기
    let promptEntry = Transcript.Entry.prompt(.init(segments: [.text(.init(content: plan.prompt))]))
    var promptTokens: Int?
    let contextSize = model.contextSize
    if contextSize > 0, let initialCount = try? await model.tokenCount(for: entries + [promptEntry]) {
      var count = initialCount
      let schemaTokens = (try? await schema.asyncMap { try await model.tokenCount(for: $0) }) ?? 0
      let reserve = request.maxTokens ?? min(1024, contextSize / 4)
      let budget = contextSize - reserve - schemaTokens
      while count > budget, configuration.trimHistory, entries.count > historyStart {
        TranscriptBuilder.dropOldestTurn(from: &entries, historyStart: historyStart)
        count = (try? await model.tokenCount(for: entries + [promptEntry])) ?? count
      }
      if count > contextSize - schemaTokens - 16 {
        throw BridgeError.contextLengthExceeded(
          "This request needs about \(count + schemaTokens) tokens but the on-device model's context window is \(contextSize) tokens."
        )
      }
      promptTokens = count + schemaTokens
    }

    let session = LanguageModelSession(model: model, tools: proxyTools, transcript: Transcript(entries: entries))
    return Prepared(
      modelID: modelID, model: model, session: session, prompt: plan.prompt, options: options, schema: schema,
      schemaDocument: schemaDocument, jsonObjectMode: jsonObjectMode, recorder: recorder, promptTokens: promptTokens)
  }

  private func runCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletion {
    let prepared = try await prepare(request)
    var content: String
    var finishReason = FinishReason.stop
    do {
      if let schema = prepared.schema {
        let response = try await prepared.session.respond(
          to: prepared.prompt, schema: schema, options: prepared.options)
        content = prepared.structuredJSON(response.content)
      } else {
        let response = try await prepared.session.respond(to: prepared.prompt, options: prepared.options)
        content = response.content
        if prepared.jsonObjectMode {
          content = TextCleanup.stripCodeFences(content)
        } else if !request.stop.isEmpty {
          content = StopSequenceFilter.apply(request.stop, to: content).text
        }
      }
    } catch where Self.isToolInterception(error) {
      let calls = await prepared.recorder.intercepted
      guard !calls.isEmpty else { throw error }
      return ChatCompletion(
        model: prepared.modelID, content: nil, toolCalls: calls, finishReason: .toolCalls,
        usage: prepared.promptTokens.map { Usage(promptTokens: $0, completionTokens: 0) })
    }

    let completionTokens = try? await prepared.model.tokenCount(for: content)
    if let max = request.maxTokens, let completionTokens, completionTokens >= max { finishReason = .length }
    return ChatCompletion(
      model: prepared.modelID, content: content, finishReason: finishReason,
      usage: usage(prompt: prepared.promptTokens, completion: completionTokens))
  }

  private func runStream(
    _ request: ChatCompletionRequest,
    into continuation: AsyncThrowingStream<ChatCompletionChunk, any Error>.Continuation
  ) async throws {
    let prepared = try await prepare(request)
    let id = ChatCompletion.makeID()
    let created = ChatCompletion.now()
    func yield(_ delta: ChatCompletionChunk.Delta) {
      continuation.yield(ChatCompletionChunk(id: id, created: created, model: prepared.modelID, delta: delta))
    }

    yield(.role)
    var fullText = ""
    var finishReason = FinishReason.stop
    do {
      if prepared.schema != nil || prepared.jsonObjectMode {
        // 부분 JSON 은 prefix-stable 하지 않으므로 완성 후 한 번에 보낸다
        if let schema = prepared.schema {
          fullText = prepared.structuredJSON(
            try await prepared.session.respond(to: prepared.prompt, schema: schema, options: prepared.options).content)
        } else {
          fullText = TextCleanup.stripCodeFences(
            try await prepared.session.respond(to: prepared.prompt, options: prepared.options).content)
        }
        yield(.content(fullText))
      } else {
        var differ = SnapshotDiffer()
        var filter = StopSequenceFilter(stops: request.stop)
        for try await snapshot in prepared.session.streamResponse(to: prepared.prompt, options: prepared.options) {
          let output = filter.feed(differ.delta(for: snapshot.content))
          if !output.isEmpty {
            fullText += output
            yield(.content(output))
          }
          if filter.isStopped { break }
        }
        let rest = filter.flush()
        if !rest.isEmpty {
          fullText += rest
          yield(.content(rest))
        }
      }
    } catch where Self.isToolInterception(error) {
      let calls = await prepared.recorder.intercepted
      guard !calls.isEmpty else { throw error }
      yield(.toolCalls(calls))
      yield(.finish(.toolCalls))
      if request.includeUsage, let promptTokens = prepared.promptTokens {
        yield(.usage(Usage(promptTokens: promptTokens, completionTokens: 0)))
      }
      return
    }

    let completionTokens = try? await prepared.model.tokenCount(for: fullText)
    if let max = request.maxTokens, let completionTokens, completionTokens >= max { finishReason = .length }
    yield(.finish(finishReason))
    if request.includeUsage, let usage = usage(prompt: prepared.promptTokens, completion: completionTokens) {
      yield(.usage(usage))
    }
  }

  private func usage(prompt: Int?, completion: Int?) -> Usage? {
    guard let prompt, let completion else { return nil }
    return Usage(promptTokens: prompt, completionTokens: completion)
  }

  private static func isToolInterception(_ error: any Error) -> Bool {
    if error is ToolCallIntercepted { return true }
    if let error = error as? LanguageModelSession.ToolCallError { return error.underlyingError is ToolCallIntercepted }
    return false
  }
}

extension Optional {
  fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let self else { return nil }
    return try await transform(self)
  }
}
