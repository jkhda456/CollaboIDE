import AFMBridgeCore
import Foundation
import FoundationModels

/// SchemaNode(IR) → `GenerationSchema`
@available(macOS 26.4, iOS 26.4, visionOS 26.4, *)
struct SchemaBuilder {
  private var enumCounter = 0

  static func generationSchema(from json: JSONValue, name: String) throws(BridgeError) -> GenerationSchema {
    try build(from: json, name: name).schema
  }

  static func build(from json: JSONValue, name: String) throws(BridgeError) -> (
    schema: GenerationSchema, document: SchemaDocument
  ) {
    let document: SchemaDocument
    do {
      document = try SchemaDocument.parse(json, rootName: name)
    } catch {
      throw .invalidRequest("Unsupported JSON schema: \(error.description)", code: "invalid_schema")
    }
    var builder = SchemaBuilder()
    do {
      let root = try builder.dynamicSchema(document.root)
      let dependencies = try document.definitions.map { try builder.dynamicSchema($0.node, name: $0.name) }
      return (try GenerationSchema(root: root, dependencies: dependencies), document)
    } catch let error as BridgeError {
      throw error
    } catch {
      throw .invalidRequest("Unsupported JSON schema: \(error)", code: "invalid_schema")
    }
  }

  private mutating func uniqueEnumName() -> String {
    enumCounter += 1
    return "Choice\(enumCounter)"
  }

  /// - Parameter name: `$defs` 처럼 이름으로 참조되는 스키마의 이름 강제
  mutating func dynamicSchema(_ node: SchemaNode, name: String? = nil) throws -> DynamicGenerationSchema {
    switch node {
    case .object(let objectName, let description, let properties):
      let converted = try properties.map { property in
        DynamicGenerationSchema.Property(
          name: property.name,
          description: property.description,
          schema: try dynamicSchema(property.schema),
          isOptional: property.isOptional
        )
      }
      return DynamicGenerationSchema(name: name ?? objectName, description: description, properties: converted)

    case .array(let items, _, let minItems, let maxItems):
      return DynamicGenerationSchema(
        arrayOf: try dynamicSchema(items), minimumElements: minItems, maximumElements: maxItems)

    case .string(let description, let choices?, _):
      return DynamicGenerationSchema(name: name ?? uniqueEnumName(), description: description, anyOf: choices)

    case .string(_, nil, let pattern?):
      let regex: Regex<AnyRegexOutput>
      do {
        regex = try Regex(pattern)
      } catch {
        throw BridgeError.invalidRequest("Invalid regex pattern '\(pattern)'.", code: "invalid_schema")
      }
      return DynamicGenerationSchema(type: String.self, guides: [.pattern(regex)])

    case .string:
      return DynamicGenerationSchema(type: String.self)

    case .integer(_, let minimum, let maximum):
      var guides: [GenerationGuide<Int>] = []
      switch (minimum, maximum) {
      case (let min?, let max?) where min <= max: guides.append(.range(min...max))
      case (let min?, nil): guides.append(.minimum(min))
      case (nil, let max?): guides.append(.maximum(max))
      default: break
      }
      return DynamicGenerationSchema(type: Int.self, guides: guides)

    case .number(_, let minimum, let maximum):
      var guides: [GenerationGuide<Double>] = []
      switch (minimum, maximum) {
      case (let min?, let max?) where min <= max: guides.append(.range(min...max))
      case (let min?, nil): guides.append(.minimum(min))
      case (nil, let max?): guides.append(.maximum(max))
      default: break
      }
      return DynamicGenerationSchema(type: Double.self, guides: guides)

    case .boolean:
      return DynamicGenerationSchema(type: Bool.self)

    case .anyOf(let anyOfName, let description, let choices):
      return DynamicGenerationSchema(
        name: name ?? anyOfName, description: description, anyOf: try choices.map { try dynamicSchema($0) })

    case .reference(let target):
      return DynamicGenerationSchema(referenceTo: target)
    }
  }
}
