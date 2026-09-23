import Foundation
import Network

struct HTTPRequest: Sendable {
  var method: String
  var path: String
  var query: String?
  var headers: [String: String]  // 소문자 키
  var body: Data
}

struct HTTPResponse: Sendable {
  var status: Int
  var headers: [(String, String)]
  var body: Data

  static func json(_ status: Int, _ body: String, extraHeaders: [(String, String)] = []) -> HTTPResponse {
    HTTPResponse(
      status: status, headers: [("Content-Type", "application/json; charset=utf-8")] + extraHeaders,
      body: Data(body.utf8))
  }

  func serialized() -> Data {
    var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
  }

  static func streamHead(extraHeaders: [(String, String)]) -> Data {
    var head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: text/event-stream; charset=utf-8\r\n"
    head += "Cache-Control: no-cache\r\n"
    head += "Connection: close\r\n"
    head += "X-Accel-Buffering: no\r\n"
    for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    return Data(head.utf8)
  }

  static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 413: "Payload Too Large"
    case 429: "Too Many Requests"
    case 499: "Client Closed Request"
    case 500: "Internal Server Error"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    default: "Status"
    }
  }
}

enum HTTPParseError: Error {
  case malformed
  case tooLarge
  case closed
}

/// NWConnection 위의 최소 HTTP/1.1 (요청 1개 처리 후 연결 종료)
struct HTTPConnection: @unchecked Sendable {
  let connection: NWConnection
  static let maxHeaderBytes = 64 * 1024
  static let maxBodyBytes = 16 * 1024 * 1024

  func readRequest() async throws -> HTTPRequest {
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      guard let chunk = try await receive() else { throw HTTPParseError.closed }
      buffer.append(chunk)
      headerEnd = buffer.range(of: separator)
      if headerEnd == nil, buffer.count > Self.maxHeaderBytes { throw HTTPParseError.tooLarge }
    }
    guard let headerEnd, let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
      throw HTTPParseError.malformed
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { throw HTTPParseError.malformed }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    var body = Data(buffer[headerEnd.upperBound...])
    // curl 등은 큰 본문 전에 `Expect: 100-continue` 로 확인을 기다린다
    if headers["expect"]?.lowercased() == "100-continue" {
      try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
    }

    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      // Dart HttpClient 등은 Content-Length 없이 chunked 로 본문을 보낸다
      body = try await readChunkedBody(initial: body)
    } else {
      let contentLength = Int(headers["content-length"] ?? "0") ?? 0
      guard contentLength >= 0 else { throw HTTPParseError.malformed }
      guard contentLength <= Self.maxBodyBytes else { throw HTTPParseError.tooLarge }
      while body.count < contentLength {
        guard let chunk = try await receive() else { throw HTTPParseError.closed }
        body.append(chunk)
      }
      body = Data(body.prefix(contentLength))
    }

    let target = String(requestLine[1])
    let parts = target.split(separator: "?", maxSplits: 1)
    return HTTPRequest(
      method: String(requestLine[0]).uppercased(),
      path: String(parts.first ?? "/"),
      query: parts.count > 1 ? String(parts[1]) : nil,
      headers: headers,
      body: body
    )
  }

  /// `Transfer-Encoding: chunked` 본문 디코딩 (chunk extension, trailer 는 무시)
  private func readChunkedBody(initial: Data) async throws -> Data {
    var buffer = initial
    var body = Data()
    let crlf = Data("\r\n".utf8)

    func fill(until condition: (Data) -> Bool) async throws {
      while !condition(buffer) {
        guard buffer.count <= Self.maxBodyBytes + Self.maxHeaderBytes else { throw HTTPParseError.tooLarge }
        guard let chunk = try await receive() else { throw HTTPParseError.closed }
        buffer.append(chunk)
      }
    }

    while true {
      try await fill { $0.range(of: crlf) != nil }
      let lineEnd = buffer.range(of: crlf)!
      let sizeLine = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
      let sizeText = sizeLine.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
      guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPParseError.malformed }
      buffer = Data(buffer[lineEnd.upperBound...])

      if size == 0 {
        // trailer 헤더들 + 빈 줄
        try await fill { $0.starts(with: crlf) || $0.range(of: Data("\r\n\r\n".utf8)) != nil }
        return body
      }
      guard body.count + size <= Self.maxBodyBytes else { throw HTTPParseError.tooLarge }
      try await fill { $0.count >= size + 2 }
      body.append(buffer.prefix(size))
      guard buffer.dropFirst(size).starts(with: crlf) else { throw HTTPParseError.malformed }
      buffer = Data(buffer.dropFirst(size + 2))
    }
  }

  func receive() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: Data())
        }
      }
    }
  }

  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }

  func close() {
    connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
    connection.cancel()
  }
}
