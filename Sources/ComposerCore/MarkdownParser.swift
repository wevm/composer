// The markdown parser: CommonMark's block structure and inline algorithm,
// limited to the supported dialect. Anything outside it stays literal text.

typealias Line = [Unicode.Scalar]

extension Array where Element == Unicode.Scalar {
  var isBlank: Bool { allSatisfy(\.isSpaceOrTab) }

  /// The leading whitespace, in columns (tabs stop every 4), and its length.
  var indentation: (columns: Int, count: Int) {
    var columns = 0
    var count = 0
    while count < self.count, self[count].isSpaceOrTab {
      columns += self[count] == "\t" ? 4 - columns % 4 : 1
      count += 1
    }
    return (columns, count)
  }

  /// Removes up to `columns` columns of leading whitespace. A tab that is
  /// only partly removed leaves spaces for the rest.
  func strippingIndentation(_ columns: Int) -> Line {
    var column = 0
    var index = 0
    while index < count, column < columns, self[index].isSpaceOrTab {
      let width = self[index] == "\t" ? 4 - column % 4 : 1
      if column + width > columns {
        let rest = column + width - columns
        return Line(repeating: " ", count: rest) + self[(index + 1)...]
      }
      column += width
      index += 1
    }
    return Line(self[index...])
  }

  func trimmingSpacesAndTabs() -> ArraySlice<Unicode.Scalar> {
    var start = startIndex
    var end = endIndex
    while start < end, self[start].isSpaceOrTab { start += 1 }
    while end > start, self[end - 1].isSpaceOrTab { end -= 1 }
    return self[start..<end]
  }
}

extension String {
  init<S: Sequence<Unicode.Scalar>>(scalars: S) {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    self = String(view)
  }
}

struct ListMarker {
  enum Kind: Equatable {
    case bullet(Unicode.Scalar)
    case ordered(start: Int, delimiter: Unicode.Scalar)
  }

  var kind: Kind
  /// The column where the item's content starts.
  var contentColumn: Int
  var isEmpty: Bool

  func continues(_ other: ListMarker) -> Bool {
    switch (kind, other.kind) {
    case (.bullet(let a), .bullet(let b)): a == b
    case (.ordered(_, let a), .ordered(_, let b)): a == b
    default: false
    }
  }
}

struct Fence {
  var character: Unicode.Scalar
  var length: Int
  var indentation: Int
  var info: String
}

enum BlockSyntax {
  /// Lists and quotes nest at most this deep while parsing. Deeper markers
  /// stay literal text, which bounds recursion on hostile input.
  static let maxDepth = 32

  static func listMarker(_ line: Line) -> ListMarker? {
    let (columns, start) = line.indentation
    guard columns < 4, start < line.count else { return nil }
    var index = start
    let kind: ListMarker.Kind
    if line[index] == "-" || line[index] == "+" || line[index] == "*" {
      kind = .bullet(line[index])
      index += 1
    } else {
      var value = 0
      while index < line.count, line[index].isASCIIDigit, index - start < 9 {
        value = value * 10 + Int(line[index].value - 0x30)
        index += 1
      }
      guard index > start, index < line.count, line[index] == "." || line[index] == ")" else {
        return nil
      }
      kind = .ordered(start: value, delimiter: line[index])
      index += 1
    }
    let markerEnd = columns + (index - start)
    if index == line.count {
      return ListMarker(kind: kind, contentColumn: markerEnd + 1, isEmpty: true)
    }
    guard line[index].isSpaceOrTab else { return nil }
    var column = markerEnd
    var cursor = index
    while cursor < line.count, line[cursor].isSpaceOrTab {
      column += line[cursor] == "\t" ? 4 - column % 4 : 1
      cursor += 1
    }
    if cursor == line.count {
      return ListMarker(kind: kind, contentColumn: markerEnd + 1, isEmpty: true)
    }
    let spaces = column - markerEnd
    return ListMarker(
      kind: kind, contentColumn: spaces >= 5 ? markerEnd + 1 : column, isEmpty: false)
  }

  static func isThematicBreak(_ line: Line) -> Bool {
    let (columns, start) = line.indentation
    guard columns < 4, start < line.count else { return false }
    let character = line[start]
    guard character == "-" || character == "*" || character == "_" else { return false }
    var count = 0
    for scalar in line[start...] {
      if scalar == character {
        count += 1
      } else if !scalar.isSpaceOrTab {
        return false
      }
    }
    return count >= 3
  }

