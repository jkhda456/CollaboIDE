import AFMBridgeCore
import AFMBridgeEngine
import Foundation
import Network

/// 로컬 OpenAI 호환 HTTP 서버.
///
/// - `GET  /health`              모델 상태 (available, reason, 안내 문구, context_size …)
/// - `GET  /v1/models`           모델 목록
/// - `GET  /v1/models/{id}`
/// - `POST /v1/chat/completions` (stream 지원)
public final class AFMServer: Sendable {
  public struct Configuration: Sendable {
    public var host: String
    /// 0 이면 OS 가 빈 포트를 할당한다 (앱 내장 시 권장)
    public var port: UInt16
    /// 설정하면 `Authorization: Bearer <apiKey>` 필요 (/health 제외)
    public var apiKey: String?
    /// 브라우저에서 호출할 수 있도록 CORS 허용 (기본 꺼짐)
    public var allowCORS: Bool

    public init(host: String = "127.0.0.1", port: UInt16 = 11435, apiKey: String? = nil, allowCORS: Bool = false) {
      self.host = host
      self.port = port
      self.apiKey = apiKey
      self.allowCORS = allowCORS
    }
  }

  public let engine: AFMEngine
  public let configuration: Configuration
  private let listener = Locked<NWListener?>(nil)
  private let queue = DispatchQueue(label: "afmbridge.server")
  private let logger: (@Sendable (String) -> Void)?

  public init(engine: AFMEngine, configuration: Configuration = .init(), logger: (@Sendable (String) -> Void)? = nil) {
    self.engine = engine
    self.configuration = configuration
    self.logger = logger
  }

