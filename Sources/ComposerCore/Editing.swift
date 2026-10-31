// Editing operations. Each one reports exactly what it changed, which becomes
// the update's changeset and the transforms' dirty ranges.

extension EditorState {
  /// Replaces `range` with `content`. A range across text blocks merges them:
  /// the first block keeps its kind and takes the last block's remaining
  /// content. A position inside `range` moves to the end of `content`.
  public mutating func replace(_ range: DocumentRange, with content: [Inline]) {
    let range = clamped(range)
    if range.isEmpty, content.allSatisfy({ $0.length == 0 }) { return }
    let edit = withDocument { $0.replace(range.offsets, with: content) }
    record(range.lowerBound.offset..<edit.upper, length: edit.length)
  }

  /// Inserts text over `selection` (the current selection by default) and
  /// puts the caret after it. The text takes `marks`, or by default the
  /// stored marks, or else the marks of the text before it, without
  /// extending a link past its end. It uses up the stored marks.
  public mutating func insert(_ text: String, at selection: Selection? = nil, marks: Marks? = nil) {
    let range = clamped((selection ?? self.selection).range)
    let marks = marks ?? typingMarks(at: range.lowerBound)
    if storedMarks != nil { storedMarks = nil }
    insert([.text(text, marks: marks)], over: range)
  }

  /// Inserts an atomic node over `selection` and puts the caret after it.
  public mutating func insert(_ node: AtomicNode, at selection: Selection? = nil) {
    insert([.node(node)], over: clamped((selection ?? self.selection).range))
  }

  /// Inserts inline content over `range` and puts the caret after it.
  public mutating func insert(_ content: [Inline], over range: DocumentRange) {
    let range = clamped(range)
    let edit = withDocument { $0.replace(range.offsets, with: content) }
    record(range.lowerBound.offset..<edit.upper, length: edit.length)
    self.selection = .caret(range.lowerBound.offset + edit.contentLength)
  }

  public mutating func delete(_ range: DocumentRange) {
    replace(range, with: [])
  }

  /// Deletes a range the user selected. Deleting everything leaves an empty
  /// paragraph, not the first block's empty list item, quote, or code block.
  mutating func deleteSelection(_ range: DocumentRange) {
    let isEverything = range.offsets == 0..<document.length
    delete(range)
    if isEverything, document.length == 0, !document.isEmpty { document = .empty }
  }

  /// Splits the text block at `position` into two. In a code block this
  /// inserts a line break instead.
  public mutating func splitBlock(at position: Position) {
    let offset = document.scalarAligned(min(max(position.offset, 0), document.length))
    withDocument { $0.splitBlock(at: offset) }
    record(offset..<offset, length: 1)
  }

  /// Sets or clears a mark on the text in `range`. Code blocks are unaffected.
  public mutating func setMark(_ kind: MarkKind, _ isOn: Bool, in range: DocumentRange) {
    let range = clamped(range)
    let changed = withDocument { document in
      document.updateMarks(in: range.offsets) { $0[kind] = isOn }
    }
    if changed { record(range.offsets, length: range.length, mapSelection: false) }
  }

  /// Removes the mark when all text in `range` has it, and adds it otherwise.
  /// With an empty range, toggles the mark in the stored marks instead, so
  /// it applies to the text typed next.
  public mutating func toggleMark(_ kind: MarkKind, in range: DocumentRange) {
    if range.isEmpty {
      let position = clamped(range).lowerBound
      let current = document.marks(at: position)
      var marks = typingMarks(at: position)
      marks[kind].toggle()
      storedMarks = marks == current ? nil : marks
      return
    }
    setMark(kind, !document.allText(in: range.offsets) { $0[kind] }, in: range)
  }

  /// Links the text in `range` to `url`, or unlinks it when `url` is `nil`.
  public mutating func setLink(_ url: String?, in range: DocumentRange) {
    let range = clamped(range)
    let changed = withDocument { document in
      document.updateMarks(in: range.offsets) { $0.link = url }
    }
    if changed { record(range.offsets, length: range.length, mapSelection: false) }
  }

