import Foundation

/// 키 순서를 보존하는 JSON 값.
///
/// JSON Schema 의 `properties` 순서는 생성 순서에 영향을 주므로
/// Foundation 의 `JSONDecoder`/`JSONSerialization`(순서 비보존) 대신 자체 파서를 사용한다.
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)
}

/// 삽입 순서를 보존하는 JSON 객체.
public struct JSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral {
  public private(set) var entries: [(key: String, value: JSONValue)] = []

  public init() {}

  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    for (key, value) in elements { self[key] = value }
  }

  public var keys: [String] { entries.map(\.key) }
  public var isEmpty: Bool { entries.isEmpty }

  public subscript(key: String) -> JSONValue? {
    get { entries.first(where: { $0.key == key })?.value }
    set {
      if let index = entries.firstIndex(where: { $0.key == key }) {
        if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
      } else if let newValue {
        entries.append((key, newValue))
      }
    }
  }

  public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
    lhs.entries.count == rhs.entries.count
      && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
  }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    var object = JSONObject()
    for (key, value) in elements { object[key] = value }
    self = .object(object)
  }
}

// MARK: - Accessors

extension JSONValue {
  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var doubleValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var intValue: Int? {
    if case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 { return Int(value) }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var objectValue: JSONObject? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
  public let message: String
  public let offset: Int
  public var description: String { "JSON parse error at \(offset): \(message)" }
}

extension JSONValue {
  public static func parse(_ string: String) throws -> JSONValue {
    try parse(Data(string.utf8))
  }

  public static func parse(_ data: Data) throws -> JSONValue {
    var parser = JSONParser(bytes: [UInt8](data))
    return try parser.parseDocument()
  }
}

private struct JSONParser {
  let bytes: [UInt8]
  var index = 0
  var depth = 0

  init(bytes: [UInt8]) { self.bytes = bytes }

  mutating func parseDocument() throws -> JSONValue {
    // UTF-8 BOM
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    skipWhitespace()
    let value = try parseValue()
    skipWhitespace()
    guard index == bytes.count else { throw error("unexpected trailing characters") }
    return value
  }

  func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

  mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  mutating func parseValue() throws -> JSONValue {
    guard index < bytes.count else { throw error("unexpected end of input") }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try parseObject()
    case UInt8(ascii: "["): return try parseArray()
    case UInt8(ascii: "\""): return .string(try parseString())
    case UInt8(ascii: "t"): try expect("true"); return .bool(true)
    case UInt8(ascii: "f"): try expect("false"); return .bool(false)
    case UInt8(ascii: "n"): try expect("null"); return .null
    default: return .number(try parseNumber())
    }
  }

  mutating func expect(_ literal: String) throws {
    let utf8 = Array(literal.utf8)
    guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
      throw error("invalid literal")
    }
    index += utf8.count
  }

  mutating func parseObject() throws -> JSONValue {
    depth += 1
    defer { depth -= 1 }
    guard depth < 512 else { throw error("nesting too deep") }
    index += 1
    var object = JSONObject()
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      return .object(object)
    }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected object key") }
      let key = try parseString()
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
      index += 1
      skipWhitespace()
      object[key] = try parseValue()
      skipWhitespace()
      guard index < bytes.count else { throw error("unterminated object") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
      } else if bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(object)
      } else {
        throw error("expected ',' or '}'")
      }
    }
  }

  mutating func parseArray() throws -> JSONValue {
    depth += 1
    defer { depth -= 1 }
    guard depth < 512 else { throw error("nesting too deep") }
    index += 1
    var array: [JSONValue] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      return .array(array)
    }
    while true {
      skipWhitespace()
      array.append(try parseValue())
      skipWhitespace()
      guard index < bytes.count else { throw error("unterminated array") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
      } else if bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(array)
      } else {
        throw error("expected ',' or ']'")
      }
    }
  }

  mutating func parseString() throws -> String {
    index += 1  // opening quote
    var result: [UInt8] = []
    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case UInt8(ascii: "\""):
        index += 1
        return String(decoding: result, as: UTF8.self)
      case UInt8(ascii: "\\"):
        index += 1
        guard index < bytes.count else { throw error("unterminated escape") }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case UInt8(ascii: "\""): result.append(0x22)
        case UInt8(ascii: "\\"): result.append(0x5C)
        case UInt8(ascii: "/"): result.append(0x2F)
        case UInt8(ascii: "b"): result.append(0x08)
        case UInt8(ascii: "f"): result.append(0x0C)
        case UInt8(ascii: "n"): result.append(0x0A)
        case UInt8(ascii: "r"): result.append(0x0D)
        case UInt8(ascii: "t"): result.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try parseHex4()
          if (0xD800...0xDBFF).contains(scalar) {
            // surrogate pair
            if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
              index += 2
              let low = try parseHex4()
              guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
              scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else {
              scalar = 0xFFFD
            }
          } else if (0xDC00...0xDFFF).contains(scalar) {
            scalar = 0xFFFD
          }
          let unicode = Unicode.Scalar(scalar) ?? "\u{FFFD}"
          result.append(contentsOf: Array(String(Character(unicode)).utf8))
        default:
          throw error("invalid escape")
        }
      default:
        guard byte >= 0x20 else { throw error("control character in string") }
        result.append(byte)
        index += 1
      }
    }
    throw error("unterminated string")
  }

  mutating func parseHex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw error("invalid unicode escape") }
    var value: UInt32 = 0
    for byte in bytes[index..<index + 4] {
      value <<= 4
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
      default: throw error("invalid hex digit")
      }
    }
    index += 4
    return value
  }

  mutating func parseNumber() throws -> Double {
    let start = index
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
    while index < bytes.count {
      let byte = bytes[index]
      let isNumberByte =
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
        || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
      guard isNumberByte else { break }
      index += 1
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    guard !text.isEmpty, let value = Double(text), value.isFinite else {
      index = start
      throw error("invalid value")
    }
    return value
  }
}

// MARK: - Serialization

extension JSONValue {
  /// 컴팩트 JSON 문자열. 객체 키는 삽입 순서대로 출력된다.
  public var jsonString: String {
    var output = ""
    write(to: &output)
    return output
  }

  public var jsonData: Data { Data(jsonString.utf8) }

  func write(to output: inout String) {
    switch self {
    case .null: output += "null"
    case .bool(let value): output += value ? "true" : "false"
    case .number(let value):
      if value.rounded() == value, abs(value) < 1e15 {
        output += String(Int64(value))
      } else {
        output += "\(value)"
      }
    case .string(let value): JSONValue.writeString(value, to: &output)
    case .array(let values):
      output += "["
      for (offset, value) in values.enumerated() {
        if offset > 0 { output += "," }
        value.write(to: &output)
      }
      output += "]"
    case .object(let object):
      output += "{"
      for (offset, entry) in object.entries.enumerated() {
        if offset > 0 { output += "," }
        JSONValue.writeString(entry.key, to: &output)
        output += ":"
        entry.value.write(to: &output)
      }
      output += "}"
    }
  }

  static func writeString(_ string: String, to output: inout String) {
    output += "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      default:
        if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
  }
}
