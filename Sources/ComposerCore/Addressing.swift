// Maps positions in the linear form (see `Position`) to text blocks.

/// A paragraph or code block, with its range in the document's linear form.
public struct TextBlock: Sendable, Hashable {
  public enum Content: Sendable, Hashable {
    case paragraph([Inline])
    case code(language: String?, text: String)
  }

  /// The block's content range. A caret at either end is inside the block.
  public var range: DocumentRange
  public var content: Content
}

extension Inline {
  /// The inline's length in document units: UTF-16 code units for text, one
  /// for a node.
  public var length: Int {
    switch self {
    case .text(let text, _): text.utf16.count
    case .node, .unknown: 1
    }
  }
}

extension Block {
  /// The content length of a text block, or `nil` for a container.
  var textLength: Int? {
    switch self {
    case .paragraph(let inlines):
      var length = 0
      for inline in inlines { length += inline.length }
      return length
    case .codeBlock(_, let text): return text.utf16.count
    case .quote, .list, .unknown: return nil
    }
  }
}

/// A text block's location: the index path through the block tree, and its
/// start offset and length in the linear form.
///
/// A path indexes `[Block]` arrays: a quote's children add one index, and a
/// list adds two (the item, then the block within the item).
struct LeafLocation {
  var path: [Int]
  var start: Int
  var length: Int
  var end: Int { start + length }
}

extension Document {
  /// The length of the document's linear form.
  public var length: Int {
    var total = 0
    var count = 0
    forEachLeaf { _, _, start, length in
      total = start + length
      count += 1
      return false
    }
    return count == 0 ? 0 : total
  }

  /// Every text block, in document order.
  public var textBlocks: [TextBlock] {
    var result: [TextBlock] = []
    forEachLeaf { _, block, start, length in
      result.append(
        TextBlock(range: .init(offsets: start..<start + length), content: block.content))
      return false
    }
    return result
  }

  /// The text block containing `position`. A position between two blocks'
  /// content belongs to the first one that contains it.
  public func textBlock(containing position: Position) -> TextBlock? {
    var result: TextBlock?
    forEachLeaf { _, block, start, length in
      guard position.offset <= start + length else { return false }
      if position.offset >= start {
        result = TextBlock(range: .init(offsets: start..<start + length), content: block.content)
      }
      return true
    }
    return result
  }

  func locate(_ offset: Int) -> LeafLocation? {
    var result: LeafLocation?
    forEachLeaf { path, _, start, length in
      guard offset <= start + length else { return false }
      if offset >= start { result = LeafLocation(path: path, start: start, length: length) }
      return true
    }
    return result
  }

  func block(at path: [Int]) -> Block {
    var blocks = self.blocks
    var index = 0
    while true {
      let block = blocks[path[index]]
      index += 1
      if index == path.count { return block }
      switch block {
      case .quote(let children):
        blocks = children
      case .list(_, let items):
        blocks = items[path[index]].blocks
        index += 1
      default:
        preconditionFailure("Path runs through a leaf")
      }
    }
  }

  /// Visits text blocks in order with their path, start, and length. Return
  /// `true` from `body` to stop.
  func forEachLeaf(_ body: ([Int], Block, Int, Int) -> Bool) {
    var path: [Int] = []
    path.reserveCapacity(8)
    var offset = 0
    var first = true
    _ = Self.walk(blocks, path: &path, offset: &offset, first: &first, body)
  }

  private static func walk(
    _ blocks: [Block], path: inout [Int], offset: inout Int, first: inout Bool,
    _ body: ([Int], Block, Int, Int) -> Bool
  ) -> Bool {
    for index in blocks.indices {
      path.append(index)
      defer { path.removeLast() }
      let block = blocks[index]
      switch block {
      case .paragraph, .codeBlock:
        if !first { offset += 1 }
        first = false
        let length = block.textLength!
        if body(path, block, offset, length) { return true }
        offset += length
      case .quote(let children):
        if walk(children, path: &path, offset: &offset, first: &first, body) { return true }
      case .list(_, let items):
        for item in items.indices {
          path.append(item)
          defer { path.removeLast() }
          if walk(items[item].blocks, path: &path, offset: &offset, first: &first, body) {
            return true
          }
        }
      case .unknown:
        break
      }
    }
    return false
  }

  /// Calls `body` with the `[Block]` array that holds the block at `path`, and
  /// the block's index in it. Containers on the way are taken out of the tree
  /// while `body` runs, so their storage is mutated in place.
  mutating func modifyContainer(
    of path: ArraySlice<Int>, _ body: (inout [Block], Int) -> Void
  ) {
    Self.modify(&blocks, path: path, body)
  }

  private static func modify(
    _ blocks: inout [Block], path: ArraySlice<Int>, _ body: (inout [Block], Int) -> Void
  ) {
    let index = path.first!
    if path.count == 1 {
      body(&blocks, index)
      return
    }
    let rest = path.dropFirst()
    switch blocks[index] {
    case .quote(var children):
      blocks[index] = .paragraph([])
      modify(&children, path: rest, body)
      blocks[index] = .quote(children)
    case .list(let kind, var items):
      blocks[index] = .paragraph([])
      let item = rest.first!
      var itemBlocks = items[item].blocks
      items[item].blocks = []
      modify(&itemBlocks, path: rest.dropFirst(), body)
      items[item].blocks = itemBlocks
      blocks[index] = .list(kind, items: items)
    default:
      preconditionFailure("Path runs through a leaf")
    }
  }
}

extension Block {
  var content: TextBlock.Content {
    switch self {
    case .paragraph(let inlines): .paragraph(inlines)
    case .codeBlock(let language, let text): .code(language: language, text: text)
    default: preconditionFailure("Not a text block")
    }
  }
}