  /// Clamps a range to the document, with both bounds on scalar boundaries.
  private func clamped(_ range: DocumentRange) -> DocumentRange {
    let length = document.length
    let lower = document.scalarAligned(min(max(range.lowerBound.offset, 0), length))
    let upper = document.scalarAligned(min(max(range.upperBound.offset, lower), length))
    return .init(offsets: lower..<max(upper, lower))
  }
}

extension Document {
  /// The marks text typed at `position` takes: those of the text before it
  /// (or after it, at the start of a block), without extending a link.
  public func marks(at position: Position) -> Marks {
    guard let leaf = locate(position.offset),
      case .paragraph(let inlines) = block(at: leaf.path)
    else { return Marks() }
    let local = position.offset - leaf.start
    var offset = 0
    for inline in inlines {
      let end = offset + inline.length
      if local == 0 || (local > offset && local <= end) {
        guard case .text(_, var marks) = inline else { return Marks() }
        if local == 0 || local == end { marks.link = nil }
        return marks
      }
      offset = end
    }
    return Marks()
  }

  /// Rounds an offset inside a UTF-16 surrogate pair down to the start of
  /// the pair, so no edit splits a scalar.
  func scalarAligned(_ offset: Int) -> Int {
    guard let leaf = locate(offset) else { return offset }
    let local = offset - leaf.start
    guard local > 0, local < leaf.length else { return offset }
    var text = ""
    var start = 0
    switch block(at: leaf.path) {
    case .codeBlock(_, let code):
      text = code
    case .paragraph(let inlines):
      for inline in inlines {
        let length = inline.length
        if local < start + length {
          guard case .text(let run, _) = inline else { return offset }
          text = run
          break
        }
        start += length
      }
    default:
      return offset
    }
    let units = text.utf16
    let index = units.index(units.startIndex, offsetBy: local - start)
    guard index > units.startIndex, UTF16.isTrailSurrogate(units[index]),
      UTF16.isLeadSurrogate(units[units.index(before: index)])
    else { return offset }
    return offset - 1
  }

  /// A replacement as recorded: the replaced range ends at `upper`, and
  /// `length` units replace it, the first `contentLength` of them the
  /// content. In a code block, nodes are inserted as their labels.
  struct Replacement {
    var upper: Int
    var length: Int
    var contentLength: Int
  }

  mutating func replace(_ range: Range<Int>, with content: [Inline]) -> Replacement {
    guard let start = locate(range.lowerBound) else {
      let content = Normalizer.inlines(content)
      blocks.append(.paragraph(content))
      let length = content.reduce(0) { $0 + $1.length }
      return Replacement(upper: range.lowerBound, length: length, contentLength: length)
    }
    let end = range.isEmpty ? start : locate(range.upperBound)!
    var inserted = 0
    if start.path == end.path {
      modifyContainer(of: start.path[...]) { blocks, index in
        let local = (range.lowerBound - start.start)..<(range.upperBound - start.start)
        (blocks[index], inserted) = Self.splice(blocks[index], local, with: content)
      }
      return Replacement(upper: range.upperBound, length: inserted, contentLength: inserted)
    }
    // Across blocks: the start block takes the end block's tail.
    var tail: [Inline]
    switch block(at: end.path) {
    case .paragraph(let inlines):
      tail = Self.split(inlines, at: range.upperBound - end.start).1
    case .codeBlock(_, let text):
      tail = [.text(String(text.utf16Suffix(from: range.upperBound - end.start)))]
    default:
      preconditionFailure("Not a text block")
    }
    let isCode = if case .codeBlock = block(at: start.path) { true } else { false }
    let endIsCode = if case .codeBlock = block(at: end.path) { true } else { false }
    let contentLength =
      isCode ? Self.plainText(content).utf16.count : content.reduce(0) { $0 + $1.length }
    Self.removeLeaves(&blocks, after: start.path[...], through: end.path[...])
    modifyContainer(of: start.path[...]) { blocks, index in
      let local = (range.lowerBound - start.start)..<start.length
      (blocks[index], inserted) = Self.splice(blocks[index], local, with: content + tail)
    }
    // Between paragraphs the tail moves as it was. Otherwise it changes: a
    // code block takes a paragraph's tail as text (nodes become labels), and
    // a paragraph takes a code block's tail as unstyled text. Then the edit
    // runs to the end block's end.
    if isCode || endIsCode {
      return Replacement(upper: end.end, length: inserted, contentLength: contentLength)
    }
    return Replacement(upper: range.upperBound, length: contentLength, contentLength: contentLength)
  }

