// Structural editing: the block tree around a text block, and the list,
// quote, and code block operations the markdown plugins run. Containers add
// no units to the linear form, so moving a text block into or out of one
// keeps every position where it was.

/// Where a text block sits in the block tree: its path, and the containers
/// around it, outermost first.
public struct BlockLocation: Sendable, Hashable {
  public enum Container: Sendable, Hashable {
    /// A quote, at `path`.
    case quote(path: [Int])
    /// Item `item` of the list at `path`.
    case item(list: [Int], item: Int)
  }

  /// The text block's path (see `Document.block(at:)`).
  public var path: [Int]
  public var containers: [Container]
  /// The text block's content range.
  public var range: DocumentRange

  /// The block's index in the `[Block]` array that holds it.
  public var index: Int { path.last! }

  /// The innermost container, if any.
  public var parent: Container? { containers.last }

  /// The list nesting level of the innermost list item: 1 for a top-level
  /// list. Levels count again inside a quote.
  public var listLevel: Int {
    var level = 0
    for container in containers {
      switch container {
      case .quote: level = 0
      case .item: level += 1
      }
    }
    return level
  }
}

extension Document {
  /// The location of the text block containing `position`.
  public func location(of position: Position) -> BlockLocation? {
    guard let leaf = locate(position.offset) else { return nil }
    return BlockLocation(
      path: leaf.path, containers: containers(along: leaf.path),
      range: .init(offsets: leaf.start..<leaf.end))
  }

  /// The containers a path runs through, outermost first.
  func containers(along path: [Int]) -> [BlockLocation.Container] {
    var result: [BlockLocation.Container] = []
    var blocks = self.blocks
    var prefix: [Int] = []
    var index = 0
    while index < path.count - 1 {
      let block = blocks[path[index]]
      prefix.append(path[index])
      switch block {
      case .quote(let children):
        result.append(.quote(path: prefix))
        blocks = children
        index += 1
      case .list(_, let items):
        let item = path[index + 1]
        result.append(.item(list: prefix, item: item))
        prefix.append(item)
        blocks = items[item].blocks
        index += 2
      default:
        preconditionFailure("Path runs through a leaf")
      }
    }
    return result
  }

  /// Calls `body` with the block at `path`, to change it in place.
  public mutating func modifyBlock(at path: [Int], _ body: (inout Block) -> Void) {
    modifyContainer(of: path[...]) { blocks, index in body(&blocks[index]) }
  }

  /// Calls `body` with the array holding the block at `path`, and the
  /// block's index in it.
  public mutating func modifyBlocks(
    containing path: [Int], _ body: (inout [Block], Int) -> Void
  ) {
    modifyContainer(of: path[...], body)
  }
}

extension ListKind {
  /// Bullet and ordered lists are different kinds, whatever the start.
  public func matches(_ other: ListKind) -> Bool {
    switch (self, other) {
    case (.bullet, .bullet), (.ordered, .ordered): true
    default: false
    }
  }

  func advanced(by count: Int) -> ListKind {
    if case .ordered(let start) = self { return .ordered(start: start + count) }
    return self
  }
}

/// The deepest list nesting inside some blocks: 0 with no lists.
func listDepth(of blocks: [Block]) -> Int {
  var depth = 0
  for block in blocks {
    switch block {
    case .list(_, let items):
      for item in items { depth = max(depth, 1 + listDepth(of: item.blocks)) }
    default:
      break
    }
  }
  return depth
}

/// Structural edits on a document. Each returns `nil` when it doesn't
/// apply, so key bindings can ask before they claim a key.
public enum Structure {
  /// The deepest list level.
  public static let maxListLevel = 3

  /// The list item a text block is directly in: the item's container, and
  /// the block's index among the item's blocks.
  static func item(of location: BlockLocation) -> (list: [Int], item: Int, block: Int)? {
    guard case .item(let list, let item) = location.parent,
      location.path.count == list.count + 2
    else { return nil }
    return (list, item, location.index)
  }

  /// The quote a text block is directly in, and the block's index in it.
  static func quote(of location: BlockLocation) -> (quote: [Int], child: Int)? {
    guard case .quote(let quote) = location.parent, location.path.count == quote.count + 1 else {
      return nil
    }
    return (quote, location.index)
  }