  static func isQuote(_ line: Line) -> Bool {
    let (columns, start) = line.indentation
    return columns < 4 && start < line.count && line[start] == ">"
  }

  static func strippingQuote(_ line: Line) -> Line {
    var index = line.indentation.count + 1
    if index < line.count, line[index].isSpaceOrTab { index += 1 }
    return Line(line[index...])
  }

  static func openingFence(_ line: Line) -> Fence? {
    let (columns, start) = line.indentation
    guard columns < 4, start < line.count else { return nil }
    let character = line[start]
    guard character == "`" || character == "~" else { return nil }
    var index = start
    while index < line.count, line[index] == character { index += 1 }
    let length = index - start
    guard length >= 3 else { return nil }
    let info = line[index...]
    if character == "`", info.contains("`") { return nil }
    return Fence(
      character: character, length: length, indentation: columns,
      info: String(scalars: Line(info).trimmingSpacesAndTabs()))
  }

  static func closes(_ fence: Fence, _ line: Line) -> Bool {
    let (columns, start) = line.indentation
    guard columns < 4 else { return false }
    var index = start
    while index < line.count, line[index] == fence.character { index += 1 }
    return index - start >= fence.length && Line(line[index...]).isBlank
  }
}

struct BlockParser {
  let schema: Schema

  mutating func parse(_ markdown: String) -> [Block] {
    var lines: [Line] = []
    var current = Line()
    var previousWasCR = false
    for scalar in markdown.unicodeScalars {
      if scalar == "\n", previousWasCR {
        previousWasCR = false
        continue
      }
      previousWasCR = scalar == "\r"
      if scalar == "\n" || scalar == "\r" {
        lines.append(current)
        current.removeAll(keepingCapacity: true)
      } else if scalar == "\0" {
        current.append("\u{FFFD}")
      } else {
        current.append(scalar)
      }
    }
    lines.append(current)
    return blocks(lines[...], depth: 0, quoteDepth: 0)
  }

  private func blocks(_ lines: ArraySlice<Line>, depth: Int, quoteDepth: Int) -> [Block] {
    var result: [Block] = []
    var i = lines.startIndex
    let end = lines.endIndex
    let nests = depth < BlockSyntax.maxDepth
    let quotes = nests && quoteDepth < Document.maxQuoteDepth
    while i < end {
      let line = lines[i]
      if line.isBlank {
        i += 1
        continue
      }
      if line.indentation.columns >= 4 {
        // An indented code block.
        var content: [Line] = []
        while i < end, lines[i].isBlank || lines[i].indentation.columns >= 4 {
          content.append(lines[i].strippingIndentation(4))
          i += 1
        }
        while content.last?.isBlank == true { content.removeLast() }
        result.append(.codeBlock(language: nil, text: Self.join(content)))
        continue
      }
      if let fence = BlockSyntax.openingFence(line) {
        var content: [Line] = []
        i += 1
        while i < end {
          if BlockSyntax.closes(fence, lines[i]) {
            i += 1
            break
          }
          content.append(lines[i].strippingIndentation(fence.indentation))
          i += 1
        }
        result.append(
          .codeBlock(language: fence.info.isEmpty ? nil : fence.info, text: Self.join(content)))
        continue
      }
      if quotes, BlockSyntax.isQuote(line) {
        var inner: [Line] = []
        var openFence: Fence?
        while i < end {
          let next = lines[i]
          let content: Line
          if BlockSyntax.isQuote(next) {
            content = BlockSyntax.strippingQuote(next)
          } else if !next.isBlank, let last = inner.last, !last.isBlank, openFence == nil,
            BlockSyntax.openingFence(last) == nil, Self.isLazyContinuation(next)
          {
            content = next
          } else {
            break
          }
          if let fence = openFence {
            if BlockSyntax.closes(fence, content) { openFence = nil }
          } else {
            openFence = BlockSyntax.openingFence(content)
          }
          inner.append(content)
          i += 1
        }
        result.append(.quote(blocks(inner[...], depth: depth + 1, quoteDepth: quoteDepth + 1)))
        continue
      }
      if nests, !BlockSyntax.isThematicBreak(line), let first = BlockSyntax.listMarker(line) {
        let (list, next) = self.list(
          lines, from: i, first: first, depth: depth, quoteDepth: quoteDepth)
        result.append(list)
        i = next
        continue
      }
      // A paragraph.
      var paragraph = [line]
      i += 1
      while i < end {
        let next = lines[i]
        if next.isBlank || Self.interruptsParagraph(next, nests: nests, quotes: quotes) { break }
        paragraph.append(next)
        i += 1
      }
      result.append(.paragraph(paragraphContent(paragraph)))
    }
    return result
  }

