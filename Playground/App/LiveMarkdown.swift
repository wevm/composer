import ComposerCore

/// A stand-in for the markdown plugins, which come in a later milestone, so
/// the Playground converts markdown as you type. It is built only on Core's
/// public API: transforms, a key binding, and a command.
///
/// - `**bold**`, `_italic_`, `*italic*`, `~~strike~~`, and `` `code` ``
///   convert when you type a space or punctuation after the closing
///   delimiter. (Converting on the delimiter itself would make the next
///   characters continue the mark, because Core's typing takes the marks of
///   the text before the caret.)
/// - `- `, `* `, `1. `, and `> ` at the start of a top-level paragraph turn
///   it into a list item or a quote, and `[ ] ` or `[x] ` at the start of a
///   bullet item makes it a task.
/// - ↩ in a list item starts a new item, and ↩ in an empty item ends the
///   list.
struct LiveMarkdown: ComposerPlugin {
  static let newListItem = Command<Void>("playground.newListItem")

  func register(in registry: inout PluginRegistry) {
    registry.addTransform("playground.inlineMarkdown") { state, range in
      Self.convertInline(&state, in: range)
    }
    registry.addTransform("playground.blockMarkdown") { state, range in
      Self.convertBlockPrefix(&state, in: range)
    }
    registry.addKeyBinding(KeyBinding(.return, command: Self.newListItem))
    registry.register(Self.newListItem) { _, controller in
      Self.newListItem(controller) ? .handled : .unhandled
    }
  }

  // MARK: Inline marks

  private static let rules: [(delimiter: String, mark: MarkKind)] = [
    ("**", .bold), ("~~", .strikethrough), ("`", .code), ("_", .italic), ("*", .italic),
  ]

  private static func isBoundary(_ unit: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return scalar.properties.isWhitespace || ".,;:!?)]}'\"".unicodeScalars.contains(scalar)
  }

  /// Converts `<delimiter>text<delimiter>` right before the boundary
  /// character just typed at the caret.
  private static func convertInline(_ state: inout EditorState, in range: DocumentRange) {
    let caret = state.selection.head.offset
    guard state.selection.isCollapsed, range.lowerBound.offset <= caret,
      caret <= range.upperBound.offset,
      let block = state.document.textBlock(containing: state.selection.head),
      case .paragraph(let inlines) = block.content
    else { return }
    var start = block.range.lowerBound.offset
    for inline in inlines {
      let length = inline.length
      defer { start += length }
      guard caret > start, caret <= start + length else { continue }
      guard case .text(let text, let marks) = inline, !marks.code else { return }
      let units = Array(text.utf16)
      let end = caret - start
      guard end >= 3, isBoundary(units[end - 1]) else { return }
      for (delimiter, mark) in rules where !marks[mark] {
        let d = Array(delimiter.utf16)
        let close = end - 1 - d.count
        guard close >= 1, Array(units[close..<close + d.count]) == d else { continue }
        guard let open = opening(of: d, before: close, in: units) else { continue }
        let base = start
        state.delete(Position(base + close)..<Position(base + close + d.count))
        state.setMark(mark, true, in: Position(base + open + d.count)..<Position(base + close))
        state.delete(Position(base + open)..<Position(base + open + d.count))
        return
      }
      return
    }
  }

  /// The nearest opening delimiter before `close` that encloses non-empty
  /// text without whitespace at its edges, and that starts a word.
  private static func opening(of d: [UInt16], before close: Int, in units: [UInt16]) -> Int? {
    let single = d.count == 1
    if single, units[close - 1] == d[0] { return nil }
    var open = close - d.count - 1
    while open >= 0 {
      defer { open -= 1 }
      guard Array(units[open..<open + d.count]) == d else { continue }
      let content = units[(open + d.count)..<close]
      guard let first = content.first, let last = content.last, !isWhitespace(first),
        !isWhitespace(last)
      else { return nil }
      if single, first == d[0] { continue }
      if single, open > 0, units[open - 1] == d[0] { continue }
      if open > 0, !isBoundary(units[open - 1]) { continue }
      return open
    }
    return nil
  }

