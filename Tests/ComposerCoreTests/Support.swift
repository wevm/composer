import ComposerCore

/// A deterministic generator (SplitMix64), so property tests are reproducible
/// on every platform.
struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// Mentions as directives (the default codec) and hashtags as plain `#tag`
/// (a custom codec), as the trigger plugins will register them.
let testSchema = Schema([
  NodeSpec(.mention, fallbackText: { "@" + $0.label }),
  NodeSpec(
    .hashtag,
    markdown: .custom(
      triggers: ["#"], encode: { "#" + $0.label },
      decode: { text in
        var end = text.index(after: text.startIndex)
        while end < text.endIndex, text[end].isLetter || text[end].isNumber || text[end] == "_" {
          end = text.index(after: end)
        }
        guard end > text.index(after: text.startIndex) else { return nil }
        let label = String(text[text.index(after: text.startIndex)..<end])
        return (AtomicNode(type: .hashtag, label: label), end)
      }),
    fallbackText: { "#" + $0.label }),
])

let markdown = MarkdownCodec(schema: testSchema)

func paragraph(_ content: Inline...) -> Block { .paragraph(content) }
func text(_ string: String, _ marks: Marks = Marks()) -> Inline { .text(string, marks: marks) }
func mention(_ label: String, id: String) -> Inline {
  .node(AtomicNode(type: .mention, label: label, attributes: ["id": id]))
}
func bullets(_ items: [Block]...) -> Block {
  .list(.bullet, items: items.map { ListItem(blocks: $0) })
}

/// Random documents built to hit the codec's hard cases: syntax characters
/// in text, marks that start and end mid-word, whitespace at mark edges,
/// links with awkward destinations, nested containers past the depth
/// limits, and code with backtick runs.
struct DocumentGenerator {
  var rng: SeededGenerator

  static let pieces = [
    "a", "b", "word", " ", "  ", "\t", "\n", "\n\n", "*", "**", "_", "__", "~", "~~", "`", "``",
    "```", "[", "]", "(", ")", "](", "!", "<", ">", "&", "&amp;", "&#42;", "&copy;", "#", "#tag",
    ":", ":mention[x]", "\\", "-", "- ", "+ ", "1.", "1. ", "2) ", "> ", "|", "\"", "'", ".",
    "é", "😀", "日本", "http://x.y", "<http://a.b>", "[ ] ", "[x] ", "    ", "---", "#hash",
  ]
  static let urls = [
    "https://wevm.dev", "a b", "(x)", "u)v", "<w>", "a\\b", "", "&amp;", "https://x.y/?q=1&r=2",
    "*", "http://a.b",
  ]
  static let labels = ["tom", "a b", "x]y", "[z]", "back\\slash", "", "émile"]
  static let ids = ["user_123", "a b", "q\"uote", "", "&amp;", "x.y"]

  init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

  mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
  mutating func pick<T>(_ values: [T]) -> T { values.randomElement(using: &rng)! }
  mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }

  mutating func string(maxPieces: Int = 5) -> String {
    var result = ""
    for _ in 0..<int(1...maxPieces) { result += pick(Self.pieces) }
    return result
  }

  mutating func document() -> Document {
    Document(blocks: blocks(depth: 0))
  }

  mutating func blocks(depth: Int) -> [Block] {
    (0..<int(1...3)).map { _ in block(depth: depth) }
  }

  mutating func block(depth: Int) -> Block {
    let roll = depth > 5 ? 0 : int(0...9)
    switch roll {
    case 0...4:
      return .paragraph(inlines())
    case 5:
      let language: String? = chance(0.5) ? pick(["swift", "a b", "`x`", " js ", "~"]) : nil
      return .codeBlock(language: language, text: string(maxPieces: 6))
    case 6:
      return .quote(blocks(depth: depth + 1))
    default:
      let kind: ListKind = chance(0.5) ? .bullet : .ordered(start: pick([0, 1, 7, 999_999_999]))
      let items = (0..<int(1...3)).map { _ in
        ListItem(checked: chance(0.3) ? chance(0.5) : nil, blocks: blocks(depth: depth + 1))
      }
      return .list(kind, items: items)
    }
  }

  mutating func inlines() -> [Inline] {
    (0..<int(1...6)).map { _ in
      switch int(0...9) {
      case 0:
        return .node(
          AtomicNode(
            type: .mention, label: pick(Self.labels),
            attributes: chance(0.7) ? ["id": pick(Self.ids)] : ["role": pick(Self.ids)]))
      case 1:
        return .node(AtomicNode(type: .hashtag, label: pick(["swift", "a_1", "日本"])))
      default:
        var marks = Marks(
          bold: chance(0.3), italic: chance(0.3), strikethrough: chance(0.2), code: chance(0.15))
        if chance(0.2) { marks.link = pick(Self.urls) }
        return .text(string(), marks: marks)
      }
    }
  }
}

/// Random markdown made of syntax fragments, for the idempotence property.
struct MarkdownGenerator {
  var rng: SeededGenerator

  static let fragments = [
    "**", "*", "_", "__", "~~", "~", "~~~", "`", "``", "```", "```swift\n", "\n", "\n\n", "- ",
    "* ", "+ ", "1. ", "3) ", "  ", "    ", "\t", "> ", ">", "[", "]", "](", "(", ")", "](u)",
    "[t](u)", "<", ">", "<http://a.b>", "&amp;", "&#42;", "&copy;", "&", "\\", "\\*", "!",
    "![a](b)",
    "[ ] ", "[x] ", "- [ ] ", ":mention[tom]{#u1}", ":mention[a", "#tag", "# ", "## h", "|a|b|",
    "---", "***", "<b>", "</b>", "a", "b", "word", " ", "é", "😀", "\r\n", "[a](b \"t\")", "=",
  ]

  init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

  mutating func markdown() -> String {
    var result = ""
    for _ in 0..<Int.random(in: 1...24, using: &rng) {
      result += Self.fragments.randomElement(using: &rng)!
    }
    return result
  }
}
