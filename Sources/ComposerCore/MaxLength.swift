// Max length: a soft limit that disables send, or a hard one that stops
// input at the limit.

/// The length of the document against a `MaxLength` limit, for a footer
/// counter. In the state under `MaxLength.statusKey`.
public struct LengthStatus: Sendable, Hashable {
  public var count: Int
  public var limit: Int
  public var mode: MaxLength.Mode

  public init(count: Int, limit: Int, mode: MaxLength.Mode) {
    self.count = count
    self.limit = limit
    self.mode = mode
  }

  /// Over a soft limit (a hard one isn't exceeded by input).
  public var isOver: Bool { count > limit }
  /// How many more fit, or, negative, how far over the count is.
  public var remaining: Int { limit - count }
}

/// Limits the message's length. There is no limit unless this plugin is
/// added.
///
/// - A **soft** limit lets the user keep typing: the status shows the
///   overflow, and send is disabled.
/// - A **hard** limit stops input at the limit: an update that would take the
///   count over it, and past where it was, loses the end of what it
///   inserted (all of a typed character; the end of a paste), and
///   `onDidTruncate` gets the text removed from anything longer than one
///   character.
///
/// The count is the length in characters of the serialized markdown, since
/// that is what servers store and limit, unless `count` says otherwise.
public struct MaxLength: ComposerPlugin {
  public enum Mode: Sendable, Hashable {
    case soft
    case hard
  }

  public static let statusKey = PluginKey<LengthStatus?>("composer.maxLength", default: nil)

  let limit: Int
  let mode: Mode
  let count: (@Sendable (Document) -> Int)?
  var didTruncate: (@MainActor @Sendable (String) -> Void)?

  public init(_ limit: Int, mode: Mode = .soft, count: (@Sendable (Document) -> Int)? = nil) {
    self.limit = limit
    self.mode = mode
    self.count = count
  }

  /// Called with the text a hard limit removed from a paste or other
  /// insertion, so the app can tell the user.
  public func onDidTruncate(_ body: @escaping @MainActor @Sendable (String) -> Void) -> MaxLength {
    var copy = self
    copy.didTruncate = body
    return copy
  }

  public func register(in registry: inout PluginRegistry) {
    let (limit, mode, custom) = (limit, mode, count)
    registry.updateFilters.append { before, state, schema in
      let counter: (Document) -> Int =
        custom ?? { MarkdownCodec(schema: schema).serialize($0).count }
      let edits = state.tracking?.edits ?? []
      if edits.isEmpty, state[Self.statusKey] != nil { return }
      var count = counter(state.document)
      if mode == .hard, count > limit, !edits.isEmpty, count > counter(before.document),
        let edit = Changeset(
          edits: edits, selectionBefore: before.selection, selectionAfter: before.selection
        ).combinedEdit
      {
        let start = edit.range.lowerBound.offset
        let removed = Self.truncate(
          &state, inserted: start..<start + edit.replacementLength, limit: limit, counter: counter)
        if removed.count > 1 { state.tracking?.truncated += removed }
        count = counter(state.document)
      }
      state[Self.statusKey] = LengthStatus(count: count, limit: limit, mode: mode)
    }
    if let didTruncate {
      registry.onDidUpdate { _, changeset in
        if !changeset.truncated.isEmpty { didTruncate(changeset.truncated) }
      }
    }
  }

  /// Removes the shortest end of `inserted` that brings the count within the
  /// limit (or all of it), on character boundaries. Returns the removed text.
  static func truncate(
    _ state: inout EditorState, inserted: Range<Int>, limit: Int, counter: (Document) -> Int
  ) -> String {
    let document = state.document
    // The character boundaries in the inserted span, from its start.
    var boundaries = [inserted.lowerBound]
    while let last = boundaries.last, last < inserted.upperBound {
      let next = document.boundary(after: last)
      guard next > last else { break }
      boundaries.append(min(next, inserted.upperBound))
    }
    func fits(keeping index: Int) -> Bool {
      var probe = EditorState(document: document)
      probe.delete(Position(boundaries[index])..<Position(inserted.upperBound))
      return counter(probe.document) <= limit
    }
    // The most of the insertion that fits: a binary search, since keeping
    // more never shortens the count.
    var (low, high) = (0, boundaries.count - 1)
    if fits(keeping: high) { return "" }
    while low < high {
      let middle = (low + high + 1) / 2
      if fits(keeping: middle) { low = middle } else { high = middle - 1 }
    }
    let cut = boundaries[low]..<inserted.upperBound
    let removed = document.plainText(in: cut)
    state.delete(Position(cut.lowerBound)..<Position(cut.upperBound))
    return removed
  }
}

extension Document {
  /// The document's text: tokens as their labels, unknown nodes as their
  /// fallback text, and a newline between text blocks.
  public var plainText: String { plainText(in: 0..<length) }

  /// The text of a range of the linear form (see `plainText`).
  public func plainText(in range: Range<Int>) -> String {
    var result = ""
    var previousEnd: Int?
    forEachTextBlock(in: Position(range.lowerBound)..<Position(range.upperBound)) { block, _ in
      let start = block.range.lowerBound.offset
      let lower = max(start, range.lowerBound)
      let upper = min(block.range.upperBound.offset, range.upperBound)
      // The separator before this block, if the range covers it.
      if previousEnd != nil || (range.lowerBound < start) { result += "\n" }
      previousEnd = upper
      guard lower < upper else { return }
      switch block.content {
      case .code(_, let text):
        result += Self.slice(text, lower - start..<upper - start)
      case .paragraph(let inlines):
        var offset = start
        for inline in inlines {
          let length = inline.length
          defer { offset += length }
          let (a, b) = (max(offset, lower), min(offset + length, upper))
          guard a < b else { continue }
          switch inline {
          case .text(let text, _): result += Self.slice(text, a - offset..<b - offset)
          case .node(let node): result += node.label
          case .unknown(let node): result += node.text
          }
        }
      }
    }
    return result
  }

  private static func slice(_ text: String, _ range: Range<Int>) -> String {
    let utf16 = text.utf16
    let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
    let upper = utf16.index(lower, offsetBy: range.count)
    return String(text[lower..<upper])
  }
}