  private func list(
    _ lines: ArraySlice<Line>, from start: Int, first: ListMarker, depth: Int, quoteDepth: Int
  ) -> (Block, Int) {
    var items: [ListItem] = []
    var i = start
    let end = lines.endIndex
    while i < end {
      let line = lines[i]
      guard !BlockSyntax.isThematicBreak(line), let marker = BlockSyntax.listMarker(line),
        marker.continues(first)
      else { break }
      var content: [Line] = marker.isEmpty ? [] : [Self.itemContent(line, marker)]
      var lastWasBlank = marker.isEmpty
      i += 1
      while i < end {
        let next = lines[i]
        if next.isBlank {
          // An item can start with at most one blank line.
          if marker.isEmpty, content.isEmpty { break }
          content.append(next.strippingIndentation(marker.contentColumn))
          lastWasBlank = true
          i += 1
          continue
        }
        if next.indentation.columns >= marker.contentColumn {
          content.append(next.strippingIndentation(marker.contentColumn))
          lastWasBlank = false
          i += 1
          continue
        }
        if !lastWasBlank, let last = content.last, BlockSyntax.openingFence(last) == nil,
          !Self.hasOpenFence(content), Self.isLazyContinuation(next)
        {
          content.append(next)
          i += 1
          continue
        }
        break
      }
      while content.last?.isBlank == true { content.removeLast() }
      var checked: Bool?
      if let firstLine = content.first, let (isChecked, rest) = Self.taskMarker(firstLine) {
        checked = isChecked
        content[0] = rest
      }
      items.append(
        ListItem(
          checked: checked,
          blocks: blocks(content[...], depth: depth + 1, quoteDepth: quoteDepth)))
      // Blank lines between items keep the list going.
      var lookahead = i
      while lookahead < end, lines[lookahead].isBlank { lookahead += 1 }
      if lookahead < end, lookahead > i, !BlockSyntax.isThematicBreak(lines[lookahead]),
        let next = BlockSyntax.listMarker(lines[lookahead]), next.continues(first)
      {
        i = lookahead
      }
    }
    let kind: ListKind =
      switch first.kind {
      case .bullet: .bullet
      case .ordered(let start, _): .ordered(start: start)
      }
    return (.list(kind, items: items), i)
  }

  /// The first line of an item, without its marker.
  private static func itemContent(_ line: Line, _ marker: ListMarker) -> Line {
    var blanked = line
    var index = line.indentation.count
    while index < blanked.count, !blanked[index].isSpaceOrTab {
      blanked[index] = " "
      index += 1
    }
    return blanked.strippingIndentation(marker.contentColumn)
  }

  /// `[ ]`, `[x]`, or `[X]` followed by whitespace or the end of the line.
  private static func taskMarker(_ line: Line) -> (Bool, Line)? {
    guard line.count >= 3, line[0] == "[", line[2] == "]",
      line[1] == " " || line[1] == "x" || line[1] == "X"
    else { return nil }
    if line.count == 3 { return (line[1] != " ", []) }
    guard line[3].isSpaceOrTab else { return nil }
    let rest = Line(line[4...])
    return (line[1] != " ", rest.isBlank ? [] : rest)
  }

  private static func hasOpenFence(_ lines: [Line]) -> Bool {
    var open: Fence?
    for line in lines {
      if let fence = open {
        if BlockSyntax.closes(fence, line) { open = nil }
      } else {
        open = BlockSyntax.openingFence(line)
      }
    }
    return open != nil
  }

  /// Whether a line would continue a paragraph rather than start a block.
  private static func isLazyContinuation(_ line: Line) -> Bool {
    if line.indentation.columns >= 4 { return true }
    return BlockSyntax.openingFence(line) == nil && !BlockSyntax.isQuote(line)
      && !BlockSyntax.isThematicBreak(line) && BlockSyntax.listMarker(line) == nil
  }