  /// Wraps the paragraph at `location` in a list item, joining a list of the
  /// same kind just before it. Not the first block of a list item (that
  /// would be an item made of a list), and not past the deepest level.
  public static func wrapInList(
    _ document: Document, at location: BlockLocation, kind: ListKind, checked: Bool? = nil
  ) -> Document? {
    guard case .paragraph = document.block(at: location.path),
      location.listLevel < maxListLevel
    else { return nil }
    if let item = item(of: location), item.block == 0 { return nil }
    var document = document
    document.modifyBlocks(containing: location.path) { blocks, index in
      let listItem = ListItem(checked: checked, blocks: [blocks[index]])
      if index > 0, case .list(let previous, var items) = blocks[index - 1],
        previous.matches(kind)
      {
        items.append(listItem)
        blocks[index - 1] = .list(previous, items: items)
        blocks.remove(at: index)
      } else {
        blocks[index] = .list(kind, items: [listItem])
      }
    }
    return document
  }

  /// Wraps the paragraph at `location` in a quote, joining a quote just
  /// before it.
  public static func wrapInQuote(_ document: Document, at location: BlockLocation) -> Document? {
    guard case .paragraph = document.block(at: location.path) else { return nil }
    if let item = item(of: location), item.block == 0 { return nil }
    var document = document
    document.modifyBlocks(containing: location.path) { blocks, index in
      if index > 0, case .quote(var children) = blocks[index - 1] {
        children.append(blocks[index])
        blocks[index - 1] = .quote(children)
        blocks.remove(at: index)
      } else {
        blocks[index] = .quote([blocks[index]])
      }
    }
    return document
  }

  /// Sets the task state of the list item whose first block is at
  /// `location`.
  public static func setChecked(
    _ checked: Bool?, _ document: Document, at location: BlockLocation
  ) -> Document? {
    guard let item = item(of: location), item.block == 0 else { return nil }
    var document = document
    var changed = false
    document.modifyBlock(at: item.list) { block in
      guard case .list(let kind, var items) = block, items[item.item].checked != checked else {
        return
      }
      items[item.item].checked = checked
      block = .list(kind, items: items)
      changed = true
    }
    return changed ? document : nil
  }

  /// Splits the list item holding the paragraph at `location` at `offset`:
  /// the item keeps what comes before, and a new item after it takes the
  /// rest, unchecked if it's a task. The caret moves one unit, past the new
  /// separator.
  public static func splitItem(
    _ document: Document, at location: BlockLocation, offset: Int
  ) -> Document? {
    guard let item = item(of: location),
      case .paragraph(let inlines) = document.block(at: location.path)
    else { return nil }
    var split = EditorState(document: Document(blocks: [.paragraph(inlines)]))
    split.splitBlock(at: Position(offset - location.range.lowerBound.offset))
    let halves = split.document.blocks
    var document = document
    document.modifyBlock(at: item.list) { block in
      guard case .list(let kind, var items) = block else { return }
      let old = items[item.item]
      let first = ListItem(
        checked: old.checked, blocks: Array(old.blocks[..<item.block]) + [halves[0]])
      let second = ListItem(
        checked: old.checked.map { _ in false },
        blocks: [halves[1]] + old.blocks[(item.block + 1)...])
      items[item.item] = first
      items.insert(second, at: item.item + 1)
      block = .list(kind, items: items)
    }
    return document
  }

  /// Whether the paragraph at `location` is an empty list item: the item's
  /// only block, with no text.
  public static func isEmptyItem(_ document: Document, at location: BlockLocation) -> Bool {
    guard let item = item(of: location), item.block == 0, location.range.isEmpty,
      case .list(_, let items) = document.block(at: item.list)
    else { return false }
    return items[item.item].blocks.count == 1
  }

  /// Moves the list item holding `location` one level in, into the item
  /// before it. Not the first item, and not past the deepest level.
  public static func sinkItem(_ document: Document, at location: BlockLocation) -> Document? {
    guard
      case .item(let list, let index)? = location.containers.last(where: {
        if case .item = $0 { return true }
        return false
      }), index > 0, case .list(let kind, var items) = document.block(at: list)
    else { return nil }
    let level = levelOfItem(in: location, list: list)
    let moving = items[index]
    guard level + 1 + listDepth(of: moving.blocks) <= maxListLevel else { return nil }
    items.remove(at: index)
    var previous = items[index - 1]
    if case .list(let inner, var children)? = previous.blocks.last, inner.matches(kind) {
      children.append(moving)
      previous.blocks[previous.blocks.count - 1] = .list(inner, items: children)
    } else {
      let innerKind: ListKind = if case .ordered = kind { .ordered(start: 1) } else { .bullet }
      previous.blocks.append(.list(innerKind, items: [moving]))
    }
    items[index - 1] = previous
    var document = document
    document.modifyBlock(at: list) { $0 = .list(kind, items: items) }
    return document
  }

