/// The markdown codec: GFM, limited to the supported dialect (see DESIGN.md).
///
/// - `parse(serialize(doc)) == canonical(doc)` for every document whose
///   atomic nodes are registered in the schema and that has no unknown nodes
///   (those export as their fallback text). `canonical` is
///   `Document.normalized()` plus one rule for custom-syntax tokens.
/// - Export is canonical: `**bold**`, `_italic_`, `~~strike~~`, `-` bullets,
///   and fenced code. So re-export is idempotent after the first pass.
/// - Unsupported syntax (headings, tables, images, raw HTML, link titles,
///   reference links) stays as literal text, and export writes it back as it
///   was, so it keeps its meaning for other renderers.
public struct MarkdownCodec: Sendable {
  public var schema: Schema

  public init(schema: Schema = Schema()) {
    self.schema = schema
  }

  public func parse(_ markdown: String) -> Document {
    var parser = BlockParser(schema: schema)
    return canonical(Document(blocks: parser.parse(markdown)))
  }

  public func serialize(_ document: Document) -> String {
    var writer = MarkdownWriter(schema: schema)
    return writer.write(canonical(document))
  }

  /// The form `parse` returns: `document.normalized()`, plus one rule that
  /// depends on the schema. A custom-syntax token whose markdown ends (or
  /// starts) with a word character leaves no room to escape, so an emphasis
  /// delimiter next to it only opens (or closes) before (or after) a word
  /// character, and only one delimiter fits there (an italic `*` also can't
  /// touch bold, and a one-character run can't also sit before or after
  /// another delimiter). Where that fails, the emphasis moves off the edge
  /// character (or off the whole code span), the way whitespace moves
  /// outside marks.
  /// The text itself is never changed.
  ///
  /// `parse(serialize(doc)) == canonical(doc)` for every document whose
  /// atomic nodes are registered and that has no unknown nodes.
  public func canonical(_ document: Document) -> Document {
    let document = document.normalized()
    guard !schema.customCodecs.isEmpty else { return document }
    return Document(blocks: canonicalBlocks(document.blocks))
  }

  private func canonicalBlocks(_ blocks: [Block]) -> [Block] {
    blocks.map { block in
      switch block {
      case .paragraph(let content):
        let adjusted = separatingMarksFromWordTokens(content)
        return .paragraph(adjusted == content ? content : Normalizer.canonicalInlines(adjusted))
      case .quote(let children):
        return .quote(canonicalBlocks(children))
      case .list(let kind, let items):
        return .list(
          kind,
          items: items.map { ListItem(checked: $0.checked, blocks: canonicalBlocks($0.blocks)) })
      case .codeBlock, .unknown:
        return block
      }
    }
  }

  private func separatingMarksFromWordTokens(_ content: [Inline]) -> [Inline] {
    var runs = content
    var index = 0
    while index < runs.count {
      defer { index += 1 }
      guard case .node(let node) = runs[index], let spec = schema.nodes[node.type],
        case .custom(_, let encode, _) = spec.markdown.kind
      else { continue }
      let output = encode(node).unicodeScalars
      if index > 0, output.first?.isMarkdownWord == true {
        index += unmarkEdge(&runs, at: index - 1, leading: false)
      }
      if index + 1 < runs.count, output.last?.isMarkdownWord == true {
        _ = unmarkEdge(&runs, at: index + 1, leading: true)
      }
    }
    return runs
  }

  /// Whether the run at `index` has an emphasis mark that `marks` lacks,
  /// so a delimiter sits between them.
  private func changesEmphasis(_ runs: [Inline], at index: Int, from marks: Marks) -> Bool {
    guard index >= 0, index < runs.count, case .text(_, let other) = runs[index] else {
      return false
    }
    return [MarkKind.bold, .italic, .strikethrough].contains { other[$0] && !marks[$0] }
  }

  /// Whether the italic span starting (or ending) at `index` holds bold or
  /// is next to bold.
  private func italicTouchesBold(_ runs: [Inline], from index: Int, forward: Bool) -> Bool {
    var i = index
    while i >= 0, i < runs.count {
      guard case .text(_, let marks) = runs[i] else { return false }
      if marks.bold { return true }
      if !marks.italic { return false }
      i += forward ? 1 : -1
    }
    return false
  }