  private static func interruptsParagraph(_ line: Line, nests: Bool, quotes: Bool) -> Bool {
    guard line.indentation.columns < 4 else { return false }
    if BlockSyntax.openingFence(line) != nil { return true }
    if quotes, BlockSyntax.isQuote(line) { return true }
    if nests, !BlockSyntax.isThematicBreak(line), let marker = BlockSyntax.listMarker(line),
      !marker.isEmpty
    {
      if case .ordered(let start, _) = marker.kind { return start == 1 }
      return true
    }
    return false
  }

  private func paragraphContent(_ lines: [Line]) -> [Inline] {
    var source = Line()
    for (index, line) in lines.enumerated() {
      if index > 0 { source.append("\n") }
      source += line.trimmingSpacesAndTabs()
    }
    var parser = InlineParser(schema: schema, source: source)
    return parser.parse()
  }

  private static func join(_ lines: [Line]) -> String {
    var view = String.UnicodeScalarView()
    for (index, line) in lines.enumerated() {
      if index > 0 { view.append("\n") }
      view.append(contentsOf: line)
    }
    return String(view)
  }
}

/// A span the inline parser found, with the source ranges of its opening and
/// closing syntax; its content is between them. Typing converts with these
/// (see `MarkdownSupport.renderInline`).
struct InlineConversion: Sendable, Hashable {
  enum Kind: Sendable, Hashable {
    case mark(MarkKind)
    case link(String)
  }

  var kind: Kind
  var open: Range<Int>
  var close: Range<Int>

  init(_ kind: Kind, open: Range<Int>, close: Range<Int>) {
    self.kind = kind
    self.open = open
    self.close = close
  }

  var content: Range<Int> { open.upperBound..<close.lowerBound }
}

/// The inline parser: CommonMark's delimiter algorithm for `*`, `_`, and `~`,
/// with code spans, links, autolinks, escapes, character references, and
/// node codecs.
struct InlineParser {
  private enum Kind {
    case text, delimiter, bracket, code
    case node(AtomicNode)
    case autolink(String)
  }

  private struct Item {
    var kind: Kind
    var text = String.UnicodeScalarView()
  }

  private struct Delimiter {
    let item: Int
    /// The run's first scalar in the source, and how many of its first
    /// scalars closing used.
    let start: Int
    var closed = 0
    let character: Unicode.Scalar
    var count: Int
    let originalCount: Int
    let canOpen: Bool
    let canClose: Bool
    var previous: Int
    var next: Int
  }

  private struct Bracket {
    let item: Int
    /// The `[` in the source.
    let start: Int
    let isImage: Bool
    var isActive = true
    /// The top of the delimiter stack when the bracket opened.
    let delimiterBottom: Int
  }

  private enum SpanKind {
    case mark(MarkKind)
    case link(String)
  }

  let schema: Schema
  private let s: [Unicode.Scalar]
  private var items: [Item] = []
  private var delimiters: [Delimiter] = []
  private var top = -1
  private var brackets: [Bracket] = []
  private var spans: [(range: Range<Int>, kind: SpanKind)] = []
  /// Each span with the source ranges of its delimiters, in the order the
  /// spans close.
  private(set) var conversions: [InlineConversion] = []
  private let triggers: [Unicode.Scalar: [NodeType]]

  init(schema: Schema, source: [Unicode.Scalar]) {
    self.schema = schema
    self.s = source
    var triggers: [Unicode.Scalar: [NodeType]] = [:]
    for type in schema.customCodecs {
      if case .custom(let set, _, _) = schema.nodes[type]!.markdown.kind {
        for scalar in set { triggers[scalar, default: []].append(type) }
      }
    }
    self.triggers = triggers
  }

