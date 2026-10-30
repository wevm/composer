// The markdown writer: canonical export, escaping only what the parser would
// read as syntax.

struct MarkdownWriter {
  let schema: Schema

  mutating func write(_ document: Document) -> String {
    lines(document.blocks, firstIsItemStart: false).joined(separator: "\n")
  }

  // MARK: Blocks

  private func lines(_ blocks: [Block], firstIsItemStart: Bool) -> [String] {
    var result: [String] = []
    // Adjacent lists of the same kind alternate markers, or they would merge.
    var previousList: (ordered: Bool, alternate: Bool)?
    var previousIsParagraph = false
    for (index, block) in blocks.enumerated() {
      var blockLines: [String]
      var list: (ordered: Bool, alternate: Bool)?
      switch block {
      case .paragraph(let content):
        blockLines = paragraph(content, isItemStart: firstIsItemStart && index == 0)
      case .codeBlock(let language, let text):
        blockLines = codeBlock(language: language, text: text)
      case .quote(let children):
        blockLines = lines(children, firstIsItemStart: false).map { $0.isEmpty ? ">" : "> " + $0 }
      case .list(let kind, let items):
        var ordered = false
        if case .ordered = kind { ordered = true }
        let alternate = previousList.map { $0.ordered == ordered && !$0.alternate } ?? false
        list = (ordered, alternate)
        blockLines = self.list(kind, items, alternate: alternate)
      case .unknown(let node):
        blockLines = paragraph([.text(node.text)], isItemStart: firstIsItemStart && index == 0)
      }
      previousList = list
      defer {
        if case .paragraph = block {
          previousIsParagraph = true
        } else {
          previousIsParagraph = false
        }
      }
      if blockLines.isEmpty { continue }
      // In an item, a list right after a paragraph is written tight, as a
      // chat message's nested list is: a bullet list, or one that starts at
      // 1, can interrupt the paragraph.
      let tight: Bool
      switch block {
      case .list(.bullet, _), .list(.ordered(start: 1), _):
        // An empty first item (a marker alone) can't interrupt.
        tight = firstIsItemStart && previousIsParagraph && blockLines[0].contains(" ")
      default:
        tight = false
      }
      if !result.isEmpty, !tight { result.append("") }
      result += blockLines
    }
    return result
  }

  private func list(_ kind: ListKind, _ items: [ListItem], alternate: Bool) -> [String] {
    var result: [String] = []
    for (index, item) in items.enumerated() {
      let marker: String
      switch kind {
      case .bullet:
        marker = alternate ? "*" : "-"
      case .ordered(let start):
        let number = min(start + index, Document.maxOrderedStart)
        marker = "\(number)" + (alternate ? ")" : ".")
      }
      let indent = String(repeating: " ", count: marker.count + 1)
      var content = lines(item.blocks, firstIsItemStart: true)
      var first = marker
      if let checked = item.checked {
        first += checked ? " [x]" : " [ ]"
        if case .paragraph? = item.blocks.first, !content.isEmpty {
          first += " " + content.removeFirst()
        }
      } else if !content.isEmpty {
        first += " " + content.removeFirst()
      }
      // `- ---` or `- - -` would be a thematic break, so the item starts
      // with a blank line instead. (A task marker has brackets, so only plain
      // items get here.)
      if BlockSyntax.isThematicBreak(Line(first.unicodeScalars)) {
        result.append(marker)
        result.append(indent + first.dropFirst(marker.count + 1))
      } else {
        result.append(first)
      }
      for line in content { result.append(line.isEmpty ? "" : indent + line) }
    }
    return result
  }

