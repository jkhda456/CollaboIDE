/// JSON Schema 를 Foundation Models 가 표현할 수 있는 형태로 정규화한 중간 표현(IR).
///
/// 지원: object / array / string(enum, pattern) / integer / number / boolean / anyOf·oneOf / $ref / nullable
/// 무시(제거): additionalProperties, format, title, default, examples 등 생성 제약이 아닌 키워드
/// 거절: allOf(2개 이상), not, if/then/else, patternProperties
public indirect enum SchemaNode: Sendable, Equatable {
  case object(name: String, description: String?, properties: [Property])
  case array(items: SchemaNode, description: String?, minItems: Int?, maxItems: Int?)
  case string(description: String?, choices: [String]?, pattern: String?)
  case integer(description: String?, minimum: Int?, maximum: Int?)
  case number(description: String?, minimum: Double?, maximum: Double?)
  case boolean(description: String?)
  case anyOf(name: String, description: String?, choices: [SchemaNode])
  case reference(String)

  public struct Property: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var schema: SchemaNode
    public var isOptional: Bool

    public init(name: String, description: String?, schema: SchemaNode, isOptional: Bool) {
      self.name = name
      self.description = description
      self.schema = schema
      self.isOptional = isOptional
    }
  }

  public var description: String? {
    switch self {
    case .object(_, let description, _), .array(_, let description, _, _), .string(let description, _, _),
      .integer(let description, _, _), .number(let description, _, _), .boolean(let description),
      .anyOf(_, let description, _):
      return description
    case .reference: return nil
    }
  }
}

/// 루트 스키마 + `$defs` 정의들
public struct SchemaDocument: Sendable, Equatable {
  public var root: SchemaNode
  public var definitions: [(name: String, node: SchemaNode)]

  public static func == (lhs: SchemaDocument, rhs: SchemaDocument) -> Bool {
    lhs.root == rhs.root && lhs.definitions.map(\.name) == rhs.definitions.map(\.name)
      && zip(lhs.definitions, rhs.definitions).allSatisfy { $0.node == $1.node }
  }
}

public struct SchemaConversionError: Error, Sendable, CustomStringConvertible {
  public var path: String
  public var message: String
  public var description: String { "\(path): \(message)" }
}

extension SchemaDocument {
  /// JSON Schema → IR
  public static func parse(_ schema: JSONValue, rootName: String) throws(SchemaConversionError) -> SchemaDocument {
    var converter = SchemaParser()
    var definitions: [(String, SchemaNode)] = []
    for key in ["$defs", "definitions"] {
      guard let defs = schema[key]?.objectValue else { continue }
      for (name, definition) in defs.entries {
        definitions.append((name, try converter.node(definition, name: name, path: "#/\(key)/\(name)")))
      }
    }
    let root = try converter.node(schema, name: sanitize(rootName), path: "#")
    return SchemaDocument(root: root, definitions: definitions)
  }

  static func sanitize(_ name: String) -> String {
    let cleaned = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
    return cleaned.isEmpty ? "Schema" : String(cleaned)
  }
}

private struct SchemaParser {
  var anonymousCounter = 0

  mutating func uniqueName(_ base: String) -> String {
    anonymousCounter += 1
    return "\(base)_\(anonymousCounter)"
  }