  mutating func parse() -> [Inline] {
    var i = 0
    while i < s.count {
      let c = s[i]
      if let types = triggers[c], let (node, end) = decodeCustom(types, at: i) {
        items.append(Item(kind: .node(node)))
        i = end
        continue
      }
      switch c {
      case "\\":
        if i + 1 < s.count, s[i + 1] == "\n" || s[i + 1].isASCIIPunctuation {
          appendText(s[i + 1])
          i += 2
        } else {
          appendText(c)
          i += 1
        }
      case "`":
        i = codeSpan(at: i)
      case "*", "_", "~":
        i = delimiterRun(at: i)
      case "[":
        brackets.append(
          Bracket(item: items.count, start: i, isImage: false, delimiterBottom: top))
        items.append(Item(kind: .bracket, text: "[".unicodeScalars))
        i += 1
      case "!" where i + 1 < s.count && s[i + 1] == "[":
        brackets.append(
          Bracket(item: items.count, start: i, isImage: true, delimiterBottom: top))
        items.append(Item(kind: .bracket, text: "![".unicodeScalars))
        i += 2
      case "]":
        i = closeBracket(at: i)
      case "<":
        if let (uri, end) = Self.autolink(s, at: i) {
          items.append(Item(kind: .autolink(uri)))
          conversions.append(InlineConversion(.link(uri), open: i..<i + 1, close: end - 1..<end))
          i = end
        } else {
          appendText(c)
          i += 1
        }
      case "&":
        if let (scalar, end) = CharacterReference.decode(s, at: i) {
          appendText(scalar)
          i = end
        } else {
          appendText(c)
          i += 1
        }
      case ":":
        if let (node, end) = directive(at: i) {
          items.append(Item(kind: .node(node)))
          i = end
        } else {
          appendText(c)
          i += 1
        }
      default:
        appendText(c)
        i += 1
      }
    }
    processEmphasis(above: -1)
    return build()
  }

  private mutating func appendText(_ scalar: Unicode.Scalar) {
    if case .text? = items.last?.kind {
      items[items.count - 1].text.append(scalar)
    } else {
      var item = Item(kind: .text)
      item.text.append(scalar)
      items.append(item)
    }
  }

  // MARK: Code spans

  private mutating func codeSpan(at start: Int) -> Int {
    var i = start
    while i < s.count, s[i] == "`" { i += 1 }
    let length = i - start
    var j = i
    while j < s.count {
      guard s[j] == "`" else {
        j += 1
        continue
      }
      var k = j
      while k < s.count, s[k] == "`" { k += 1 }
      if k - j == length {
        var content = s[i..<j].map { $0 == "\n" ? " " : $0 }
        var strip = 0
        if content.count >= 2, content.first == " ", content.last == " ",
          content.contains(where: { $0 != " " })
        {
          content = Array(content.dropFirst().dropLast())
          strip = 1
        }
        items.append(Item(kind: .code, text: String.UnicodeScalarView(content)))
        conversions.append(
          InlineConversion(.mark(.code), open: start..<i + strip, close: j - strip..<k))
        return k
      }
      j = k
    }
    for _ in 0..<length { appendText("`") }
    return i
  }

  // MARK: Emphasis

  private mutating func delimiterRun(at start: Int) -> Int {
    let c = s[start]
    var i = start
    while i < s.count, s[i] == c { i += 1 }
    let count = i - start
    let before: Unicode.Scalar = start > 0 ? s[start - 1] : "\n"
    let after: Unicode.Scalar = i < s.count ? s[i] : "\n"
    let left =
      !after.isMarkdownWhitespace
      && (!after.isMarkdownPunctuation || before.isMarkdownWhitespace
        || before.isMarkdownPunctuation)
    let right =
      !before.isMarkdownWhitespace
      && (!before.isMarkdownPunctuation || after.isMarkdownWhitespace
        || after.isMarkdownPunctuation)
    var canOpen = left
    var canClose = right
    if c == "_" {
      canOpen = left && (!right || before.isMarkdownPunctuation)
      canClose = right && (!left || after.isMarkdownPunctuation)
    }
    if c == "~", count > 2 {
      canOpen = false
      canClose = false
    }
    var item = Item(kind: canOpen || canClose ? .delimiter : .text)
    for _ in 0..<count { item.text.append(c) }
    if canOpen || canClose {
      let index = delimiters.count
      delimiters.append(
        Delimiter(
          item: items.count, start: start, character: c, count: count, originalCount: count,
          canOpen: canOpen,
          canClose: canClose, previous: top, next: -1))
      if top >= 0 { delimiters[top].next = index }
      top = index
      items.append(item)
    } else {
      for scalar in item.text { appendText(scalar) }
    }
    return i
  }

  private mutating func remove(_ index: Int) {
    let previous = delimiters[index].previous
    let next = delimiters[index].next
    if previous >= 0 { delimiters[previous].next = next }
    if next >= 0 {
      delimiters[next].previous = previous
    } else {
      top = previous
    }
  }

