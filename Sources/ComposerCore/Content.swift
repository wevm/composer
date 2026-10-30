import Foundation

// Read-only rendering: a document as an `AttributedString`, the same on
// every platform, for sent messages. UI layers style its attributes.

/// The attributes `ContentRenderer` sets, in their own scope so they work on
/// Linux, where Foundation has no presentation intents.
public enum ComposerAttributes {
  /// The marks of a text run.
  public enum MarksAttribute: AttributedStringKey {
    public typealias Value = Marks
    public static let name = "dev.wevm.composer.marks"
  }

  /// The token a run draws (its fallback text).
  public enum NodeAttribute: AttributedStringKey {
    public typealias Value = AtomicNode
    public static let name = "dev.wevm.composer.node"
  }

  /// The token's style from its plugin, before any UI overrides.
  public enum TokenStyleAttribute: AttributedStringKey {
    public typealias Value = TokenStyle
    public static let name = "dev.wevm.composer.tokenStyle"
  }

  /// Text that draws structure rather than content: list markers, quote
  /// bars, and indentation.
  public enum DecorationAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "dev.wevm.composer.decoration"
  }

  /// A code block's text.
  public enum CodeBlockAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "dev.wevm.composer.codeBlock"
  }
}

/// Renders documents for reading. Blocks are lines of text: a list item
/// starts with its marker ("• ", "1. ", "☐ "), indented by its depth, and
/// each line of a quote with a bar ("┃ "), so the structure shows in a plain
/// `Text`. Text runs carry their marks and link, tokens their node and a
/// node URL as their link (see `AtomicNode.url`), so a tap can be told apart
/// from a link's. On Apple platforms marks also set Foundation's inline
/// presentation intents, which `Text` draws.
public struct ContentRenderer: Sendable {
  public var schema: Schema

  public init(schema: Schema = Schema()) {
    self.schema = schema
  }

  public func attributedString(_ document: Document) -> AttributedString {
    var result = AttributedString()
    var first = true
    let end = Position(document.length)
    document.forEachTextBlock(in: Position(0)..<end) { block, containers in
      if !first { result += AttributedString("\n") }
      first = false
      let (prefix, continuation) = Self.prefixes(containers)
      result += decoration(prefix)
      switch block.content {
      case .code(_, let text):
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.isEmpty { lines = [""] }
        for (index, line) in lines.enumerated() {
          if index > 0 {
            result += AttributedString("\n")
            result += decoration(continuation)
          }
          var run = AttributedString(String(line))
          run[ComposerAttributes.CodeBlockAttribute.self] = true
          apply(.code, to: &run)
          result += run
        }
      case .paragraph(let inlines):
        for inline in inlines {
          switch inline {
          case .text(let text, let marks):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
              if index > 0 {
                result += AttributedString("\n")
                result += decoration(continuation)
              }
              guard !line.isEmpty else { continue }
              var run = AttributedString(String(line))
              apply(marks, to: &run)
              result += run
            }
          case .node(let node):
            var run = AttributedString(schema.fallbackText(node))
            run[ComposerAttributes.NodeAttribute.self] = node
            run[ComposerAttributes.TokenStyleAttribute.self] = schema.tokenStyle(node)
            run.link = node.url
            result += run
          case .unknown(let node):
            result += AttributedString(node.text)
          }
        }
      }
    }
    return result
  }

  private func decoration(_ text: String) -> AttributedString {
    var run = AttributedString(text)
    if !text.isEmpty { run[ComposerAttributes.DecorationAttribute.self] = true }
    return run
  }

  private func apply(_ marks: Marks, to run: inout AttributedString) {
    guard !marks.isEmpty else { return }
    run[ComposerAttributes.MarksAttribute.self] = marks
    if let link = marks.link { run.link = URL(string: link) }
    #if canImport(Darwin)
      var intent = InlinePresentationIntent()
      if marks.bold { intent.insert(.stronglyEmphasized) }
      if marks.italic { intent.insert(.emphasized) }
      if marks.strikethrough { intent.insert(.strikethrough) }
      if marks.code { intent.insert(.code) }
      if !intent.isEmpty { run.inlinePresentationIntent = intent }
    #endif
  }

  /// The decoration before a text block's first line, and before its other
  /// lines.
  static func prefixes(_ containers: [TextBlock.Container]) -> (String, String) {
    var first = ""
    var rest = ""
    var bullets = 0
    for (level, container) in containers.enumerated() {
      let isLast = level == containers.count - 1
      switch container {
      case .quote:
        first += "┃ "
        rest += "┃ "
      case .listItem(let kind, let index, let checked, let isFirstBlock):
        let marker: String
        if let checked {
          marker = checked ? "☑ " : "☐ "
        } else if case .ordered(let start) = kind {
          marker = "\(start + index). "
        } else {
          marker = ["• ", "◦ ", "▪ "][bullets % 3]
        }
        if kind == .bullet { bullets += 1 }
        let blank = String(repeating: " ", count: marker.count)
        // The marker shows on the item's first line; deeper lines, and
        // the item's later blocks, line up under its text.
        first += isLast && isFirstBlock ? marker : blank
        rest += blank
      }
    }
    return (first, rest)
  }
}

extension AtomicNode {
  static let urlScheme = "composer-node"

  /// The node as an internal URL,
  /// `composer-node://node?type=…&label=…&a.<attribute>=…`, which a
  /// read-only view intercepts to tell taps on tokens from link taps.
  public var url: URL? {
    var components = URLComponents()
    components.scheme = Self.urlScheme
    components.host = "node"
    components.queryItems =
      [URLQueryItem(name: "type", value: type.rawValue), URLQueryItem(name: "label", value: label)]
      + attributes.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: "a." + $0.key, value: $0.value)
      }
    return components.url
  }

  /// The node a node URL stands for, or `nil` for any other URL.
  public init?(url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == Self.urlScheme
    else { return nil }
    var type = ""
    var label = ""
    var attributes: [String: String] = [:]
    for item in components.queryItems ?? [] {
      if item.name == "type" {
        type = item.value ?? ""
      } else if item.name == "label" {
        label = item.value ?? ""
      } else if item.name.hasPrefix("a.") {
        attributes[String(item.name.dropFirst(2))] = item.value ?? ""
      }
    }
    guard !type.isEmpty else { return nil }
    self.init(type: NodeType(type), label: label, attributes: attributes)
  }
}