  mutating func splitBlock(at offset: Int) {
    guard let leaf = locate(offset) else {
      blocks += [.paragraph([]), .paragraph([])]
      return
    }
    modifyContainer(of: leaf.path[...]) { blocks, index in
      switch blocks[index] {
      case .paragraph(let inlines):
        let (before, after) = Self.split(inlines, at: offset - leaf.start)
        blocks[index] = .paragraph(before)
        blocks.insert(.paragraph(after), at: index + 1)
      case .codeBlock:
        let local = (offset - leaf.start)..<(offset - leaf.start)
        blocks[index] = Self.splice(blocks[index], local, with: [.text("\n")]).0
      default:
        preconditionFailure("Not a text block")
      }
    }
  }

  /// Applies `update` to the marks of the text in `range`. Returns whether
  /// anything changed.
  mutating func updateMarks(in range: Range<Int>, _ update: (inout Marks) -> Void) -> Bool {
    var targets: [LeafLocation] = []
    forEachLeaf { path, block, start, length in
      if start > range.upperBound { return true }
      if case .paragraph = block, start + length > range.lowerBound, start < range.upperBound {
        targets.append(LeafLocation(path: path, start: start, length: length))
      }
      return false
    }
    var changed = false
    for leaf in targets {
      modifyContainer(of: leaf.path[...]) { blocks, index in
        guard case .paragraph(let inlines) = blocks[index] else { return }
        let lower = max(range.lowerBound - leaf.start, 0)
        let upper = min(range.upperBound - leaf.start, leaf.length)
        let (before, rest) = Self.split(inlines, at: lower)
        let (middle, after) = Self.split(rest, at: upper - lower)
        var updated = before
        for inline in middle {
          if case .text(let text, var marks) = inline {
            update(&marks)
            updated.append(.text(text, marks: marks))
          } else {
            updated.append(inline)
          }
        }
        updated = Normalizer.inlines(updated + after)
        if updated != inlines {
          blocks[index] = .paragraph(updated)
          changed = true
        }
      }
    }
    return changed
  }

  /// Whether all text in `range` satisfies `predicate` (and there is some).
  func allText(in range: Range<Int>, _ predicate: (Marks) -> Bool) -> Bool {
    var sawText = false
    var result = true
    forEachLeaf { _, block, start, length in
      if start > range.upperBound { return true }
      guard case .paragraph(let inlines) = block, start + length > range.lowerBound else {
        return false
      }
      let local = max(range.lowerBound - start, 0)..<min(range.upperBound - start, length)
      let middle = Self.split(Self.split(inlines, at: local.lowerBound).1, at: local.count).0
      for case .text(_, let marks) in middle {
        sawText = true
        if !predicate(marks) {
          result = false
          return true
        }
      }
      return false
    }
    return sawText && result
  }

  // MARK: Helpers

  /// Replaces `local` in a text block and returns the block and the inserted
  /// length.
  static func splice(_ block: Block, _ local: Range<Int>, with content: [Inline]) -> (Block, Int) {
    switch block {
    case .paragraph(let inlines):
      let (before, rest) = split(inlines, at: local.lowerBound)
      let after = split(rest, at: local.count).1
      let result = Normalizer.inlines(before + content + after)
      return (.paragraph(result), content.reduce(0) { $0 + $1.length })
    case .codeBlock(let language, let text):
      let insertion = plainText(content)
      let result =
        String(text.utf16Prefix(local.lowerBound)) + insertion
        + String(text.utf16Suffix(from: local.upperBound))
      return (.codeBlock(language: language, text: result), insertion.utf16.count)
    default:
      preconditionFailure("Not a text block")
    }
  }