  /// Matches delimiters above `bottom` (a delimiter index, exclusive), then
  /// removes them from the stack.
  private mutating func processEmphasis(above bottom: Int) {
    // The first delimiter above `bottom`.
    var closer = top
    while closer >= 0, delimiters[closer].previous > bottom { closer = delimiters[closer].previous }
    if closer <= bottom { closer = -1 }
    var openersBottom: [Int: Int] = [:]
    while closer >= 0 {
      let close = delimiters[closer]
      guard close.canClose else {
        closer = close.next
        continue
      }
      let key =
        Int(close.character.value) * 8 + (close.canOpen ? 4 : 0)
        + (close.character == "~" ? close.count % 4 : close.originalCount % 3)
      let limit = max(bottom, openersBottom[key] ?? bottom)
      var opener = close.previous
      var found = false
      while opener > limit {
        let open = delimiters[opener]
        if open.character == close.character, open.canOpen {
          if close.character == "~" {
            found = open.count == close.count
          } else {
            let oddMatch =
              (close.canOpen || open.canClose) && close.originalCount % 3 != 0
              && (open.originalCount + close.originalCount) % 3 == 0
            found = !oddMatch
          }
          if found { break }
        }
        opener = open.previous
      }
      guard found else {
        openersBottom[key] = close.previous
        let next = close.next
        if !close.canOpen { remove(closer) }
        closer = next
        continue
      }
      let use: Int
      let kind: MarkKind
      if close.character == "~" {
        use = close.count
        kind = .strikethrough
      } else {
        use = delimiters[opener].count >= 2 && close.count >= 2 ? 2 : 1
        kind = use == 2 ? .bold : .italic
      }
      delimiters[opener].count -= use
      delimiters[closer].count -= use
      let openItem = delimiters[opener].item
      let closeItem = close.item
      items[openItem].text.removeLast(use)
      items[closeItem].text.removeFirst(use)
      spans.append((openItem + 1..<closeItem, .mark(kind)))
      // The opener gives its last characters, the closer its first.
      let openStart =
        delimiters[opener].start + delimiters[opener].closed + delimiters[opener].count
      let closeStart = close.start + close.closed
      delimiters[closer].closed += use
      conversions.append(
        InlineConversion(
          .mark(kind), open: openStart..<openStart + use, close: closeStart..<closeStart + use))
      // Delimiters between the two are literal now.
      delimiters[opener].next = closer
      delimiters[closer].previous = opener
      if delimiters[opener].count == 0 { remove(opener) }
      if delimiters[closer].count == 0 {
        let next = delimiters[closer].next
        remove(closer)
        closer = next
      }
    }
    while top > bottom { remove(top) }
  }

  // MARK: Links

  private mutating func closeBracket(at i: Int) -> Int {
    guard let bracket = brackets.popLast() else {
      appendText("]")
      return i + 1
    }
    guard bracket.isActive, let (url, end) = Self.destination(s, at: i + 1) else {
      appendText("]")
      return i + 1
    }
    if bracket.isImage {
      // Images are not supported: the whole image stays literal text.
      appendText("]")
      for scalar in s[(i + 1)..<end] { appendText(scalar) }
      return end
    }
    processEmphasis(above: bracket.delimiterBottom)
    items[bracket.item].text = String.UnicodeScalarView()
    spans.append((bracket.item + 1..<items.count, .link(url)))
    conversions.append(
      InlineConversion(.link(url), open: bracket.start..<bracket.start + 1, close: i..<end))
    for index in brackets.indices where !brackets[index].isImage {
      brackets[index].isActive = false
    }
    // Text after the link starts a new item, outside the link's range.
    items.append(Item(kind: .text))
    return end
  }