  /// 서버를 시작하고 실제 바인딩된 포트를 돌려준다.
  @discardableResult
  public func start() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    let port = NWEndpoint.Port(rawValue: configuration.port) ?? .any
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(configuration.host), port: port)
    let listener = try NWListener(using: parameters)

    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { return connection.cancel() }
      connection.start(queue: self.queue)
      Task { await self.handle(HTTPConnection(connection: connection)) }
    }

    let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let resumed = Locked(false)
      listener.stateUpdateHandler = { state in
        let shouldResume = resumed.withLock { done -> Bool in
          switch state {
          case .ready, .failed, .cancelled:
            defer { done = true }
            return !done
          default:
            return false
          }
        }
        guard shouldResume else { return }
        switch state {
        case .ready: continuation.resume(returning: listener.port?.rawValue ?? 0)
        case .failed(let error): continuation.resume(throwing: error)
        default: continuation.resume(throwing: CancellationError())
        }
      }
      listener.start(queue: queue)
    }
    self.listener.withLock { $0 = listener }
    logger?("AFMBridge server listening on http://\(configuration.host):\(boundPort)")
    return boundPort
  }

  public func stop() {
    listener.withLock {
      $0?.cancel()
      $0 = nil
    }
  }

  public var isRunning: Bool { listener.withLock { $0 != nil } }

  // MARK: - Handling

  private func handle(_ connection: HTTPConnection) async {
    defer { connection.close() }
    let request: HTTPRequest
    do {
      request = try await connection.readRequest()
    } catch HTTPParseError.tooLarge {
      try? await connection.send(errorResponse(BridgeError(status: 413, type: "invalid_request_error",
        message: "Request too large.")).serialized())
      return
    } catch HTTPParseError.malformed {
      try? await connection.send(errorResponse(.invalidRequest("Malformed HTTP request.")).serialized())
      logger?("malformed HTTP request -> 400")
      return
    } catch {
      return  // 연결이 닫힘
    }

    let started = Date()
    let status = await route(request, connection: connection)
    logger?(String(format: "%@ %@ -> %d (%.2fs)", request.method, request.path, status,
      Date().timeIntervalSince(started)))
  }

  /// 응답을 보내고 상태 코드를 돌려준다.
  private func route(_ request: HTTPRequest, connection: HTTPConnection) async -> Int {
    func send(_ response: HTTPResponse) async -> Int {
      try? await connection.send(response.serialized())
      return response.status
    }

    if let rejection = securityCheck(request) { return await send(errorResponse(rejection)) }

    if request.method == "OPTIONS" {
      return await send(HTTPResponse(status: 204, headers: corsHeaders + [
        ("Access-Control-Allow-Methods", "GET, POST, OPTIONS"),
        ("Access-Control-Allow-Headers", "Authorization, Content-Type"),
      ], body: Data()))
    }

    let path = request.path.hasSuffix("/") && request.path.count > 1 ? String(request.path.dropLast()) : request.path
    switch (request.method, path) {
    case ("GET", "/health"), ("GET", "/"):
      return await send(.json(200, engine.status().json.jsonString, extraHeaders: corsHeaders))

    case ("GET", "/v1/models"):
      return await send(.json(200, ModelList.json().jsonString, extraHeaders: corsHeaders))

    case ("GET", _) where path.hasPrefix("/v1/models/"):
      let id = String(path.dropFirst("/v1/models/".count))
      guard AFMModelID.all.contains(id) else {
        return await send(errorResponse(.notFound("The model '\(id)' does not exist.")))
      }
      return await send(.json(200, ModelList.model(id: id).jsonString, extraHeaders: corsHeaders))

    case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
      return await chatCompletions(request, connection: connection)

    case (_, "/v1/chat/completions"), (_, "/v1/models"), (_, "/health"):
      return await send(errorResponse(BridgeError(status: 405, type: "invalid_request_error",
        message: "Method not allowed.")))

    default:
      return await send(errorResponse(.notFound("Unknown endpoint \(request.method) \(request.path).")))
    }
  }

  private func chatCompletions(_ http: HTTPRequest, connection: HTTPConnection) async -> Int {
    let request: ChatCompletionRequest
    do {
      let json = try JSONValue.parse(http.body)
      request = try ChatCompletionRequest.parse(json)
    } catch let error as BridgeError {
      try? await connection.send(errorResponse(error).serialized())
      return error.status
    } catch {
      let error = BridgeError.invalidRequest("Invalid JSON body: \(error)")
      try? await connection.send(errorResponse(error).serialized())
      return error.status
    }

    if !request.stream {
      do {
        let completion = try await engine.chatCompletion(request)
        try? await connection.send(HTTPResponse.json(200, completion.json.jsonString, extraHeaders: corsHeaders)
          .serialized())
        return 200
      } catch {
        let error = error as? BridgeError ?? .server("\(error)")
        try? await connection.send(errorResponse(error).serialized())
        return error.status
      }
    }

    // 스트리밍: 첫 청크 전에 실패하면 일반 HTTP 에러로 응답
    var iterator = engine.streamChatCompletion(request).makeAsyncIterator()
    let first: ChatCompletionChunk?
    do {
      first = try await iterator.next()
    } catch {
      let error = error as? BridgeError ?? .server("\(error)")
      try? await connection.send(errorResponse(error).serialized())
      return error.status
    }

    do {
      try await connection.send(HTTPResponse.streamHead(extraHeaders: corsHeaders))
      if let first { try await connection.send(Data(SSE.event(first.json).utf8)) }
      while let chunk = try await nextChunk(&iterator, connection: connection) {
        try await connection.send(Data(SSE.event(chunk.json).utf8))
      }
      try await connection.send(Data(SSE.done.utf8))
    } catch {
      // 클라이언트 연결 끊김이면 iterator 해제 → 생성 취소
    }
    return 200
  }

  /// 스트림 중간 에러는 SSE error 이벤트로 보내고 종료한다.
  private func nextChunk(
    _ iterator: inout AsyncThrowingStream<ChatCompletionChunk, any Error>.Iterator, connection: HTTPConnection
  ) async throws -> ChatCompletionChunk? {
    do {
      return try await iterator.next()
    } catch {
      let error = error as? BridgeError ?? .server("\(error)")
      try await connection.send(Data(SSE.event(error.json).utf8))
      return nil
    }
  }

  // MARK: - Security

  private var corsHeaders: [(String, String)] {
    configuration.allowCORS ? [("Access-Control-Allow-Origin", "*")] : []
  }

  private func securityCheck(_ request: HTTPRequest) -> BridgeError? {
    // DNS rebinding 방지: 루프백 바인딩일 때 Host 헤더가 로컬이어야 한다
    if isLoopback(configuration.host), let host = request.headers["host"] {
      let hostname = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) :
        String(host.split(separator: ":").first ?? "")
      if !["localhost", "127.0.0.1", "::1"].contains(hostname.lowercased()) {
        return BridgeError(status: 403, type: "invalid_request_error", message: "Forbidden host.")
      }
    }
    // 브라우저 요청은 CORS 를 명시적으로 켠 경우에만 허용
    if !configuration.allowCORS, let origin = request.headers["origin"], !origin.isEmpty, origin != "null" {
      return BridgeError(status: 403, type: "invalid_request_error",
        message: "Cross-origin requests are disabled. Start the server with CORS enabled.")
    }
    if let apiKey = configuration.apiKey, request.path != "/health", request.method != "OPTIONS" {
      guard request.headers["authorization"] == "Bearer \(apiKey)" else { return .unauthorized() }
    }
    return nil
  }

  private func isLoopback(_ host: String) -> Bool {
    ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
  }

  private func errorResponse(_ error: BridgeError) -> HTTPResponse {
    .json(error.status, error.json.jsonString, extraHeaders: corsHeaders)
  }
}