  private func codeBlock(language: String?, text: String) -> [String] {
    let language = language ?? ""
    let character: Character = language.contains("`") ? "~" : "`"
    var longest = 0
    var run = 0
    for c in text {
      run = c == character ? run + 1 : 0
      longest = max(longest, run)
    }
    let fence = String(repeating: character, count: max(3, longest + 1))
    var result = [fence + language]
    if !text.isEmpty {
      result += text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
    result.append(fence)
    return result
  }

  // MARK: Paragraphs

  private func paragraph(_ content: [Inline], isItemStart: Bool) -> [String] {
    guard !content.isEmpty else { return [] }
    var rendered = render(content, conservative: false, isItemStart: isItemStart)
    // The minimal escaping is checked by parsing it back; if it would not
    // round-trip, every punctuation character in text is escaped instead.
    if isRoundTripCheckable(content) {
      var parser = BlockParser(schema: schema)
      let parsed = Document(blocks: parser.parse(rendered)).normalized().blocks
      if parsed != [.paragraph(content)] {
        rendered = render(content, conservative: true, isItemStart: isItemStart)
      }
    }
    return rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  /// Unknown and unregistered nodes do not parse back, so there is nothing to
  /// compare.
  private func isRoundTripCheckable(_ content: [Inline]) -> Bool {
    for inline in content {
      switch inline {
      case .text: continue
      case .unknown: return false
      case .node(let node): if schema.nodes[node.type] == nil { return false }
      }
    }
    return true
  }

  private enum Escape { case none, backslash, entity }

  private enum TokenKind {
    case text(Unicode.Scalar)
    /// An emphasis delimiter. `pair` links an opener and its closer.
    case delimiter(MarkKind, isOpen: Bool, pair: Int)
    case linkOpen
    case linkClose(String)
    case raw(String)
  }

  private struct Token {
    var kind: TokenKind
    var escape = Escape.none
    var insideLink = false
    /// The delimiter's spelling, for emphasis delimiters.
    var spelling = ""
    /// For a node's output: the node it encodes.
    var node: AtomicNode?

    var text: Unicode.Scalar? {
      if case .text(let c) = kind { return c }
      return nil
    }

    var output: String {
      switch kind {
      case .text(let c):
        switch escape {
        case .none: return String(c)
        case .backslash: return "\\" + String(c)
        case .entity: return CharacterReference.encode(c)
        }
      case .delimiter: return spelling
      case .linkOpen: return "["
      case .linkClose(let destination): return "](" + destination + ")"
      case .raw(let raw): return raw
      }
    }

    var first: Unicode.Scalar? {
      switch kind {
      case .text(let c): escape == .none ? c : escape == .backslash ? "\\" : "&"
      case .delimiter: spelling.unicodeScalars.first
      case .linkOpen: "["
      case .linkClose: "]"
      case .raw(let raw): raw.unicodeScalars.first
      }
    }

    var last: Unicode.Scalar? {
      switch kind {
      case .text(let c): escape == .entity ? ";" : c
      case .delimiter: spelling.unicodeScalars.last
      case .linkOpen: "["
      case .linkClose: ")"
      case .raw(let raw): raw.unicodeScalars.last
      }
    }

    var isEmpty: Bool {
      if case .raw(let raw) = kind { return raw.isEmpty }
      return false
    }
  }

  private func render(_ content: [Inline], conservative: Bool, isItemStart: Bool) -> String {
    var tokens = tokenize(content)
    decide(&tokens, conservative: conservative, isItemStart: isItemStart)
    var result = ""
    for token in tokens { result += token.output }
    return result
  }

  // MARK: Tokens

  private struct Span {
    var mark: SpanMark
    var start: Int
    var end: Int  // inclusive run index
  }

  private enum SpanMark: Equatable {
    case emphasis(MarkKind)
    case link(String)

    /// Openers at the same run open in this order: links innermost.
    var order: Int {
      switch self {
      case .emphasis(.bold): 0
      case .emphasis(.italic): 1
      case .emphasis(.strikethrough): 2
      case .emphasis(.code): 3
      case .link: 4
      }
    }
  }

  private func tokenize(_ runs: [Inline]) -> [Token] {
    // Maximal spans of each mark over the runs.
    var spans: [Span] = []
    for kind in [MarkKind.bold, .italic, .strikethrough] {
      var start: Int?
      for (index, run) in runs.enumerated() {
        var on = false
        if case .text(_, let marks) = run { on = marks[kind] }
        if on, start == nil { start = index }
        if !on, let s = start {
          spans.append(Span(mark: .emphasis(kind), start: s, end: index - 1))
          start = nil
        }
      }
      if let s = start { spans.append(Span(mark: .emphasis(kind), start: s, end: runs.count - 1)) }
    }
    var linkStart: (Int, String)?
    for (index, run) in runs.enumerated() {
      var url: String?
      if case .text(_, let marks) = run { url = marks.link }
      if let (s, open) = linkStart, url != open {
        spans.append(Span(mark: .link(open), start: s, end: index - 1))
        linkStart = nil
      }
      if let url, linkStart == nil { linkStart = (index, url) }
    }
    if let (s, open) = linkStart {
      spans.append(Span(mark: .link(open), start: s, end: runs.count - 1))
    }
    spans.sort { ($0.start, -$0.end, $0.mark.order) < ($1.start, -$1.end, $1.mark.order) }

    var tokens: [Token] = []
    var stack: [Span] = []
    var nextPair = 0
    var pairs: [Int] = []  // the pair id of each open stack entry
    var autolinkOpen = false
    var spanIndex = 0
    var linkDepth = 0

    func open(_ span: Span, tokens: inout [Token]) {
      switch span.mark {
      case .emphasis(let kind):
        tokens.append(Token(kind: .delimiter(kind, isOpen: true, pair: nextPair)))
        pairs.append(nextPair)
        nextPair += 1
      case .link:
        tokens.append(Token(kind: .linkOpen))
        pairs.append(-1)
        linkDepth += 1
      }
      stack.append(span)
    }

    func close(tokens: inout [Token]) {
      let span = stack.removeLast()
      let pair = pairs.removeLast()
      switch span.mark {
      case .emphasis(let kind):
        tokens.append(Token(kind: .delimiter(kind, isOpen: false, pair: pair)))
      case .link(let url):
        linkDepth -= 1
        if autolinkOpen {
          autolinkOpen = false
        } else {
          tokens.append(Token(kind: .linkClose(Self.destination(url))))
        }
      }
    }

    for (index, run) in runs.enumerated() {
      while spanIndex < spans.count, spans[spanIndex].start == index {
        let span = spans[spanIndex]
        spanIndex += 1
        if case .link(let url) = span.mark, span.start == span.end,
          case .text(let text, let marks) = run, !marks.code, text == url, Self.isAutolinkable(url)
        {
          stack.append(span)
          pairs.append(-1)
          linkDepth += 1
          autolinkOpen = true
          continue
        }
        open(span, tokens: &tokens)
      }
      let inside = linkDepth > 0
      switch run {
      case .text(let text, let marks):
        if autolinkOpen {
          tokens.append(Token(kind: .raw("<" + text + ">")))
        } else if marks.code {
          tokens.append(Token(kind: .raw(Self.codeSpan(text))))
        } else {
          for scalar in text.unicodeScalars {
            tokens.append(Token(kind: .text(scalar), insideLink: inside))
          }
        }
      case .node(let node):
        tokens.append(Token(kind: .raw(encode(node)), node: node))
      case .unknown(let node):
        for scalar in node.text.unicodeScalars {
          tokens.append(Token(kind: .text(scalar), insideLink: inside))
        }
      }
      // Close the spans that end here; spans above them close and reopen.
      var ending = stack.filter { $0.end == index }.count
      var reopen: [Span] = []
      while ending > 0 {
        let span = stack.last!
        close(tokens: &tokens)
        if span.end == index {
          ending -= 1
        } else {
          reopen.append(span)
        }
      }
      for span in reopen.reversed() { open(span, tokens: &tokens) }
    }
    return tokens
  }

  private func encode(_ node: AtomicNode) -> String {
    if let spec = schema.nodes[node.type] {
      switch spec.markdown.kind {
      case .directive(let name): return Self.directive(name, node)
      case .custom(_, let encode, _): return encode(node)
      }
    }
    return Self.directive(node.type.rawValue, node)
  }

  static func directive(_ name: String, _ node: AtomicNode) -> String {
    var result = ":" + name + "["
    for c in node.label.unicodeScalars {
      if c == "\\" || c == "[" || c == "]" { result += "\\" }
      result.unicodeScalars.append(c)
    }
    result += "]"
    var parts: [String] = []
    var attributes = node.attributes
    if let id = attributes.removeValue(forKey: "id") {
      if !id.isEmpty,
        id.unicodeScalars.allSatisfy({
          $0.isASCIILetter || $0.isASCIIDigit || $0 == "_" || $0 == "-"
        })
      {
        parts.append("#" + id)
      } else {
        parts.append("id=" + quoted(id))
      }
    }
    for key in attributes.keys.sorted() where isAttributeName(key) {
      parts.append(key + "=" + quoted(attributes[key]!))
    }
    if !parts.isEmpty { result += "{" + parts.joined(separator: " ") + "}" }
    return result
  }

  /// Attribute names are `[A-Za-z_:][A-Za-z0-9_.:-]*`; others can't be
  /// written, so they are left out.
  static func isAttributeName(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first,
      first.isASCIILetter || first == "_" || first == ":"
    else { return false }
    return key.unicodeScalars.allSatisfy {
      $0.isASCIILetter || $0.isASCIIDigit || "_.:-".unicodeScalars.contains($0)
    }
  }

  private static func quoted(_ value: String) -> String {
    var result = "\""
    for c in value.unicodeScalars {
      switch c {
      case "&": result += "&amp;"
      case "\"": result += "&quot;"
      case "\n": result += "&#10;"
      case "\r": result += "&#13;"
      default: result.unicodeScalars.append(c)
      }
    }
    return result + "\""
  }

  static func codeSpan(_ text: String) -> String {
    var longest = 0
    var run = 0
    for c in text.unicodeScalars {
      run = c == "`" ? run + 1 : 0
      longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: longest + 1)
    let scalars = text.unicodeScalars
    let pads =
      scalars.first == "`" || scalars.last == "`"
      || (scalars.first == " " && scalars.last == " " && scalars.contains { $0 != " " })
    return pads ? fence + " " + text + " " + fence : fence + text + fence
  }

  static func isAutolinkable(_ url: String) -> Bool {
    let s = Array(url.unicodeScalars)
    guard !s.contains(where: { $0 == "\\" || $0 == "&" }),
      let (uri, end) = InlineParser.autolink(["<"] + s + [">"], at: 0)
    else { return false }
    return uri == url && end == s.count + 2
  }

  static func destination(_ url: String) -> String {
    let s = Array(url.unicodeScalars)
    let pointy = s.contains { $0.value <= 0x20 || $0.value == 0x7F }
    var result = pointy ? "<" : ""
    for (index, c) in s.enumerated() {
      switch c {
      case "\\", "(", ")", "<", ">":
        result += "\\"
      case "&" where CharacterReference.decode(s, at: index) != nil:
        result += "\\"
      default:
        break
      }
      result.unicodeScalars.append(c)
    }
    return pointy ? result + ">" : result
  }

  // MARK: Escaping

  private func decide(_ tokens: inout [Token], conservative: Bool, isItemStart: Bool) {
    // Updated when hard breaks are inserted; the helpers below read it.
    var count = tokens.count
    func previous(_ index: Int) -> Unicode.Scalar? {
      var i = index - 1
      while i >= 0, tokens[i].isEmpty { i -= 1 }
      return i >= 0 ? tokens[i].last : nil
    }
    func next(_ index: Int) -> Unicode.Scalar? {
      var i = index + 1
      while i < count, tokens[i].isEmpty { i += 1 }
      return i < count ? tokens[i].first : nil
    }
    func isWhitespace(_ c: Unicode.Scalar?) -> Bool { c?.isMarkdownWhitespace ?? true }
    func isPunctuation(_ c: Unicode.Scalar?) -> Bool { c?.isMarkdownPunctuation ?? false }
    func isWord(_ c: Unicode.Scalar?) -> Bool { !isWhitespace(c) && !isPunctuation(c) }
    func isBold(_ index: Int) -> Bool {
      guard index >= 0, index < count, case .delimiter(.bold, _, _) = tokens[index].kind else {
        return false
      }
      return true
    }
    /// The text scalars from `index` until the next non-text token.
    func text(from index: Int, limit: Int = 1024) -> [Unicode.Scalar] {
      var result: [Unicode.Scalar] = []
      var i = index
      while i < count, result.count < limit, let c = tokens[i].text {
        result.append(c)
        i += 1
      }
      return result
    }

    // 1. Delimiter spellings. Italic is `_`, or `*` inside a word, where `_`
    //    can't open or close, unless `*` would touch a bold delimiter.
    var italicOpeners: [Int: Int] = [:]
    for index in 0..<count {
      guard case .delimiter(let kind, let isOpen, let pair) = tokens[index].kind else { continue }
      switch kind {
      case .bold: tokens[index].spelling = "**"
      case .strikethrough: tokens[index].spelling = "~~"
      case .italic, .code:
        tokens[index].spelling = "_"
        if isOpen {
          italicOpeners[pair] = index
          continue
        }
        guard !conservative, let opener = italicOpeners[pair] else { continue }
        let intraword = isWord(previous(opener)) || isWord(next(index))
        let touchesBold =
          isBold(opener - 1) || isBold(opener + 1) || isBold(index - 1) || isBold(index + 1)
        if intraword, !touchesBold {
          tokens[opener].spelling = "*"
          tokens[index].spelling = "*"
        }
      }
    }

    // 2. Line starts and ends: edge whitespace becomes a character
    //    reference, empty lines become hard breaks, and block syntax is
    //    escaped.
    var hardBreaks: [Int] = []
    var lineStart = 0
    var index = 0
    while index <= count {
      let atEnd = index == count
      if atEnd || tokens[index].text == "\n" {
        if index == lineStart {
          if !atEnd { hardBreaks.append(index) }
        } else {
          if let c = tokens[lineStart].text, c.isSpaceOrTab { tokens[lineStart].escape = .entity }
          if let c = tokens[index - 1].text, c.isSpaceOrTab { tokens[index - 1].escape = .entity }
          escapeBlockSyntax(
            &tokens, from: lineStart, to: index, isItemStart: isItemStart && lineStart == 0)
        }
        lineStart = index + 1
      }
      index += 1
    }
    for position in hardBreaks.reversed() {
      tokens.insert(Token(kind: .raw("\\")), at: position)
    }
    count = tokens.count
    let total = count

    // 3. Characters that start inline syntax.
    for index in 0..<total {
      guard let c = tokens[index].text, tokens[index].escape == .none else { continue }
      if conservative {
        if c.isASCIIPunctuation, c != "\\" { tokens[index].escape = .backslash }
        continue
      }
      switch c {
      case "`":
        tokens[index].escape = .backslash
      case "[", "]":
        if tokens[index].insideLink {
          tokens[index].escape = .backslash
        } else if c == "[", !(index > 0 && tokens[index - 1].text == "!"),
          opensLink(tokens, at: index)
        {
          tokens[index].escape = .backslash
        }
      case "!":
        if index + 1 < total, case .linkOpen = tokens[index + 1].kind {
          tokens[index].escape = .backslash
        }
      case "<":
        if InlineParser.autolink(text(from: index), at: 0) != nil {
          tokens[index].escape = .backslash
        }
      case "&":
        if CharacterReference.decode(text(from: index, limit: 12), at: 0) != nil {
          tokens[index].escape = .backslash
        }
      case ":":
        let rest = text(from: index, limit: 64)
        if InlineParser.directivePrefix(rest, schema: schema) {
          tokens[index].escape = .backslash
        }
      default:
        break
      }
      if tokens[index].escape == .none, schema.customTriggers.contains(c),
        decodesCustom(c, text(from: index))
      {
        tokens[index].escape = c.isASCIIPunctuation ? .backslash : .entity
      }
    }

    // 4. Nodes must not absorb what follows them: a directive without
    //    attributes before `{`, or a custom syntax whose decoder would read
    //    on.
    for index in 0..<total {
      guard let node = tokens[index].node, index + 1 < total,
        case .raw(let output) = tokens[index].kind
      else { continue }
      guard let spec = schema.nodes[node.type] else { continue }
      switch spec.markdown.kind {
      case .directive:
        if !output.hasSuffix("}"), tokens[index + 1].text == "{" {
          tokens[index + 1].escape = .backslash
        }
      case .custom(_, _, let decode):
        func absorbs() -> Bool {
          var following = ""
          var i = index + 1
          while i < total, following.unicodeScalars.count < 64 {
            following += tokens[i].output
            i += 1
          }
          let line = (output + following).prefix { $0 != "\n" }
          guard let (_, end) = decode(line[...]) else { return true }
          return line.unicodeScalars.distance(from: line.startIndex, to: end)
            != output.unicodeScalars.count
        }
        guard absorbs() else { continue }
        if let c = tokens[index + 1].text, tokens[index + 1].escape == .none {
          tokens[index + 1].escape = c.isASCIIPunctuation ? .backslash : .entity
          if absorbs() { tokens[index + 1].escape = .entity }
        } else if case .delimiter(.italic, _, let pair) = tokens[index + 1].kind {
          for i in 0..<total {
            if case .delimiter(.italic, _, pair) = tokens[i].kind { tokens[i].spelling = "*" }
          }
        }
      }
    }

    // 5. Make every delimiter open or close: a character next to it that
    //    stops it becomes a character reference, which counts as
    //    punctuation.
    func fix(_ target: Int) -> Bool {
      guard target >= 0, target < total, let c = tokens[target].text,
        tokens[target].escape == .none
      else { return false }
      if c == "\n" {
        // After a hard break, the newline itself becomes the reference:
        // `a\n\\\n` and `a\n&#10;` are the same text.
        if target > 0, case .raw("\\") = tokens[target - 1].kind {
          tokens[target - 1].kind = .raw("")
        }
      } else if !isWord(c), !c.isMarkdownWhitespace {
        return false
      }
      tokens[target].escape = .entity
      return true
    }
    var changed = true
    while changed {
      changed = false
      for index in 0..<total {
        guard case .delimiter(_, let isOpen, _) = tokens[index].kind else { continue }
        let underscore = tokens[index].spelling == "_"
        let before = previous(index)
        let after = next(index)
        let left =
          !isWhitespace(after)
          && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
        let right =
          !isWhitespace(before)
          && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        if isOpen {
          if left, !underscore || !right || isPunctuation(before) { continue }
          // Whitespace after an opener (where a mark reopens), or a word
          // character before it.
          if isWhitespace(after), after != nil {
            changed = fix(index + 1) || changed
          } else {
            changed = fix(index - 1) || changed
          }
        } else {
          if right, !underscore || !left || isPunctuation(after) { continue }
          if isWhitespace(before), before != nil {
            changed = fix(index - 1) || changed
          } else {
            changed = fix(index + 1) || changed
          }
        }
      }
    }

    // 6. `*`, `_`, and `~` in text, by run: a run is literal when neither
    //    side could make it a delimiter.
    var start = 0
    while start < total {
      guard let c = tokens[start].text, c == "*" || c == "_" || c == "~",
        tokens[start].escape == .none
      else {
        start += 1
        continue
      }
      var end = start
      while end + 1 < total, tokens[end + 1].text == c, tokens[end + 1].escape == .none {
        end += 1
      }
      let before = previous(start)
      let after = next(end)
      let literal =
        (isWhitespace(before) && isWhitespace(after))
        || (c == "_" && isWord(before) && isWord(after))
      if conservative || !literal {
        for i in start...end { tokens[i].escape = .backslash }
      }
      start = end + 1
    }

    // 7. Backslashes before punctuation or a line break (one that ends
    //    the paragraph is literal).
    for index in 0..<total where tokens[index].text == "\\" {
      let after = next(index)
      if after == "\n" || after?.isASCIIPunctuation == true {
        tokens[index].escape = .backslash
      }
    }

    // 8. A directive doesn't start right after a `:`, even an escaped one
    //    (as in remark-directive), so that colon is a character reference.
    for index in 1..<max(total, 1) where tokens[index].node != nil {
      if tokens[index].first == ":", tokens[index - 1].text == ":" {
        tokens[index - 1].escape = .entity
      }
    }
  }

  /// Escapes what would start a block at the beginning of a line.
  private func escapeBlockSyntax(
    _ tokens: inout [Token], from start: Int, to end: Int, isItemStart: Bool
  ) {
    // A line that starts with a character reference starts no block.
    guard tokens[start].escape == .none else { return }
    var line: [Unicode.Scalar] = []
    var i = start
    while i < end, let c = tokens[i].text, line.count < 16 {
      line.append(c)
      i += 1
    }
    guard let first = line.first else { return }
    if isItemStart, line.count >= 3, first == "[", line[2] == "]",
      line[1] == " " || line[1] == "x" || line[1] == "X",
      line.count == 3 || line[3].isSpaceOrTab
    {
      tokens[start].escape = .backslash
      return
    }
    switch first {
    case ">":
      tokens[start].escape = .backslash
    case "-", "+", "*":
      let ends = line.count == 1 || line[1].isSpaceOrTab
      if ends, !isThematicBreak(tokens, from: start, to: end) {
        tokens[start].escape = .backslash
      }
    case "`", "~":
      if line.count >= 3, line[1] == first, line[2] == first { tokens[start].escape = .backslash }
    default:
      var digits = 0
      while digits < line.count, line[digits].isASCIIDigit { digits += 1 }
      if digits >= 1, digits <= 9, digits < line.count, line[digits] == "." || line[digits] == ")",
        digits + 1 == line.count || line[digits + 1].isSpaceOrTab
      {
        tokens[start + digits].escape = .backslash
      }
    }
  }

  private func isThematicBreak(_ tokens: [Token], from start: Int, to end: Int) -> Bool {
    var line = Line()
    for i in start..<end {
      guard let c = tokens[i].text else { return false }
      line.append(c)
    }
    return BlockSyntax.isThematicBreak(line)
  }

  /// Whether the parser would make a link from the `[` at `index`: it finds
  /// its `]` before any other link, and a destination follows.
  private func opensLink(_ tokens: [Token], at index: Int) -> Bool {
    var depth = 0
    var i = index + 1
    while i < tokens.count {
      switch tokens[i].kind {
      case .text("["):
        depth += 1
      case .text("]"):
        if depth == 0 {
          var rest: [Unicode.Scalar] = []
          var j = i + 1
          while j < tokens.count, let c = tokens[j].text, rest.count < 2048 {
            rest.append(c)
            j += 1
          }
          return InlineParser.destination(rest, at: 0) != nil
        }
        depth -= 1
      case .linkOpen:
        return false
      default:
        break
      }
      i += 1
    }
    return false
  }

  private func decodesCustom(_ c: Unicode.Scalar, _ rest: [Unicode.Scalar]) -> Bool {
    for type in schema.customCodecs {
      guard case .custom(let triggers, _, let decode) = schema.nodes[type]!.markdown.kind,
        triggers.contains(c)
      else { continue }
      var line = rest
      if let newline = line.firstIndex(of: "\n") { line.removeSubrange(newline...) }
      guard !line.isEmpty else { continue }
      let string = String(scalars: line)[...]
      if let (_, end) = decode(string), end > string.startIndex { return true }
    }
    return false
  }
}

extension InlineParser {
  /// Whether `s` starts with a directive name the schema registers, followed
  /// by `[`.
  static func directivePrefix(_ s: [Unicode.Scalar], schema: Schema) -> Bool {
    var i = 1
    guard i < s.count, s[i].isASCIILetter else { return false }
    while i < s.count, s[i].isASCIILetter || s[i].isASCIIDigit || s[i] == "-" || s[i] == "_" {
      i += 1
    }
    return i < s.count && s[i] == "[" && schema.directives[String(scalars: s[1..<i])] != nil
  }
}
