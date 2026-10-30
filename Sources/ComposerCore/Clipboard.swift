import Foundation

// Copy: the selection as markdown, JSON, and plain text, from a fragment of
// the document that keeps its structure.

/// What copying writes: markdown as plain text, for text fields and
/// terminals; the JSON form under `documentType`, so tokens survive from
/// composer to composer; and the document itself. Engines add RTF, rendered
/// from their text storage.
public struct ClipboardContent: Sendable, Hashable {
  /// The private pasteboard type whose payload is `json`.
  public static let documentType = "dev.wevm.composer.document"

  public var document: Document
  public var markdown: String
  public var json: Data
}

extension ComposerController {
  /// The clipboard content of a range, by default the selection, or `nil`
  /// if it is empty.
  public func clipboardContent(of range: DocumentRange? = nil) -> ClipboardContent? {
    let range = range ?? state.selection.range
    guard !range.isEmpty else { return nil }
    let fragment = state.document.fragment(range)
    return ClipboardContent(
      document: fragment, markdown: MarkdownCodec(schema: schema).serialize(fragment),
      json: (try? JSONCodec(schema: schema).encode(fragment)) ?? Data())
  }

  /// Pastes the JSON form of a document copied from a composer: tokens and
  /// structure come through as they were. Returns whether it decoded.
  @discardableResult
  public func pasteDocument(_ json: Data, options: PasteOptions = PasteOptions()) -> Bool {
    guard let document = try? JSONCodec(schema: schema).decode(json) else { return false }
    paste(.document(document), options: options)
    return true
  }
}

extension Document {
  /// The part of the document in `range`, with its structure: the text
  /// blocks the range touches, cut to it, inside the quotes and lists that
  /// hold them. A range that covers a separator keeps the (possibly empty)
  /// blocks on both sides, so pasting the fragment splits a block as the
  /// copied text did.
  public func fragment(_ range: DocumentRange) -> Document {
    var slicer = FragmentSlicer(lower: range.lowerBound.offset, upper: range.upperBound.offset)
    return Document(blocks: slicer.slice(blocks))
  }
}

private struct FragmentSlicer {
  let lower: Int
  let upper: Int
  var offset = 0
  var first = true

  mutating func slice(_ blocks: [Block]) -> [Block] {
    var result: [Block] = []
    for block in blocks {
      if offset > upper { break }
      switch block {
      case .paragraph(let inlines):
        guard let (start, end) = advance(block.textLength!) else { continue }
        result.append(
          .paragraph(Self.slice(inlines, max(lower, start) - start, min(upper, end) - start)))
      case .codeBlock(let language, let text):
        guard let (start, end) = advance(block.textLength!) else { continue }
        let utf16 = text.utf16
        let from = utf16.index(utf16.startIndex, offsetBy: max(lower, start) - start)
        let to = utf16.index(utf16.startIndex, offsetBy: min(upper, end) - start)
        result.append(.codeBlock(language: language, text: String(text[from..<to])))
      case .quote(let children):
        let children = slice(children)
        if !children.isEmpty { result.append(.quote(children)) }
      case .list(let kind, let items):
        var kept: [ListItem] = []
        var firstIndex: Int?
        for (index, item) in items.enumerated() {
          let blocks = slice(item.blocks)
          guard !blocks.isEmpty else { continue }
          if firstIndex == nil { firstIndex = index }
          kept.append(ListItem(checked: item.checked, blocks: blocks))
        }
        guard let firstIndex else { continue }
        if case .ordered(let start) = kind {
          result.append(.list(.ordered(start: start + firstIndex), items: kept))
        } else {
          result.append(.list(kind, items: kept))
        }
      case .unknown:
        // Unknown blocks take no room in the linear form: kept when they
        // sit inside the range or at its ends.
        if offset >= lower, offset <= upper { result.append(block) }
      }
    }
    return result
  }

  /// Steps over a text block of `length` units; returns its content range
  /// if the range touches the block or the separator before it.
  private mutating func advance(_ length: Int) -> (Int, Int)? {
    if !first { offset += 1 }
    first = false
    let start = offset
    offset += length
    return start <= upper && offset >= lower ? (start, offset) : nil
  }

  static func slice(_ inlines: [Inline], _ from: Int, _ to: Int) -> [Inline] {
    var result: [Inline] = []
    var offset = 0
    for inline in inlines {
      let length = inline.length
      defer { offset += length }
      let (a, b) = (max(offset, from), min(offset + length, to))
      guard a < b else { continue }
      if case .text(let text, let marks) = inline, a > offset || b < offset + length {
        let utf16 = text.utf16
        let lower = utf16.index(utf16.startIndex, offsetBy: a - offset)
        let upper = utf16.index(utf16.startIndex, offsetBy: b - offset)
        result.append(.text(String(text[lower..<upper]), marks: marks))
      } else {
        result.append(inline)
      }
    }
    return result
  }
}