  /// An inline link destination without a title, `(url)` or `(<url>)`, at
  /// `start`. Returns the decoded URL and the index after the `)`. A link
  /// with a title is not supported, so it returns `nil`.
  static func destination(_ s: [Unicode.Scalar], at start: Int) -> (String, Int)? {
    guard start < s.count, s[start] == "(" else { return nil }
    var i = start + 1
    func skipWhitespace() {
      var newlines = 0
      while i < s.count, s[i].isSpaceOrTab || (s[i] == "\n" && newlines == 0) {
        if s[i] == "\n" { newlines += 1 }
        i += 1
      }
    }
    skipWhitespace()
    var url = Line()
    if i < s.count, s[i] == "<" {
      i += 1
      while true {
        guard i < s.count, s[i] != "\n", s[i] != "<" else { return nil }
        if s[i] == ">" {
          i += 1
          break
        }
        if s[i] == "\\", i + 1 < s.count, s[i + 1].isASCIIPunctuation {
          url.append(s[i + 1])
          i += 2
        } else if s[i] == "&", let (scalar, end) = CharacterReference.decode(s, at: i) {
          url.append(scalar)
          i = end
        } else {
          url.append(s[i])
          i += 1
        }
      }
    } else {
      var depth = 0
      while i < s.count {
        let c = s[i]
        if c.value <= 0x20 || c.value == 0x7F { break }
        if c == "\\", i + 1 < s.count, s[i + 1].isASCIIPunctuation {
          url.append(s[i + 1])
          i += 2
          continue
        }
        if c == "&", let (scalar, end) = CharacterReference.decode(s, at: i) {
          url.append(scalar)
          i = end
          continue
        }
        if c == "(" {
          depth += 1
          if depth > 32 { return nil }
        }
        if c == ")" {
          if depth == 0 { break }
          depth -= 1
        }
        url.append(c)
        i += 1
      }
      if depth != 0 { return nil }
    }
    skipWhitespace()
    guard i < s.count, s[i] == ")" else { return nil }
    return (String(scalars: url), i + 1)
  }

  /// A URI autolink, `<scheme:…>`, at `start`.
  static func autolink(_ s: [Unicode.Scalar], at start: Int) -> (String, Int)? {
    var i = start + 1
    guard i < s.count, s[i].isASCIILetter else { return nil }
    let schemeStart = i
    while i < s.count,
      s[i].isASCIILetter || s[i].isASCIIDigit || s[i] == "+" || s[i] == "."
        || s[i] == "-"
    {
      i += 1
    }
    guard (2...32).contains(i - schemeStart), i < s.count, s[i] == ":" else { return nil }
    while i < s.count, s[i] != ">" {
      if s[i].value <= 0x20 || s[i] == "<" { return nil }
      i += 1
    }
    guard i < s.count else { return nil }
    return (String(scalars: s[(start + 1)..<i]), i + 1)
  }

  // MARK: Nodes

  /// A text directive, `:name[label]{attributes}`, whose name is registered.
  private func directive(at start: Int) -> (AtomicNode, Int)? {
    if start > 0, s[start - 1] == ":" { return nil }
    return Self.directive(s, at: start, schema: schema)
  }

  static func directive(_ s: [Unicode.Scalar], at start: Int, schema: Schema) -> (AtomicNode, Int)?
  {
    var i = start + 1
    guard i < s.count, s[i].isASCIILetter else { return nil }
    while i < s.count, s[i].isASCIILetter || s[i].isASCIIDigit || s[i] == "-" || s[i] == "_" {
      i += 1
    }
    let name = String(scalars: s[(start + 1)..<i])
    guard let type = schema.directives[name], i < s.count, s[i] == "[" else { return nil }
    i += 1
    var label = Line()
    var depth = 0
    while true {
      guard i < s.count, s[i] != "\n" else { return nil }
      let c = s[i]
      if c == "\\", i + 1 < s.count, s[i + 1].isASCIIPunctuation {
        label.append(s[i + 1])
        i += 2
        continue
      }
      if c == "[" { depth += 1 }
      if c == "]" {
        if depth == 0 { break }
        depth -= 1
      }
      label.append(c)
      i += 1
    }
    i += 1
    var attributes: [String: String] = [:]
    if i < s.count, s[i] == "{" {
      guard let (parsed, end) = directiveAttributes(s, at: i) else { return nil }
      attributes = parsed
      i = end
    }
    return (AtomicNode(type: type, label: String(scalars: label), attributes: attributes), i)
  }

