/// The node types a composer knows, with their codecs. Plugins register them;
/// the core schema registers nothing.
public struct Schema: Sendable {
  public private(set) var nodes: [NodeType: NodeSpec] = [:]
  /// Directive names to node types, for the markdown parser.
  private(set) var directives: [String: NodeType] = [:]
  /// Node types with custom markdown codecs, in registration order.
  private(set) var customCodecs: [NodeType] = []
  /// Every custom codec's triggers, so the codec checks others cheaply.
  private(set) var customTriggers: Set<Unicode.Scalar> = []

  public init(_ nodes: [NodeSpec] = []) {
    for node in nodes { register(node) }
  }

  /// Registers a node type. A later registration of the same type replaces
  /// the earlier one.
  public mutating func register(_ node: NodeSpec) {
    if let previous = nodes[node.type] {
      if case .directive(let name) = previous.markdown.kind { directives[name] = nil }
      customCodecs.removeAll { $0 == node.type }
    }
    nodes[node.type] = node
    switch node.markdown.kind {
    case .directive(let name): directives[name] = node.type
    case .custom: customCodecs.append(node.type)
    }
    customTriggers = []
    for type in customCodecs {
      if case .custom(let triggers, _, _) = nodes[type]!.markdown.kind {
        customTriggers.formUnion(triggers)
      }
    }
  }

  public subscript(type: NodeType) -> NodeSpec? { nodes[type] }

  /// The fallback text of a node: what renders when nothing else can, and
  /// the JSON `text` field.
  public func fallbackText(_ node: AtomicNode) -> String {
    nodes[node.type]?.fallbackText(node) ?? node.label
  }
}

/// A node type and its codecs.
public struct NodeSpec: Sendable {
  public var type: NodeType
  public var markdown: MarkdownNodeCodec
  /// The node's fallback text, for example `"@tom"` for a mention.
  public var fallbackText: @Sendable (AtomicNode) -> String

  public init(
    _ type: NodeType, markdown: MarkdownNodeCodec? = nil,
    fallbackText: @escaping @Sendable (AtomicNode) -> String = { $0.label }
  ) {
    self.type = type
    self.markdown = markdown ?? .directive(name: type.rawValue)
    self.fallbackText = fallbackText
  }

  /// The same node type with another markdown codec.
  public func codec(_ codec: MarkdownNodeCodec) -> NodeSpec {
    var copy = self
    copy.markdown = codec
    return copy
  }
}

/// How an atomic node is written in markdown.
public struct MarkdownNodeCodec: Sendable {
  enum Kind: Sendable {
    case directive(name: String)
    case custom(
      triggers: Set<Unicode.Scalar>, encode: @Sendable (AtomicNode) -> String,
      decode: @Sendable (Substring) -> (node: AtomicNode, end: Substring.Index)?)
  }

  let kind: Kind

  /// A generic text directive, `:name[label]{#id key="value"}`. The default.
  /// Directive names are letters, digits, `-`, and `_`, starting with a letter.
  public static func directive(name: String) -> MarkdownNodeCodec {
    MarkdownNodeCodec(kind: .directive(name: name))
  }

  /// A custom syntax, for example `#tag` or `<@user_123>`.
  ///
  /// - `triggers`: the characters a node can start with. The parser tries
  ///   `decode` only at an unescaped trigger, in text.
  /// - `encode`: the node's markdown, written verbatim.
  /// - `decode`: given the rest of the line from a trigger, returns the node
  ///   and where its syntax ends, or `nil`. Export escapes a trigger in text
  ///   whenever `decode` would accept the text that follows it.
  public static func custom(
    triggers: Set<Character>, encode: @escaping @Sendable (AtomicNode) -> String,
    decode: @escaping @Sendable (Substring) -> (node: AtomicNode, end: Substring.Index)?
  ) -> MarkdownNodeCodec {
    var scalars = Set<Unicode.Scalar>()
    for trigger in triggers {
      precondition(trigger.unicodeScalars.count == 1, "A trigger is a single scalar")
      scalars.insert(trigger.unicodeScalars.first!)
    }
    return MarkdownNodeCodec(kind: .custom(triggers: scalars, encode: encode, decode: decode))
  }
}
