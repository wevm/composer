/// What an update changed: the edited ranges and the selection before and
/// after. Engines apply it to their text storage by touching only the edited
/// ranges.
public struct Changeset: Sendable, Hashable {
  /// One replacement in the linear form. Edits are sequential: each one's
  /// `range` is in the coordinates left by the edits before it. An edit whose
  /// `replacementLength` equals its range's length may be attributes only.
  public struct Edit: Sendable, Hashable {
    public var range: DocumentRange
    public var replacementLength: Int

    public init(range: DocumentRange, replacementLength: Int) {
      self.range = range
      self.replacementLength = replacementLength
    }
  }

  public var edits: [Edit]
  public var selectionBefore: Selection
  public var selectionAfter: Selection
  /// How many transform passes ran before reaching a fixed point.
  public var transformPasses: Int
  /// Whether transforms were stopped by the pass limit instead of reaching a
  /// fixed point, which means some transform never converges.
  public var reachedTransformLimit: Bool

  public init(
    edits: [Edit] = [], selectionBefore: Selection, selectionAfter: Selection,
    transformPasses: Int = 0, reachedTransformLimit: Bool = false
  ) {
    self.edits = edits
    self.selectionBefore = selectionBefore
    self.selectionAfter = selectionAfter
    self.transformPasses = transformPasses
    self.reachedTransformLimit = reachedTransformLimit
  }

  /// Whether the update changed neither the document nor the selection.
  public var isEmpty: Bool { edits.isEmpty && selectionBefore == selectionAfter }

  /// One replacement covering every edit, in the coordinates before the
  /// update, or `nil` if the document didn't change. Its result is the range
  /// `range.lowerBound ..< range.lowerBound + replacementLength` after the
  /// update. Engines that rebuild one span of their text storage apply this.
  public var combinedEdit: Edit? {
    guard let first = edits.first else { return nil }
    var lower = first.range.lowerBound.offset
    // The span's end after the edits so far, and the same point before them.
    var upper = lower + first.replacementLength
    var upperBefore = first.range.upperBound.offset
    for edit in edits.dropFirst() {
      let (a, b) = (edit.range.lowerBound.offset, edit.range.upperBound.offset)
      // Everything outside the span is unchanged so far, so below `lower`
      // and above `upper` the coordinates before the update still hold
      // (shifted by the span's change in length).
      lower = Swift.min(lower, a)
      upperBefore += Swift.max(0, b - upper)
      upper = Swift.max(upper, b) + edit.replacementLength - (b - a)
    }
    return Edit(range: .init(offsets: lower..<upperBefore), replacementLength: upper - lower)
  }
}

extension [Changeset.Edit] {
  /// Appends `edit`, merging it into the last edit when the two touch, so a
  /// burst of typing stays one edit.
  mutating func appendCoalescing(_ edit: Changeset.Edit) {
    guard let last = self.last else {
      append(edit)
      return
    }
    let (a1, b1, n1) = (
      last.range.lowerBound.offset, last.range.upperBound.offset, last.replacementLength
    )
    let (a2, b2, n2) = (
      edit.range.lowerBound.offset, edit.range.upperBound.offset, edit.replacementLength
    )
    // `edit` is in the coordinates after `last`, where `last` produced [a1, a1 + n1).
    guard a2 <= a1 + n1, b2 >= a1 else {
      append(edit)
      return
    }
    let lower = Swift.min(a1, a2)
    let upperAfterLast = Swift.max(a1 + n1, b2)
    let upperBeforeLast = upperAfterLast == a1 + n1 ? b1 : b2 - n1 + (b1 - a1)
    let length = (upperAfterLast - lower) - (b2 - a2) + n2
    if lower == upperBeforeLast, length == 0 {
      removeLast()  // An insertion that was deleted again.
    } else {
      self[count - 1] = Changeset.Edit(
        range: .init(offsets: lower..<upperBeforeLast), replacementLength: length)
    }
  }
}

/// A sorted set of disjoint ranges that follows edits.
struct DirtyRanges: Sendable {
  private(set) var ranges: [Range<Int>] = []

  var isEmpty: Bool { ranges.isEmpty }

  mutating func insert(_ range: Range<Int>) {
    var lower = range.lowerBound
    var upper = range.upperBound
    var index = 0
    while index < ranges.count, ranges[index].upperBound < lower { index += 1 }
    var end = index
    while end < ranges.count, ranges[end].lowerBound <= upper {
      lower = Swift.min(lower, ranges[end].lowerBound)
      upper = Swift.max(upper, ranges[end].upperBound)
      end += 1
    }
    ranges.replaceSubrange(index..<end, with: CollectionOfOne(lower..<upper))
  }

  /// Maps the ranges through an edit of `edited` into `length` units. Ranges
  /// that touch the edit grow to cover its result.
  mutating func apply(_ edited: Range<Int>, length: Int, markDirty: Bool) {
    let delta = length - edited.count
    let result = edited.lowerBound..<edited.lowerBound + length
    var mapped: [Range<Int>] = []
    mapped.reserveCapacity(ranges.count + 1)
    for range in ranges {
      if range.upperBound < edited.lowerBound {
        mapped.append(range)
      } else if range.lowerBound > edited.upperBound {
        mapped.append(range.lowerBound + delta..<range.upperBound + delta)
      } else {
        let upper =
          range.upperBound > edited.upperBound ? range.upperBound + delta : result.upperBound
        mapped.append(
          Swift.min(range.lowerBound, result.lowerBound)..<Swift.max(upper, result.upperBound))
      }
    }
    ranges = []
    for range in mapped { insert(range) }
    if markDirty { insert(result) }
  }

  mutating func removeAll() { ranges.removeAll(keepingCapacity: true) }
}

extension Position {
  /// Maps the position through an edit of `edited` into `length` units. A
  /// position inside the edited range moves to the end of the replacement.
  func mapped(through edited: Range<Int>, length: Int) -> Position {
    if offset <= edited.lowerBound { return self }
    if offset >= edited.upperBound { return Position(offset + length - edited.count) }
    return Position(edited.lowerBound + length)
  }
}