  mutating func node(_ json: JSONValue, name: String, path: String) throws(SchemaConversionError) -> SchemaNode {
    // `true` / `{}` = any → 문자열로 근사
    if case .bool(true) = json { return .string(description: nil, choices: nil, pattern: nil) }
    guard let schema = json.objectValue else {
      throw SchemaConversionError(path: path, message: "schema must be an object")
    }
    let description = schema["description"]?.stringValue

    if let ref = schema["$ref"]?.stringValue {
      guard let last = ref.split(separator: "/").last, ref.hasPrefix("#/") else {
        throw SchemaConversionError(path: path, message: "only local $ref is supported")
      }
      return .reference(String(last))
    }

    for keyword in ["not", "if", "patternProperties"] where schema[keyword] != nil {
      throw SchemaConversionError(path: path, message: "'\(keyword)' is not supported")
    }

    if let allOf = schema["allOf"]?.arrayValue {
      guard allOf.count == 1 else {
        throw SchemaConversionError(path: path, message: "'allOf' with multiple schemas is not supported")
      }
      return try node(allOf[0], name: name, path: "\(path)/allOf/0")
    }

    if let choices = schema["anyOf"]?.arrayValue ?? schema["oneOf"]?.arrayValue {
      // nullable 패턴 (anyOf: [X, {type: null}]) 은 X 로 축약. optional 여부는 부모 object 가 판단
      let nonNull = choices.filter { $0["type"]?.stringValue != "null" }
      if nonNull.count == 1 { return try node(nonNull[0], name: name, path: "\(path)/anyOf/0") }
      guard !nonNull.isEmpty else { throw SchemaConversionError(path: path, message: "anyOf has no choices") }
      var nodes: [SchemaNode] = []
      for (index, choice) in nonNull.enumerated() {
        nodes.append(try node(choice, name: "\(name)_\(index)", path: "\(path)/anyOf/\(index)"))
      }
      return .anyOf(name: name, description: description, choices: nodes)
    }

    if let values = schema["enum"]?.arrayValue {
      let strings = values.compactMap(\.stringValue)
      guard strings.count == values.count, !strings.isEmpty else {
        throw SchemaConversionError(path: path, message: "only string enums are supported")
      }
      return .string(description: description, choices: strings, pattern: nil)
    }
    if let constant = schema["const"] {
      guard let string = constant.stringValue else {
        throw SchemaConversionError(path: path, message: "only string const is supported")
      }
      return .string(description: description, choices: [string], pattern: nil)
    }

    let type = try resolveType(schema, path: path)
    switch type {
    case "object":
      let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      var properties: [SchemaNode.Property] = []
      for (propertyName, propertySchema) in schema["properties"]?.objectValue?.entries ?? [] {
        let child = try node(
          propertySchema, name: "\(name)_\(SchemaDocument.sanitize(propertyName))",
          path: "\(path)/properties/\(propertyName)")
        properties.append(
          .init(
            name: propertyName,
            description: propertySchema["description"]?.stringValue,
            schema: child,
            isOptional: !required.contains(propertyName) || Self.isNullable(propertySchema)
          ))
      }
      return .object(name: name, description: description, properties: properties)

    case "array":
      let items: SchemaNode
      if let itemSchema = schema["items"] {
        items = try node(itemSchema, name: "\(name)_item", path: "\(path)/items")
      } else {
        items = .string(description: nil, choices: nil, pattern: nil)
      }
      return .array(
        items: items, description: description,
        minItems: schema["minItems"]?.intValue, maxItems: schema["maxItems"]?.intValue)

    case "string":
      return .string(description: description, choices: nil, pattern: schema["pattern"]?.stringValue)

    case "integer":
      return .integer(
        description: description,
        minimum: schema["minimum"]?.intValue ?? schema["exclusiveMinimum"]?.intValue.map { $0 + 1 },
        maximum: schema["maximum"]?.intValue ?? schema["exclusiveMaximum"]?.intValue.map { $0 - 1 })

    case "number":
      return .number(
        description: description,
        minimum: schema["minimum"]?.doubleValue ?? schema["exclusiveMinimum"]?.doubleValue,
        maximum: schema["maximum"]?.doubleValue ?? schema["exclusiveMaximum"]?.doubleValue)

    case "boolean":
      return .boolean(description: description)

    default:
      throw SchemaConversionError(path: path, message: "unsupported type '\(type)'")
    }
  }

  func resolveType(_ schema: JSONObject, path: String) throws(SchemaConversionError) -> String {
    switch schema["type"] {
    case .string(let type)?: return type
    case .array(let types)?:
      let nonNull = types.compactMap(\.stringValue).filter { $0 != "null" }
      guard nonNull.count == 1 else {
        throw SchemaConversionError(path: path, message: "multiple types are not supported; use anyOf")
      }
      return nonNull[0]
    case nil:
      if schema["properties"] != nil { return "object" }
      if schema["items"] != nil { return "array" }
      return "string"
    default:
      throw SchemaConversionError(path: path, message: "invalid 'type'")
    }
  }

  static func isNullable(_ schema: JSONValue) -> Bool {
    if let types = schema["type"]?.arrayValue, types.contains(.string("null")) { return true }
    if let choices = schema["anyOf"]?.arrayValue ?? schema["oneOf"]?.arrayValue {
      return choices.contains { $0["type"]?.stringValue == "null" }
    }
    return false
  }
}

extension SchemaDocument {
  /// 생성된 JSON 의 객체 키를 스키마의 properties 순서대로 재정렬한다.
  /// (`GeneratedContent.jsonString` 은 키 순서를 보장하지 않는다)
  public func reordered(_ value: JSONValue) -> JSONValue {
    reorder(value, node: root, depth: 0)
  }

  private func reorder(_ value: JSONValue, node: SchemaNode, depth: Int) -> JSONValue {
    guard depth < 64 else { return value }
    switch (node, value) {
    case (.reference(let name), _):
      guard let target = definitions.first(where: { $0.name == name })?.node else { return value }
      return reorder(value, node: target, depth: depth + 1)
    case (.object(_, _, let properties), .object(let object)):
      var result = JSONObject()
      for property in properties {
        if let child = object[property.name] {
          result[property.name] = reorder(child, node: property.schema, depth: depth + 1)
        }
      }
      for (key, child) in object.entries where result[key] == nil { result[key] = child }
      return .object(result)
    case (.array(let items, _, _, _), .array(let values)):
      return .array(values.map { reorder($0, node: items, depth: depth + 1) })
    case (.anyOf(_, _, let choices), .object(let object)):
      // 키 집합이 가장 잘 맞는 선택지를 사용
      let best = choices.max { score($0, object) < score($1, object) }
      return best.map { reorder(value, node: $0, depth: depth + 1) } ?? value
    default:
      return value
    }
  }

  private func score(_ node: SchemaNode, _ object: JSONObject) -> Int {
    guard case .object(_, _, let properties) = node else { return -1 }
    return properties.filter { object[$0.name] != nil }.count
  }
}
