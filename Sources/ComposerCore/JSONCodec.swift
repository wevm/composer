import Foundation

/// The versioned JSON form of a document, for drafts, the private pasteboard
/// type, and wherever markdown would lose information.
///
/// ```json
/// { "version": 1, "blocks": [
///   { "type": "paragraph", "children": [
///     { "type": "text", "text": "hi ", "marks": ["bold"] },
///     { "type": "mention", "text": "@tom", "label": "tom", "attrs": { "id": "user_123" } } ] } ] }
/// ```
///
/// Every node is an object with a `type`. Atomic nodes always carry their
/// fallback `text`. A node whose type the schema doesn't register decodes to
/// an `UnknownNode` that keeps its JSON verbatim and encodes back unchanged.
public struct JSONCodec: Sendable {
  public static let version = 1

  public enum DecodingError: Error, Equatable {
    case notAnObject
    case missingVersion
    case unsupportedVersion(Int)
    case invalid(String)
  }

  public var schema: Schema

  public init(schema: Schema = Schema()) {
    self.schema = schema
  }

  public func encode(_ document: Document) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value(document))
  }

  public func decode(_ data: Data) throws -> Document {
    try document(JSONParser.parse(data))
  }

  // MARK: Encoding

  public func value(_ document: Document) -> JSONValue {
    .object(["version": .int(Int64(Self.version)), "blocks": .array(document.blocks.map(value))])
  }

  private func value(_ block: Block) -> JSONValue {
    switch block {
    case .paragraph(let content):
      return .object(["type": "paragraph", "children": .array(content.map(value))])
    case .codeBlock(let language, let text):
      var object: [String: JSONValue] = ["type": "codeBlock", "text": .string(text)]
      if let language { object["attrs"] = .object(["language": .string(language)]) }
      return .object(object)
    case .quote(let children):
      return .object(["type": "quote", "children": .array(children.map(value))])
    case .list(let kind, let items):
      let attrs: [String: JSONValue] =
        switch kind {
        case .bullet: ["kind": "bullet"]
        case .ordered(let start): ["kind": "ordered", "start": .int(Int64(start))]
        }
      return .object([
        "type": "list", "attrs": .object(attrs),
        "children": .array(
          items.map { item in
            var object: [String: JSONValue] = [
              "type": "listItem", "children": .array(item.blocks.map(value)),
            ]
            if let checked = item.checked { object["attrs"] = .object(["checked": .bool(checked)]) }
            return .object(object)
          }),
      ])
    case .unknown(let node):
      return node.json
    }
  }

  private func value(_ inline: Inline) -> JSONValue {
    switch inline {
    case .text(let text, let marks):
      var object: [String: JSONValue] = ["type": "text", "text": .string(text)]
      let names = MarkKind.allCases.filter { marks[$0] }.map { JSONValue.string($0.rawValue) }
      if !names.isEmpty { object["marks"] = .array(names) }
      if let link = marks.link { object["attrs"] = .object(["href": .string(link)]) }
      return .object(object)
    case .node(let node):
      var object: [String: JSONValue] = [
        "type": .string(node.type.rawValue), "text": .string(schema.fallbackText(node)),
        "label": .string(node.label),
      ]
      if !node.attributes.isEmpty {
        object["attrs"] = .object(node.attributes.mapValues { .string($0) })
      }
      return .object(object)
    case .unknown(let node):
      return node.json
    }
  }

  // MARK: Decoding

  public func document(_ json: JSONValue) throws -> Document {
    guard case .object(let object) = json else { throw DecodingError.notAnObject }
    guard case .int(let version)? = object["version"] else { throw DecodingError.missingVersion }
    guard version == Self.version else { throw DecodingError.unsupportedVersion(Int(version)) }
    return Document(blocks: try array(object["blocks"], "blocks").map(block))
  }

  private func block(_ json: JSONValue) throws -> Block {
    guard case .object(let object) = json, case .string(let type)? = object["type"] else {
      throw DecodingError.invalid("A block is an object with a type")
    }
    let attrs = object["attrs"]
    switch type {
    case "paragraph":
      return .paragraph(try array(object["children"], "paragraph children").map(inline))
    case "codeBlock":
      guard case .string(let text)? = object["text"] else {
        throw DecodingError.invalid("A code block has text")
      }
      var language: String?
      if case .string(let value)? = attrs?["language"] { language = value }
      return .codeBlock(language: language, text: text)
    case "quote":
      return .quote(try array(object["children"], "quote children").map(block))
    case "list":
      let kind: ListKind
      switch attrs?["kind"] {
      case .string("bullet")?:
        kind = .bullet
      case .string("ordered")?:
        guard case .int(let start)? = attrs?["start"], let value = Int(exactly: start) else {
          throw DecodingError.invalid("An ordered list has a start")
        }
        kind = .ordered(start: value)
      default:
        throw DecodingError.invalid("A list has a kind")
      }
      let items = try array(object["children"], "list children").map { json -> ListItem in
        guard case .object(let item) = json, item["type"] == .string("listItem") else {
          throw DecodingError.invalid("A list's children are list items")
        }
        var checked: Bool?
        if case .bool(let value)? = item["attrs"]?["checked"] { checked = value }
        return ListItem(
          checked: checked, blocks: try array(item["children"], "list item children").map(block))
      }
      return .list(kind, items: items)
    default:
      return .unknown(UnknownNode(json: json))
    }
  }

  private func inline(_ json: JSONValue) throws -> Inline {
    guard case .object(let object) = json, case .string(let type)? = object["type"] else {
      throw DecodingError.invalid("An inline node is an object with a type")
    }
    if type == "text" {
      guard case .string(let text)? = object["text"] else {
        throw DecodingError.invalid("A text node has text")
      }
      var marks = Marks()
      if case .array(let names)? = object["marks"] {
        for case .string(let name) in names {
          if let kind = MarkKind(rawValue: name) { marks[kind] = true }
        }
      }
      if case .string(let href)? = object["attrs"]?["href"] { marks.link = href }
      return .text(text, marks: marks)
    }
    guard schema.nodes[NodeType(type)] != nil else { return .unknown(UnknownNode(json: json)) }
    var label = ""
    if case .string(let value)? = object["label"] {
      label = value
    } else if case .string(let value)? = object["text"] {
      label = value
    }
    var attributes: [String: String] = [:]
    if case .object(let attrs)? = object["attrs"] {
      for (key, value) in attrs {
        guard case .string(let string) = value else {
          throw DecodingError.invalid("Atomic node attributes are strings")
        }
        attributes[key] = string
      }
    }
    return .node(AtomicNode(type: NodeType(type), label: label, attributes: attributes))
  }

  private func array(_ json: JSONValue?, _ what: String) throws -> [JSONValue] {
    guard let json else { return [] }
    guard case .array(let array) = json else { throw DecodingError.invalid("\(what) is an array") }
    return array
  }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension Document: Codable {
  /// The schema-free JSON form: every atomic node type decodes as unknown.
  /// Use `JSONCodec` with the composer's schema to keep typed nodes.
  public init(from decoder: any Decoder) throws {
    self = try JSONCodec().document(JSONValue(from: decoder))
  }

  public func encode(to encoder: any Encoder) throws {
    try JSONCodec().value(self).encode(to: encoder)
  }
}