  /// `{#id .class key="value" key=value key}`, at `start` (a `{`).
  private static func directiveAttributes(
    _ s: [Unicode.Scalar], at start: Int
  )
    -> ([String: String], Int)?
  {
    var attributes: [String: String] = [:]
    var classes: [String] = []
    var i = start + 1
    func isShorthand(_ c: Unicode.Scalar) -> Bool {
      !c.isMarkdownWhitespace && !"\"'<>=`{}.#".unicodeScalars.contains(c)
    }
    func isNameStart(_ c: Unicode.Scalar) -> Bool { c.isASCIILetter || c == "_" || c == ":" }
    func isName(_ c: Unicode.Scalar) -> Bool {
      isNameStart(c) || c.isASCIIDigit || c == "." || c == "-"
    }
    while true {
      while i < s.count, s[i].isSpaceOrTab { i += 1 }
      guard i < s.count else { return nil }
      let c = s[i]
      if c == "}" { break }
      if c == "#" || c == "." {
        i += 1
        let valueStart = i
        while i < s.count, isShorthand(s[i]) { i += 1 }
        guard i > valueStart else { return nil }
        let value = String(scalars: s[valueStart..<i])
        if c == "#" { attributes["id"] = value } else { classes.append(value) }
        continue
      }
      guard isNameStart(c) else { return nil }
      let nameStart = i
      while i < s.count, isName(s[i]) { i += 1 }
      let name = String(scalars: s[nameStart..<i])
      guard i < s.count, s[i] == "=" else {
        attributes[name] = ""
        continue
      }
      i += 1
      guard i < s.count else { return nil }
      var value = Line()
      if s[i] == "\"" || s[i] == "'" {
        let quote = s[i]
        i += 1
        while true {
          guard i < s.count, s[i] != "\n" else { return nil }
          if s[i] == quote { break }
          if s[i] == "&", let (scalar, end) = CharacterReference.decode(s, at: i) {
            value.append(scalar)
            i = end
          } else {
            value.append(s[i])
            i += 1
          }
        }
        i += 1
      } else {
        while i < s.count, !s[i].isMarkdownWhitespace, !"\"'=<>`}".unicodeScalars.contains(s[i]) {
          value.append(s[i])
          i += 1
        }
        guard !value.isEmpty else { return nil }
      }
      if name == "class" {
        classes.append(String(scalars: value))
      } else {
        attributes[name] = String(scalars: value)
      }
    }
    if !classes.isEmpty { attributes["class"] = classes.joined(separator: " ") }
    return (attributes, i + 1)
  }

  private func decodeCustom(_ types: [NodeType], at start: Int) -> (AtomicNode, Int)? {
    var end = start
    while end < s.count, s[end] != "\n", end - start < 1024 { end += 1 }
    let rest = String(scalars: s[start..<end])[...]
    for type in types {
      guard case .custom(_, _, let decode) = schema.nodes[type]!.markdown.kind,
        let (node, index) = decode(rest), index > rest.startIndex
      else { continue }
      return (node, start + rest.unicodeScalars.distance(from: rest.startIndex, to: index))
    }
    return nil
  }

  // MARK: Output

  private func build() -> [Inline] {
    let count = items.count
    var bold = [Int](repeating: 0, count: count + 1)
    var italic = bold
    var strikethrough = bold
    var links = [String?](repeating: nil, count: count)
    for (range, kind) in spans where !range.isEmpty {
      switch kind {
      case .mark(.bold):
        bold[range.lowerBound] += 1
        bold[range.upperBound] -= 1
      case .mark(.italic):
        italic[range.lowerBound] += 1
        italic[range.upperBound] -= 1
      case .mark(.strikethrough), .mark(.code):
        strikethrough[range.lowerBound] += 1
        strikethrough[range.upperBound] -= 1
      case .link(let url):
        for index in range where links[index] == nil { links[index] = url }
      }
    }
    var result: [Inline] = []
    result.reserveCapacity(count)
    var (b, it, st) = (0, 0, 0)
    for index in 0..<count {
      b += bold[index]
      it += italic[index]
      st += strikethrough[index]
      var marks = Marks(bold: b > 0, italic: it > 0, strikethrough: st > 0, link: links[index])
      let item = items[index]
      switch item.kind {
      case .text, .delimiter, .bracket:
        Normalizer.append(.text(String(item.text), marks: marks), to: &result)
      case .code:
        marks.code = true
        Normalizer.append(.text(String(item.text), marks: marks), to: &result)
      case .autolink(let uri):
        marks.link = uri
        Normalizer.append(.text(uri, marks: marks), to: &result)
      case .node(let node):
        result.append(.node(node))
      }
    }
    return result
  }
}
