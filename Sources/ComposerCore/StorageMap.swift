import Foundation

// In Core, though only engines use it, so it is tested on Linux.

/// Maps document positions to text storage offsets and back. Text is one
/// storage character per unit, and a token is one unit drawn as its
/// label, several characters long, so offsets after a token shift by its
/// label's length less one. With no tokens, the map is the identity.
package struct StorageMap: Equatable, Sendable {
  /// A token's document offset, its storage offset, and its storage length.
  struct Token: Equatable, Sendable {
    var offset: Int
    var storage: Int
    var length: Int
  }

  private(set) var tokens: [Token] = []
  /// The document's length in units.
  package private(set) var documentLength: Int
  /// The storage's length.
  package var storageLength: Int { storage(documentLength) }

  /// How a storage offset inside a token rounds to a document position.
  package enum Rounding {
    case down, up, nearest
  }

  package init(document: Document, tokenLength: (Inline) -> Int) {
    documentLength = document.length
    var shift = 0
    for block in document.textBlocks {
      guard case .paragraph(let inlines) = block.content else { continue }
      var offset = block.range.lowerBound.offset
      for inline in inlines {
        switch inline {
        case .node, .unknown:
          let length = tokenLength(inline)
          tokens.append(Token(offset: offset, storage: offset + shift, length: length))
          shift += length - 1
        case .text:
          break
        }
        offset += inline.length
      }
    }
  }

  package var isIdentity: Bool { tokens.allSatisfy { $0.length == 1 } }

  /// The index of the first token at or after `offset`.
  private func firstToken(atOrAfter offset: Int, _ key: (Token) -> Int) -> Int {
    var low = 0
    var high = tokens.count
    while low < high {
      let mid = (low + high) / 2
      if key(tokens[mid]) < offset { low = mid + 1 } else { high = mid }
    }
    return low
  }

  /// The storage offset of a document position.
  package func storage(_ position: Int) -> Int {
    guard !tokens.isEmpty else { return position }
    let index = firstToken(atOrAfter: position, \.offset)
    guard index > 0 else { return position }
    let token = tokens[index - 1]
    return token.storage + token.length + (position - token.offset - 1)
  }

  /// The document position of a storage offset. One inside a token's
  /// label rounds to the token's start or end.
  package func document(_ offset: Int, rounding: Rounding = .nearest) -> Int {
    guard !tokens.isEmpty else { return offset }
    let index = firstToken(atOrAfter: offset + 1, { $0.storage + 1 })
    // `index` is the first token starting at or after `offset`; the one
    // before may contain it.
    guard index > 0 else { return offset }
    let token = tokens[index - 1]
    let end = token.storage + token.length
    if offset > token.storage, offset < end {
      switch rounding {
      case .down: return token.offset
      case .up: return token.offset + 1
      case .nearest:
        return offset - token.storage < end - offset ? token.offset : token.offset + 1
      }
    }
    if offset <= token.storage { return token.offset - (token.storage - offset) }
    return token.offset + 1 + (offset - end)
  }

  /// The token whose label holds a storage offset strictly inside it, as
  /// its document offset.
  package func token(containing offset: Int) -> Int? {
    guard !tokens.isEmpty else { return nil }
    let index = firstToken(atOrAfter: offset + 1, { $0.storage + 1 })
    guard index > 0 else { return nil }
    let token = tokens[index - 1]
    return offset > token.storage && offset < token.storage + token.length ? token.offset : nil
  }

  /// The storage range of a document range.
  package func storage(_ range: DocumentRange) -> NSRange {
    let lower = storage(range.lowerBound.offset)
    return NSRange(location: lower, length: storage(range.upperBound.offset) - lower)
  }

  /// The document range of a storage range, grown to whole tokens.
  package func document(_ range: NSRange) -> DocumentRange {
    let lower = document(range.location, rounding: .down)
    let upper = document(NSMaxRange(range), rounding: range.length == 0 ? .down : .up)
    return Position(lower)..<Position(max(lower, upper))
  }
}
