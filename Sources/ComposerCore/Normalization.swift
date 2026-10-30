extension Document {
  /// Lists nest up to this many levels. Deeper lists are clamped.
  public static let maxListDepth = 3
  /// Quotes nest up to this many levels. Deeper quotes are spliced into their
  /// parent, which keeps the parser's recursion bounded.
  public static let maxQuoteDepth = 8
  /// The largest ordered-list start markdown can spell (nine digits).
  public static let maxOrderedStart = 999_999_999

  /// The canonical form of the document: the form markdown can represent.
  ///
  /// - Line endings are `\n`, and inline code never spans a line break.
  /// - Adjacent text runs with equal marks are merged, and empty runs, empty
  ///   paragraphs, empty quotes, and empty lists are removed.
  /// - Lists nested deeper than `maxListDepth` are clamped: the deeper items
  ///   become level-3 items in their original order. A quote starts a new list
  ///   nesting context.
  /// - Quotes nested deeper than `maxQuoteDepth` are spliced into their parent.
  /// - Code block languages are trimmed, single-line, and `nil` when empty.
  /// - Ordered list starts are clamped to `0...maxOrderedStart`.
  ///
  /// `MarkdownCodec` guarantees `parse(serialize(doc)) == doc.normalized()` for
  /// documents without unknown nodes.
  public func normalized() -> Document {
    Document(blocks: Normalizer.blocks(blocks, quoteDepth: 0, listDepth: 0))
  }
}

enum Normalizer {
  static func blocks(_ blocks: [Block], quoteDepth: Int, listDepth: Int) -> [Block] {
    var result: [Block] = []
    result.reserveCapacity(blocks.count)
    for block in blocks {
      switch block {
      case .paragraph(let content):
        let content = canonicalInlines(content)
        if !content.isEmpty { result.append(.paragraph(content)) }
      case .codeBlock(let language, let text):
        result.append(.codeBlock(language: Normalizer.language(language), text: lineEndings(text)))
      case .quote(let children):
        if quoteDepth + 1 > Document.maxQuoteDepth {
          result += Normalizer.blocks(children, quoteDepth: quoteDepth, listDepth: listDepth)
        } else {
          let children = Normalizer.blocks(children, quoteDepth: quoteDepth + 1, listDepth: 0)
          if !children.isEmpty { result.append(.quote(children)) }
        }
      case .list(let kind, let items):
        let level = listDepth + 1
        var normalizedItems: [ListItem] = []
        normalizedItems.reserveCapacity(items.count)
        for item in items {
          if level < Document.maxListDepth {
            normalizedItems.append(
              ListItem(
                checked: item.checked,
                blocks: Normalizer.blocks(item.blocks, quoteDepth: quoteDepth, listDepth: level)))
          } else {
            normalizedItems += flatten(item, quoteDepth: quoteDepth)
          }
        }
        guard !normalizedItems.isEmpty else { continue }
        var kind = kind
        if case .ordered(let start) = kind {
          kind = .ordered(start: min(max(start, 0), Document.maxOrderedStart))
        }
        result.append(.list(kind, items: normalizedItems))
      case .unknown:
        result.append(block)
      }
    }
    return result
  }

  /// Clamps an item at the deepest list level: lists nested in it are hoisted
  /// into sibling items, in order.
  private static func flatten(_ item: ListItem, quoteDepth: Int) -> [ListItem] {
    var result = [ListItem(checked: item.checked, blocks: [])]
    var startsNewItem = false
    for block in item.blocks {
      if case .list(_, let items) = block {
        for nested in items { result += flatten(nested, quoteDepth: quoteDepth) }
        startsNewItem = true
        continue
      }
      let normalized = blocks([block], quoteDepth: quoteDepth, listDepth: Document.maxListDepth)
      guard !normalized.isEmpty else { continue }
      if startsNewItem {
        result.append(ListItem(blocks: []))
        startsNewItem = false
      }
      result[result.count - 1].blocks += normalized
    }
    // An item that held nothing but a nested list has no content of its own.
    if result.count > 1, result[0].blocks.isEmpty, result[0].checked == nil {
      result.removeFirst()
    }
    return result
  }

