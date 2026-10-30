// The smallest edit between two documents, for replacing a document without
// replacing all of its text (undo, redo, `setDocument`).

extension Document {
  /// A text block with what surrounds it, for comparing documents block by
  /// block.
  private struct Leaf: Equatable {
    enum Step: Equatable {
      case quote
      case item(ListKind, index: Int, checked: Bool?)
    }

    var block: Block
    var context: [Step]
    var start: Int
    var length: Int

    func matches(_ other: Leaf) -> Bool { block == other.block && context == other.context }
  }

  private var leaves: [Leaf] {
    var result: [Leaf] = []
    var context: [Leaf.Step] = []
    var offset = 0
    func walk(_ blocks: [Block]) {
      for block in blocks {
        switch block {
        case .paragraph, .codeBlock:
          if !result.isEmpty { offset += 1 }
          let length = block.textLength!
          result.append(Leaf(block: block, context: context, start: offset, length: length))
          offset += length
        case .quote(let children):
          context.append(.quote)
          walk(children)
          context.removeLast()
        case .list(let kind, let items):
          for (index, item) in items.enumerated() {
            context.append(.item(kind, index: index, checked: item.checked))
            walk(item.blocks)
            context.removeLast()
          }
        case .unknown:
          break
        }
      }
    }
    walk(blocks)
    return result
  }

  /// The smallest replacement that turns this document's linear form into
  /// `other`'s: the range replaced here and the replacement's length. `nil`
  /// when the linear forms are the same, which includes documents that differ
  /// only in unknown blocks.
  ///
  /// Text blocks are compared with their containers, so wrapping a block in a
  /// quote replaces that block. Within a single changed text block, only the
  /// units between the common prefix and suffix are replaced.
  func difference(to other: Document) -> (range: Range<Int>, length: Int)? {
    let a = leaves
    let b = other.leaves
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix].matches(b[prefix]) { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
      a[a.count - 1 - suffix].matches(b[b.count - 1 - suffix])
    {
      suffix += 1
    }
    if prefix == a.count, prefix == b.count { return nil }
    // One text block changed in place: replace only what differs inside it.
    if a.count - suffix - prefix == 1, b.count - suffix - prefix == 1,
      a[prefix].context == b[prefix].context,
      let range = Self.difference(a[prefix].block, b[prefix].block)
    {
      let start = a[prefix].start
      return (start + range.range.lowerBound..<start + range.range.upperBound, range.length)
    }
    let aLength = a.last.map { $0.start + $0.length } ?? 0
    let bLength = b.last.map { $0.start + $0.length } ?? 0
    // Where leaf `i` starts; past the end, where one after a final separator
    // would.
    func start(_ leaves: [Leaf], _ index: Int, _ length: Int) -> Int {
      index < leaves.count ? leaves[index].start : length + 1
    }
    if suffix > 0 {
      let lower = start(a, prefix, aLength)
      let upper = start(a, a.count - suffix, aLength)
      let length = start(b, b.count - suffix, bLength) - start(b, prefix, bLength)
      return (lower..<upper, length)
    }
    if prefix > 0 {
      // Include the separator before the changed blocks.
      let lower = start(a, prefix, aLength) - 1
      return (lower..<aLength, bLength - (start(b, prefix, bLength) - 1))
    }
    return (0..<aLength, bLength)
  }

  /// The units that differ between two versions of a text block, if they are
  /// the same kind.
  private static func difference(_ a: Block, _ b: Block) -> (range: Range<Int>, length: Int)? {
    switch (a, b) {
    case (.paragraph(let x), .paragraph(let y)):
      return difference(units(x), units(y), code: \.code)
    case (.codeBlock(let l1, let x), .codeBlock(let l2, let y)) where l1 == l2:
      return difference(Array(x.utf16), Array(y.utf16), code: { $0 })
    default:
      return nil
    }
  }

  private enum ParagraphUnit: Equatable {
    case text(UInt16, Marks)
    case node(Inline)

    var code: UInt16? {
      if case .text(let code, _) = self { return code }
      return nil
    }
  }

  private static func units(_ inlines: [Inline]) -> [ParagraphUnit] {
    var result: [ParagraphUnit] = []
    for inline in inlines {
      if case .text(let text, let marks) = inline {
        for unit in text.utf16 { result.append(.text(unit, marks)) }
      } else {
        result.append(.node(inline))
      }
    }
    return result
  }

  /// The common prefix and suffix, never splitting a surrogate pair.
  private static func difference<T: Equatable>(
    _ a: [T], _ b: [T], code: (T) -> UInt16?
  ) -> (range: Range<Int>, length: Int) {
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    if prefix > 0, let unit = code(a[prefix - 1]), UTF16.isLeadSurrogate(unit) { prefix -= 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
      a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
    {
      suffix += 1
    }
    if suffix > 0, let unit = code(a[a.count - suffix]), UTF16.isTrailSurrogate(unit) {
      suffix -= 1
    }
    return (prefix..<a.count - suffix, b.count - suffix - prefix)
  }
}