  /// The level of the list at `list` among `location`'s containers.
  private static func levelOfItem(in location: BlockLocation, list: [Int]) -> Int {
    var level = 0
    for container in location.containers {
      switch container {
      case .quote: level = 0
      case .item(let path, _):
        level += 1
        if path == list { return level }
      }
    }
    return level
  }

  /// Moves the list item holding `location` one level out. A nested item
  /// moves after its parent item, taking the items after it as its
  /// children. A top-level item leaves the list: its blocks take its place,
  /// splitting the list around them.
  public static func liftItem(_ document: Document, at location: BlockLocation) -> Document? {
    let items = location.containers.enumerated().compactMap { offset, container in
      if case .item(let list, let item) = container { return (offset, list, item) }
      return nil
    }
    guard let (position, list, index) = items.last else { return nil }
    var document = document
    guard case .list(let kind, var siblings) = document.block(at: list) else { return nil }
    if position > 0,
      case .item(let parentList, let parentIndex) = location.containers[position - 1],
      list.count == parentList.count + 2
    {
      // Nested: out after the parent item.
      var moving = siblings[index]
      let after = Array(siblings[(index + 1)...])
      siblings.removeSubrange(index...)
      if !after.isEmpty {
        if case .list(let inner, var children)? = moving.blocks.last, inner.matches(kind) {
          children.append(contentsOf: after)
          moving.blocks[moving.blocks.count - 1] = .list(inner, items: children)
        } else {
          moving.blocks.append(.list(kind.advanced(by: index + 1), items: after))
        }
      }
      document.modifyBlock(at: parentList) { block in
        guard case .list(let parentKind, var parents) = block else { return }
        var parent = parents[parentIndex]
        // The nested list is a block of the parent item: the last part of
        // its path.
        let listIndex = list[list.count - 1]
        if siblings.isEmpty {
          parent.blocks.remove(at: listIndex)
        } else {
          parent.blocks[listIndex] = .list(kind, items: siblings)
        }
        parents[parentIndex] = parent
        parents.insert(moving, at: parentIndex + 1)
        block = .list(parentKind, items: parents)
      }
      return document
    }
    // Top level: the item's blocks replace it, between the two halves.
    let moving = siblings[index]
    let before = Array(siblings[..<index])
    let after = Array(siblings[(index + 1)...])
    var replacement: [Block] = []
    if !before.isEmpty { replacement.append(.list(kind, items: before)) }
    replacement.append(contentsOf: moving.blocks.isEmpty ? [.paragraph([])] : moving.blocks)
    if !after.isEmpty { replacement.append(.list(kind.advanced(by: index + 1), items: after)) }
    document.modifyBlocks(containing: list) { blocks, at in
      blocks.replaceSubrange(at...at, with: replacement)
    }
    return document
  }

  /// Moves the paragraph at `location` out of the quote it is directly in,
  /// splitting the quote around it.
  public static func liftOutOfQuote(_ document: Document, at location: BlockLocation) -> Document? {
    guard let (quote, child) = quote(of: location),
      case .quote(let children) = document.block(at: quote)
    else { return nil }
    let before = Array(children[..<child])
    let after = Array(children[(child + 1)...])
    var replacement: [Block] = []
    if !before.isEmpty { replacement.append(.quote(before)) }
    replacement.append(children[child])
    if !after.isEmpty { replacement.append(.quote(after)) }
    var document = document
    document.modifyBlocks(containing: quote) { blocks, at in
      blocks.replaceSubrange(at...at, with: replacement)
    }
    return document
  }

  /// Replaces the text block at `location` with other blocks.
  public static func replace(
    _ document: Document, at location: BlockLocation, with blocks: [Block]
  ) -> Document {
    var document = document
    document.modifyBlocks(containing: location.path) { array, index in
      array.replaceSubrange(index...index, with: blocks)
    }
    return document
  }
}
