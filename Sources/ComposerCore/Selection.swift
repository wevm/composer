/// A position in a document, as an offset into its linear form.
///
/// The linear form is the document's text blocks (paragraphs and code blocks)
/// in order, separated by one unit. Text counts in UTF-16 code units, the unit
/// of `NSString` and TextKit, and each atomic or unknown inline node counts as
/// one unit, so no position falls inside a token. Containers (quotes, lists,
/// items) and unknown blocks add no units of their own. Editing rounds a
/// position inside a surrogate pair down to the start of the pair.
public struct Position: Sendable, Hashable, Comparable, ExpressibleByIntegerLiteral,
  CustomStringConvertible
{
  public var offset: Int

  public init(_ offset: Int) { self.offset = offset }
  public init(integerLiteral value: Int) { self.offset = value }

  public static func < (lhs: Position, rhs: Position) -> Bool { lhs.offset < rhs.offset }
  public var description: String { "\(offset)" }
}

/// A range of positions in a document.
public typealias DocumentRange = Range<Position>

extension Range where Bound == Position {
  /// The range's length in document units.
  public var length: Int { upperBound.offset - lowerBound.offset }

  init(offsets: Range<Int>) {
    self = Position(offsets.lowerBound)..<Position(offsets.upperBound)
  }

  var offsets: Range<Int> { lowerBound.offset..<upperBound.offset }
}

public struct Selection: Sendable, Hashable, CustomStringConvertible {
  public var anchor: Position
  public var head: Position

  public init(anchor: Position, head: Position) {
    self.anchor = anchor
    self.head = head
  }

  /// A collapsed selection: a caret.
  public init(_ position: Position) {
    self.init(anchor: position, head: position)
  }

  /// A forward selection of `range`.
  public init(_ range: DocumentRange) {
    self.init(anchor: range.lowerBound, head: range.upperBound)
  }

  public static func caret(_ offset: Int) -> Selection { Selection(Position(offset)) }

  public var isCollapsed: Bool { anchor == head }
  public var range: DocumentRange { min(anchor, head)..<max(anchor, head) }

  public var description: String {
    isCollapsed ? "caret(\(head))" : "\(anchor)→\(head)"
  }

  func clamped(to length: Int) -> Selection {
    Selection(
      anchor: Position(min(max(anchor.offset, 0), length)),
      head: Position(min(max(head.offset, 0), length)))
  }
}

/// An IME composition in progress: the marked text sits in the document at
/// `range`. Transforms are paused while it exists.
public struct MarkedText: Sendable, Hashable {
  public var range: DocumentRange
  /// The selection within the marked text, relative to `range.lowerBound`.
  public var selectedRange: Range<Int>?

  public init(range: DocumentRange, selectedRange: Range<Int>? = nil) {
    self.range = range
    self.selectedRange = selectedRange
  }
}