  /// Splits inline runs at a local offset.
  static func split(_ inlines: [Inline], at offset: Int) -> ([Inline], [Inline]) {
    var before: [Inline] = []
    var after: [Inline] = []
    var position = 0
    for inline in inlines {
      let length = inline.length
      if position + length <= offset {
        before.append(inline)
      } else if position >= offset {
        after.append(inline)
      } else if case .text(let text, let marks) = inline {
        let cut = offset - position
        before.append(.text(String(text.utf16Prefix(cut)), marks: marks))
        after.append(.text(String(text.utf16Suffix(from: cut)), marks: marks))
      }
      position += length
    }
    return (before, after)
  }

  static func plainText(_ inlines: [Inline]) -> String {
    var result = ""
    for inline in inlines {
      switch inline {
      case .text(let text, _): result += text
      case .node(let node): result += node.label
      case .unknown(let node): result += node.text
      }
    }
    return result
  }

  /// Removes every text block after the one at `start` up to and including
  /// the one at `end`, with any blocks between them, and containers left
  /// empty at the end side.
  static func removeLeaves(
    _ blocks: inout [Block], after start: ArraySlice<Int>?, through end: ArraySlice<Int>?
  ) {
    let low = start?.first
    let high = end?.first
    if let low, let high, low == high {
      removeLeaves(in: &blocks[low], after: start!.dropFirst(), through: end!.dropFirst())
      return
    }
    var removesHigh = false
    if let high, let end {
      if end.count == 1 {
        removesHigh = true
      } else {
        removeLeaves(in: &blocks[high], after: nil, through: end.dropFirst())
        removesHigh = blocks[high].isEmptyContainer
      }
    }
    if let low, let start, start.count > 1 {
      removeLeaves(in: &blocks[low], after: start.dropFirst(), through: nil)
    }
    let lower = (low ?? -1) + 1
    let upper = high.map { removesHigh ? $0 + 1 : $0 } ?? blocks.count
    if lower < upper { blocks.removeSubrange(lower..<upper) }
  }

  private static func removeLeaves(
    in block: inout Block, after start: ArraySlice<Int>?, through end: ArraySlice<Int>?
  ) {
    switch block {
    case .quote(var children):
      block = .paragraph([])
      removeLeaves(&children, after: start, through: end)
      block = .quote(children)
    case .list(let kind, var items):
      block = .paragraph([])
      removeLeaves(items: &items, after: start, through: end)
      block = .list(kind, items: items)
    default:
      preconditionFailure("Path runs through a leaf")
    }
  }

  private static func removeLeaves(
    items: inout [ListItem], after start: ArraySlice<Int>?, through end: ArraySlice<Int>?
  ) {
    let low = start?.first
    let high = end?.first
    if let low, let high, low == high {
      removeLeaves(&items[low].blocks, after: start!.dropFirst(), through: end!.dropFirst())
      return
    }
    var removesHigh = false
    if let high, let end {
      removeLeaves(&items[high].blocks, after: nil, through: end.dropFirst())
      removesHigh = items[high].blocks.isEmpty
    }
    if let low, let start {
      removeLeaves(&items[low].blocks, after: start.dropFirst(), through: nil)
    }
    let lower = (low ?? -1) + 1
    let upper = high.map { removesHigh ? $0 + 1 : $0 } ?? items.count
    if lower < upper { items.removeSubrange(lower..<upper) }
  }
}

extension Block {
  var isEmptyContainer: Bool {
    switch self {
    case .quote(let children): children.isEmpty
    case .list(_, let items): items.isEmpty
    default: false
    }
  }
}

extension String {
  func utf16Prefix(_ count: Int) -> Substring {
    let index =
      utf16.index(utf16.startIndex, offsetBy: count, limitedBy: utf16.endIndex) ?? endIndex
    return self[..<index]
  }

  func utf16Suffix(from offset: Int) -> Substring {
    let index =
      utf16.index(utf16.startIndex, offsetBy: offset, limitedBy: utf16.endIndex) ?? endIndex
    return self[index...]
  }
}
