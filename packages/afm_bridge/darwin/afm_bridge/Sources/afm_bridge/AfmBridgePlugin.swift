import AFMBridgeCore
import AFMBridgeEngine
import AFMBridgeServer
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Flutter ↔ AFMBridge.
///
/// - MethodChannel `afm_bridge`: status / configure / prewarm / chatCompletions / streamStart / streamCancel /
///   serverStart / serverStop. 요청·응답은 OpenAI 형식 JSON 문자열.
/// - EventChannel `afm_bridge/stream`: 모든 스트림 이벤트를 `{id, event, data}` 로 전달
///   (event: "chunk" | "error" | "done").
public class AfmBridgePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var engine = AFMEngine()
  private var server: AFMServer?
  private var serverPort: Int?
  private var streams: [String: Task<Void, Never>] = [:]
  private var eventSink: FlutterEventSink?

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let instance = AfmBridgePlugin()
    let channel = FlutterMethodChannel(name: "afm_bridge", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(name: "afm_bridge/stream", binaryMessenger: messenger)
    events.setStreamHandler(instance)
  }

  // MARK: - FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  // MARK: - Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "status":
      result(engine.status(model: args["model"] as? String ?? AFMModelID.default).json.jsonString)

    case "configure":
      configure(args)
      result(nil)

    case "prewarm":
      engine.prewarm(instructions: args["instructions"] as? String)
      result(nil)

    case "chatCompletions":
      chatCompletions(args["request"] as? String, result: result)

    case "streamStart":
      guard let id = args["id"] as? String else {
        return result(FlutterError(code: "invalid_argument", message: "id is required", details: nil))
      }
      startStream(id: id, requestJSON: args["request"] as? String)
      result(nil)

    case "streamCancel":
      if let id = args["id"] as? String { streams[id]?.cancel() }
      result(nil)

    case "serverStart":
      startServer(args, result: result)

    case "serverStop":
      server?.stop()
      server = nil
      serverPort = nil
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func configure(_ args: [String: Any]) {
    var configuration = AFMEngine.Configuration()
    if let value = args["maxConcurrentRequests"] as? Int { configuration.maxConcurrentRequests = value }
    if let value = args["trimHistory"] as? Bool { configuration.trimHistory = value }
    if let value = args["permissiveGuardrails"] as? Bool { configuration.permissiveGuardrails = value }
    if let value = args["defaultInstructions"] as? String { configuration.defaultInstructions = value }
    engine = AFMEngine(configuration: configuration)
  }

  private func parse(_ json: String?) -> Result<ChatCompletionRequest, BridgeError> {
    guard let json else { return .failure(.invalidRequest("request is required")) }
    do {
      return .success(try ChatCompletionRequest.parse(try JSONValue.parse(json)))
    } catch let error as BridgeError {
      return .failure(error)
    } catch {
      return .failure(.invalidRequest("Invalid JSON: \(error)"))
    }
  }

  private static func flutterError(_ error: BridgeError) -> FlutterError {
    FlutterError(code: error.code ?? error.type, message: error.message, details: errorJSON(error))
  }

  private static func errorJSON(_ error: BridgeError) -> String {
    guard case .object(var root) = error.json, case .object(var inner)? = root["error"] else {
      return error.json.jsonString
    }
    inner["status"] = .number(Double(error.status))
    root["error"] = .object(inner)
    return JSONValue.object(root).jsonString
  }

  private func chatCompletions(_ json: String?, result: @escaping FlutterResult) {
    var request: ChatCompletionRequest
    switch parse(json) {
    case .failure(let error): return result(Self.flutterError(error))
    case .success(let value): request = value
    }
    request.stream = false
    let engine = engine
    Task {
      do {
        let completion = try await engine.chatCompletion(request).json.jsonString
        await MainActor.run { result(completion) }
      } catch {
        let bridgeError = error as? BridgeError ?? .server("\(error)")
        await MainActor.run { result(Self.flutterError(bridgeError)) }
      }
    }
  }

  private func startStream(id: String, requestJSON: String?) {
    let parsed = parse(requestJSON)
    let engine = engine
    let task = Task { [weak self] in
      var request: ChatCompletionRequest
      switch parsed {
      case .failure(let error):
        await self?.emit(id: id, event: "error", data: Self.errorJSON(error))
        return
      case .success(let value):
        request = value
      }
      request.stream = true
      do {
        for try await chunk in engine.streamChatCompletion(request) {
          await self?.emit(id: id, event: "chunk", data: chunk.json.jsonString)
        }
        await self?.emit(id: id, event: "done", data: nil)
      } catch {
        await self?.emit(id: id, event: "error", data: Self.errorJSON(error as? BridgeError ?? .server("\(error)")))
      }
    }
    streams[id] = task
  }

  @MainActor
  private func emit(id: String, event: String, data: String?) {
    eventSink?(["id": id, "event": event, "data": data.map { $0 as Any } ?? NSNull()])
    if event != "chunk" { streams[id] = nil }
  }

  private func startServer(_ args: [String: Any], result: @escaping FlutterResult) {
    if server != nil, let serverPort {
      return result(serverPort)
    }
    let configuration = AFMServer.Configuration(
      host: args["host"] as? String ?? "127.0.0.1",
      port: UInt16(args["port"] as? Int ?? 0),
      apiKey: args["apiKey"] as? String,
      allowCORS: args["allowCORS"] as? Bool ?? false
    )
    let server = AFMServer(engine: engine, configuration: configuration)
    Task {
      do {
        let port = try await server.start()
        await MainActor.run {
          self.server = server
          self.serverPort = Int(port)
          result(Int(port))
        }
      } catch {
        await MainActor.run {
          result(FlutterError(code: "server_start_failed", message: "\(error)", details: nil))
        }
      }
    }
  }
}