  private static func isWhitespace(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit)?.properties.isWhitespace ?? false
  }

  // MARK: Block prefixes

  private enum Prefix {
    case bullet, ordered(Int), quote
  }

  /// The top-level block holding `position`, and where its text starts.
  private static func topLevelBlock(
    containing position: Position, in document: Document
  ) -> (index: Int, start: Int)? {
    var offset = 0
    var first = true
    for (index, block) in document.blocks.enumerated() {
      let single = Document(blocks: [block])
      guard !single.textBlocks.isEmpty else { continue }
      if !first { offset += 1 }
      first = false
      let length = single.length
      if position.offset >= offset, position.offset <= offset + length {
        return (index, offset)
      }
      offset += length
    }
    return nil
  }

  private static func prefix(of text: String) -> (Prefix, Int)? {
    for (spelling, prefix) in [("- ", Prefix.bullet), ("* ", .bullet), ("> ", .quote)]
    where text.hasPrefix(spelling) {
      return (prefix, spelling.utf16.count)
    }
    let digits = text.prefix { $0.isASCII && $0.isNumber }
    if (1...9).contains(digits.count), text.dropFirst(digits.count).hasPrefix(". "),
      let number = Int(digits)
    {
      return (.ordered(number), digits.count + 2)
    }
    return nil
  }

  /// Turns a top-level paragraph that starts with a list or quote marker
  /// just typed into that container, joining a list of the same kind before
  /// it.
  private static func convertBlockPrefix(_ state: inout EditorState, in range: DocumentRange) {
    guard let (index, start) = topLevelBlock(containing: range.lowerBound, in: state.document)
    else { return }
    if case .list = state.document.blocks[index] {
      convertTaskPrefix(&state, list: index, start: start)
      return
    }
    guard case .paragraph(let inlines) = state.document.blocks[index],
      case .text(let text, let marks)? = inlines.first,
      let (prefix, length) = prefix(of: text),
      state.selection == .caret(start + length)
    else { return }
    let rest = String(text.utf16.dropFirst(length)) ?? ""
    let paragraph = Block.paragraph(
      (rest.isEmpty ? [] : [.text(rest, marks: marks)]) + inlines.dropFirst())
    var blocks = state.document.blocks
    let item: ListItem
    let kind: ListKind
    switch prefix {
    case .quote:
      blocks[index] = .quote([paragraph])
      state.document.blocks = blocks
      state.selection = .caret(start)
      return
    case .bullet:
      (item, kind) = (ListItem(blocks: [paragraph]), .bullet)
    case .ordered(let number):
      (item, kind) = (ListItem(blocks: [paragraph]), .ordered(start: number))
    }
    if index > 0, case .list(let previousKind, var items) = blocks[index - 1],
      sameKind(previousKind, kind)
    {
      items.append(item)
      blocks[index - 1] = .list(previousKind, items: items)
      blocks.remove(at: index)
    } else {
      blocks[index] = .list(kind, items: [item])
    }
    state.document.blocks = blocks
    // Containers add no units, so the item's text starts where the
    // paragraph's did.
    state.selection = .caret(start)
  }

  /// `[ ] ` or `[x] ` typed at the start of a bullet item makes it a task.
  private static func convertTaskPrefix(_ state: inout EditorState, list index: Int, start: Int) {
    guard case .list(.bullet, var items) = state.document.blocks[index] else { return }
    var offset = start
    for (position, item) in items.enumerated() {
      guard item.blocks.count == 1, case .paragraph(let inlines) = item.blocks[0] else { return }
      let length = inlines.reduce(0) { $0 + $1.length }
      defer { offset += length + 1 }
      guard state.selection == .caret(offset + 4), item.checked == nil,
        case .text(let text, let marks)? = inlines.first,
        text.hasPrefix("[ ] ") || text.hasPrefix("[x] ")
      else { continue }
      let rest = String(text.utf16.dropFirst(4)) ?? ""
      items[position] = ListItem(
        checked: text.hasPrefix("[x]"),
        blocks: [
          .paragraph((rest.isEmpty ? [] : [.text(rest, marks: marks)]) + inlines.dropFirst())
        ])
      var blocks = state.document.blocks
      blocks[index] = .list(.bullet, items: items)
      state.document.blocks = blocks
      state.selection = .caret(offset)
      return
    }
  }

  private static func sameKind(_ a: ListKind, _ b: ListKind) -> Bool {
    switch (a, b) {
    case (.bullet, .bullet), (.ordered, .ordered): true
    default: false
    }
  }

  // MARK: Return in lists

  /// ↩ in an item of a top-level list: splits the item into two, or ends
  /// the list if the item is empty. Returns whether it applied.
  @MainActor private static func newListItem(_ controller: ComposerController) -> Bool {
    var handled = false
    controller.update { state in
      let caret = state.selection.head.offset
      guard state.selection.isCollapsed,
        let (index, start) = topLevelBlock(containing: state.selection.head, in: state.document),
        case .list(let kind, var items) = state.document.blocks[index]
      else { return }
      var offset = start
      for (position, item) in items.enumerated() {
        guard item.blocks.count == 1, case .paragraph(let inlines) = item.blocks[0] else {
          return
        }
        let length = inlines.reduce(0) { $0 + $1.length }
        defer { offset += length + 1 }
        guard caret <= offset + length else { continue }
        var blocks = state.document.blocks
        if length == 0 {
          // An empty item ends the list: it becomes a paragraph after it.
          let before = Array(items[..<position])
          let after = Array(items[(position + 1)...])
          var replacement: [Block] = []
          if !before.isEmpty { replacement.append(.list(kind, items: before)) }
          replacement.append(.paragraph([]))
          if !after.isEmpty {
            replacement.append(.list(renumbered(kind, by: position + 1), items: after))
          }
          blocks.replaceSubrange(index...index, with: replacement)
          state.document.blocks = blocks
          state.selection = .caret(offset)
        } else {
          var split = EditorState(document: Document(blocks: [.paragraph(inlines)]))
          split.splitBlock(at: Position(caret - offset))
          let halves = split.document.blocks
          items[position] = ListItem(checked: item.checked, blocks: [halves[0]])
          items.insert(
            ListItem(checked: item.checked.map { _ in false }, blocks: [halves[1]]),
            at: position + 1)
          blocks[index] = .list(kind, items: items)
          state.document.blocks = blocks
          state.selection = .caret(caret + 1)
        }
        handled = true
        return
      }
    }
    return handled
  }

  private static func renumbered(_ kind: ListKind, by count: Int) -> ListKind {
    if case .ordered(let start) = kind { return .ordered(start: start + count) }
    return kind
  }
}