  /// `inlines(_:)`, plus what markdown cannot spell: bold, italic, and
  /// strikethrough never start or end with whitespace (it moves outside the
  /// mark), paragraphs never end with a line break, and node labels and link
  /// destinations have no line breaks.
  static func canonicalInlines(_ content: [Inline]) -> [Inline] {
    var runs = inlines(
      content.map { inline in
        switch inline {
        case .text(let text, var marks):
          if let link = marks.link, link.utf8.contains(where: { $0 == 10 || $0 == 13 }) {
            marks.link = String(
              String.UnicodeScalarView(link.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
          }
          return .text(text, marks: marks)
        case .node(var node):
          if node.label.utf8.contains(where: { $0 == 10 || $0 == 13 }) {
            node.label = String(
              String.UnicodeScalarView(
                node.label.unicodeScalars.map { $0 == "\n" || $0 == "\r" ? " " : $0 }))
          }
          return .node(node)
        case .unknown:
          return inline
        }
      })
    while case .text(let text, let marks)? = runs.last, text.unicodeScalars.last == "\n" {
      var scalars = text.unicodeScalars
      while scalars.last == "\n" { scalars.removeLast() }
      runs.removeLast()
      if !scalars.isEmpty { runs.append(.text(String(scalars), marks: marks)) }
    }
    var changed = false
    for kind in [MarkKind.bold, .italic, .strikethrough] {
      changed = trimWhitespace(of: kind, in: &runs) || changed
    }
    return changed ? inlines(runs) : runs
  }

  /// Moves whitespace at the edges of each span of `kind` outside it.
  private static func trimWhitespace(of kind: MarkKind, in runs: inout [Inline]) -> Bool {
    func marked(_ inline: Inline) -> Bool {
      if case .text(_, let marks) = inline { return marks[kind] }
      return false
    }
    // Whether a run can carry the mark's edge: code and nodes never do,
    // because a delimiter next to them never touches whitespace.
    func edgeWhitespace(_ inline: Inline, leading: Bool) -> Int? {
      guard case .text(let text, let marks) = inline, !marks.code else { return nil }
      let scalars = Array(text.unicodeScalars)
      var count = 0
      if leading {
        while count < scalars.count, scalars[count].isMarkdownWhitespace { count += 1 }
      } else {
        while count < scalars.count, scalars[scalars.count - 1 - count].isMarkdownWhitespace {
          count += 1
        }
      }
      return count
    }
    var changed = false
    var index = 0
    while index < runs.count {
      guard marked(runs[index]) else {
        index += 1
        continue
      }
      var end = index
      while end + 1 < runs.count, marked(runs[end + 1]) { end += 1 }
      // Leading edge.
      var start = index
      while start <= end, let count = edgeWhitespace(runs[start], leading: true), count > 0 {
        guard case .text(let text, var marks) = runs[start] else { break }
        changed = true
        let scalars = Array(text.unicodeScalars)
        var off = marks
        off[kind] = false
        if count == scalars.count {
          runs[start] = .text(text, marks: off)
          start += 1
          continue
        }
        marks[kind] = true
        runs[start] = .text(String(String.UnicodeScalarView(scalars[count...])), marks: marks)
        runs.insert(
          .text(String(String.UnicodeScalarView(scalars[..<count])), marks: off), at: start)
        start += 1
        end += 1
        break
      }
      // Trailing edge.
      var last = end
      while last >= start, let count = edgeWhitespace(runs[last], leading: false), count > 0 {
        guard case .text(let text, var marks) = runs[last] else { break }
        changed = true
        let scalars = Array(text.unicodeScalars)
        var off = marks
        off[kind] = false
        if count == scalars.count {
          runs[last] = .text(text, marks: off)
          last -= 1
          continue
        }
        marks[kind] = true
        let split = scalars.count - count
        runs[last] = .text(String(String.UnicodeScalarView(scalars[..<split])), marks: marks)
        runs.insert(
          .text(String(String.UnicodeScalarView(scalars[split...])), marks: off), at: last + 1)
        end += 1
        break
      }
      index = end + 1
    }
    return changed
  }

  /// Merges adjacent runs with equal marks, drops empty runs, normalizes line
  /// endings, and keeps line breaks out of inline code. Editing keeps
  /// paragraphs in this form.
  static func inlines(_ inlines: [Inline]) -> [Inline] {
    var result: [Inline] = []
    result.reserveCapacity(inlines.count)
    for inline in inlines {
      guard case .text(var text, let marks) = inline else {
        result.append(inline)
        continue
      }
      text = lineEndings(text)
      if marks.code, text.utf8.contains(UInt8(ascii: "\n")) {
        var plain = marks
        plain.code = false
        var first = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
          if !first { append(.text("\n", marks: plain), to: &result) }
          first = false
          append(.text(String(line), marks: marks), to: &result)
        }
      } else {
        append(.text(text, marks: marks), to: &result)
      }
    }
    return result
  }

  /// Appends a run, merging it into the previous one when the marks match.
  static func append(_ inline: Inline, to result: inout [Inline]) {
    guard case .text(let text, let marks) = inline else {
      result.append(inline)
      return
    }
    if text.isEmpty { return }
    if case .text(let previous, let previousMarks)? = result.last, previousMarks == marks {
      result[result.count - 1] = .text(previous + text, marks: marks)
    } else {
      result.append(inline)
    }
  }

  static func lineEndings(_ text: String) -> String {
    guard text.utf8.contains(UInt8(ascii: "\r")) else { return text }
    var result = String.UnicodeScalarView()
    var previousWasCR = false
    for scalar in text.unicodeScalars {
      if scalar == "\r" {
        result.append("\n")
        previousWasCR = true
        continue
      }
      if scalar == "\n", previousWasCR {
        previousWasCR = false
        continue
      }
      previousWasCR = false
      result.append(scalar)
    }
    return String(result)
  }

  static func language(_ language: String?) -> String? {
    guard let language else { return nil }
    var scalars = String.UnicodeScalarView()
    for scalar in language.unicodeScalars {
      scalars.append(scalar == "\n" || scalar == "\r" ? " " : scalar)
    }
    let trimmed = String(scalars).trimmingMarkdownWhitespace()
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension String {
  /// Trims spaces, tabs, and line breaks (not other Unicode whitespace).
  func trimmingMarkdownWhitespace() -> String {
    let scalars = unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    func isSpace(_ scalar: Unicode.Scalar) -> Bool {
      scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }
    while start < end, isSpace(scalars[start]) { start = scalars.index(after: start) }
    while end > start, isSpace(scalars[scalars.index(before: end)]) {
      end = scalars.index(before: end)
    }
    return String(scalars[start..<end])
  }
}

extension Unicode.Scalar {
  /// CommonMark's Unicode whitespace: `Zs`, tab, line feed, form feed, and
  /// carriage return.
  var isMarkdownWhitespace: Bool {
    switch value {
    case 0x09, 0x0A, 0x0C, 0x0D, 0x20: return true
    case 0..<0x80: return false
    default: return properties.generalCategory == .spaceSeparator
    }
  }
}