  /// Removes emphasis from the edge of the run at `index` when its delimiter
  /// couldn't flank there. Returns how many runs were inserted before
  /// `index + 1`.
  private func unmarkEdge(_ runs: inout [Inline], at index: Int, leading: Bool) -> Int {
    guard case .text(let text, var marks) = runs[index] else { return 0 }
    let kinds = [MarkKind.bold, .italic, .strikethrough].filter { marks[$0] }
    let scalars = Array(text.unicodeScalars)
    guard !kinds.isEmpty, let edge = leading ? scalars.first : scalars.last else { return 0 }
    // One delimiter, then a word character: it flanks. Anything else puts
    // punctuation (another delimiter, `[`, a backtick, or the text) next to it.
    // Italic must be `*` there (`_` can't open after a word character), and
    // a `*` next to a bold `**` merges into one delimiter run.
    // The edge character also can't be the one the writer escapes to make a
    // neighboring delimiter flank.
    if kinds.count == 1, marks.link == nil, !marks.code, edge.isMarkdownWord,
      kinds[0] != .italic || !italicTouchesBold(runs, from: index, forward: leading),
      scalars.count >= 2 || !changesEmphasis(runs, at: index + (leading ? 1 : -1), from: marks)
    {
      return 0
    }
    let original = marks
    for kind in kinds { marks[kind] = false }
    if marks.code || scalars.count == 1 {
      runs[index] = .text(text, marks: marks)
      return 0
    }
    let edgeText = Inline.text(
      String(scalars: leading ? scalars[..<1] : scalars[(scalars.count - 1)...]), marks: marks)
    let rest = Inline.text(
      String(scalars: leading ? scalars[1...] : scalars[..<(scalars.count - 1)]), marks: original)
    runs.replaceSubrange(index...index, with: leading ? [edgeText, rest] : [rest, edgeText])
    return 1
  }
}

extension Unicode.Scalar {
  /// CommonMark's Unicode punctuation: ASCII punctuation and the `P` and `S`
  /// categories (CommonMark 0.31). Symbols count, so emoji are punctuation.
  var isMarkdownPunctuation: Bool {
    if value < 0x80 { return isASCIIPunctuation }
    switch properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol,
      .modifierSymbol, .otherSymbol:
      return true
    default:
      return false
    }
  }

  var isASCIIPunctuation: Bool {
    switch value {
    case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
    default: return false
    }
  }

  /// Neither whitespace nor punctuation: a character that blocks a
  /// delimiter on one side.
  var isMarkdownWord: Bool { !isMarkdownWhitespace && !isMarkdownPunctuation }

  var isASCIIDigit: Bool { value >= 0x30 && value <= 0x39 }
  var isASCIILetter: Bool { (value | 0x20) >= 0x61 && (value | 0x20) <= 0x7A }
  var isASCIIHexDigit: Bool {
    isASCIIDigit || ((value | 0x20) >= 0x61 && (value | 0x20) <= 0x66)
  }
  var isSpaceOrTab: Bool { self == " " || self == "\t" }
}

/// Character references the parser decodes: decimal and hexadecimal numeric
/// references, and `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&nbsp;`.
/// Other named references stay literal, and export escapes `&` only before a
/// reference this decodes.
enum CharacterReference {
  static let named: [String: Unicode.Scalar] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
  ]

  /// Decodes a reference at `index` (an `&`). Returns the scalar and the
  /// index after the `;`.
  static func decode(_ s: [Unicode.Scalar], at index: Int) -> (Unicode.Scalar, Int)? {
    var i = index + 1
    guard i < s.count else { return nil }
    if s[i] == "#" {
      i += 1
      var value: UInt32 = 0
      var digits = 0
      if i < s.count, s[i] == "x" || s[i] == "X" {
        i += 1
        while i < s.count, s[i].isASCIIHexDigit, digits < 6 {
          value = value * 16 + UInt32(Int(String(s[i]), radix: 16)!)
          digits += 1
          i += 1
        }
      } else {
        while i < s.count, s[i].isASCIIDigit, digits < 7 {
          value = value * 10 + (s[i].value - 0x30)
          digits += 1
          i += 1
        }
      }
      guard digits > 0, i < s.count, s[i] == ";" else { return nil }
      let scalar = value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}"
      return (scalar, i + 1)
    }
    var name = ""
    while i < s.count, s[i].isASCIILetter || s[i].isASCIIDigit, name.unicodeScalars.count < 8 {
      name.unicodeScalars.append(s[i])
      i += 1
    }
    guard i < s.count, s[i] == ";", let scalar = named[name] else { return nil }
    return (scalar, i + 1)
  }

  static func encode(_ scalar: Unicode.Scalar) -> String { "&#\(scalar.value);" }
}
