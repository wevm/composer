// The structured document: blocks of inline runs, typed atomic nodes, and
// opaque unknown nodes. Markdown and JSON are import and export formats.

/// A rich-text document. The structured model is canonical; markdown and JSON
/// are import and export formats.
public struct Document: Sendable, Hashable {
  public var blocks: [Block]

  public init(blocks: [Block] = []) {
    self.blocks = blocks
  }

  /// A document with a single empty paragraph, where a caret can sit.
  public static var empty: Document { Document(blocks: [.paragraph([])]) }

  /// Whether the document has no content: no blocks, or one empty
  /// paragraph. An empty list item or code block is content, since it shows.
  public var isEmpty: Bool {
    switch blocks.count {
    case 0: true
    case 1: blocks[0] == .paragraph([]) || blocks[0] == .paragraph([.text("", marks: Marks())])
    default: false
    }
  }
}

public enum Block: Sendable, Hashable {
  case paragraph([Inline])
  /// A fenced code block. `language` is the fence's info string.
  case codeBlock(language: String?, text: String)
  case quote([Block])
  /// Nested up to 3 levels; deeper imports are clamped (see `Document.normalized()`).
  case list(ListKind, items: [ListItem])
  /// A JSON block whose type has no registered plugin, kept verbatim.
  case unknown(UnknownNode)
}

public enum ListKind: Sendable, Hashable {
  case bullet
  case ordered(start: Int)
}

public struct ListItem: Sendable, Hashable {
  /// `nil` for a plain item; `true` or `false` for a GFM task item.
  public var checked: Bool?
  public var blocks: [Block]

  public init(checked: Bool? = nil, blocks: [Block]) {
    self.checked = checked
    self.blocks = blocks
  }
}

public enum Inline: Sendable, Hashable {
  case text(String, marks: Marks)
  /// An indivisible token: a mention, hashtag, slash token, or custom token.
  case node(AtomicNode)
  /// A JSON inline node whose type has no registered plugin, kept verbatim.
  case unknown(UnknownNode)

  /// Unmarked text.
  public static func text(_ text: String) -> Inline { .text(text, marks: Marks()) }
}

/// The marks on a text run. Marks nest freely, except that nothing nests
/// inside inline code: a run with `code` and `bold` is bold code.
public struct Marks: Sendable, Hashable {
  public var bold: Bool
  public var italic: Bool
  public var strikethrough: Bool
  public var code: Bool
  /// The link destination, if the run is a link.
  public var link: String?

  public init(
    bold: Bool = false, italic: Bool = false, strikethrough: Bool = false, code: Bool = false,
    link: String? = nil
  ) {
    self.bold = bold
    self.italic = italic
    self.strikethrough = strikethrough
    self.code = code
    self.link = link
  }

  public static let bold = Marks(bold: true)
  public static let italic = Marks(italic: true)
  public static let strikethrough = Marks(strikethrough: true)
  public static let code = Marks(code: true)
  public static func link(_ url: String) -> Marks { Marks(link: url) }

  public var isEmpty: Bool { self == Marks() }

  public subscript(kind: MarkKind) -> Bool {
    get {
      switch kind {
      case .bold: bold
      case .italic: italic
      case .strikethrough: strikethrough
      case .code: code
      }
    }
    set {
      switch kind {
      case .bold: bold = newValue
      case .italic: italic = newValue
      case .strikethrough: strikethrough = newValue
      case .code: code = newValue
      }
    }
  }

  /// The union of two mark sets; `other`'s link wins when both have one.
  public func union(_ other: Marks) -> Marks {
    Marks(
      bold: bold || other.bold, italic: italic || other.italic,
      strikethrough: strikethrough || other.strikethrough, code: code || other.code,
      link: other.link ?? link)
  }
}

/// A boolean mark. Links are set separately because they carry a destination.
public enum MarkKind: String, Sendable, Hashable, CaseIterable {
  case bold, italic, strikethrough, code
}

/// The type of an atomic node, for example `"mention"`. Node types are open:
/// plugins register them in the `Schema`.
public struct NodeType: RawRepresentable, Sendable, Hashable, Comparable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public var rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.rawValue = value }

  public var description: String { rawValue }
  public static func < (lhs: NodeType, rhs: NodeType) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A typed, indivisible inline token. Delete and select treat it as one unit.
public struct AtomicNode: Sendable, Hashable {
  public var type: NodeType
  public var label: String
  public var attributes: [String: String]

  public init(type: NodeType, label: String, attributes: [String: String] = [:]) {
    self.type = type
    self.label = label
    self.attributes = attributes
  }
}

/// A JSON node whose type has no registered plugin. It keeps its JSON verbatim,
/// renders and exports to markdown as its `text`, and encodes back to the same
/// JSON.
public struct UnknownNode: Sendable, Hashable {
  /// The node's JSON object, verbatim.
  public var json: JSONValue

  public init(json: JSONValue) { self.json = json }

  /// The node's `type` field.
  public var type: String {
    if case .string(let type) = json["type"] { return type }
    return "unknown"
  }

  /// The node's fallback `text`, or `[type]` when the JSON has none.
  public var text: String {
    if case .string(let text) = json["text"] { return text }
    return "[\(type)]"
  }
}
