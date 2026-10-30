// Paste: handlers that act on a paste themselves (a URL over a selection),
// mappers that turn the pasteboard's content into a document fragment
// (markdown, rich text), transforms of the fragment (autolink), and inserting
// the fragment at the selection.

/// Turns pasted content into a document fragment.
public protocol PasteMapper: Sendable {
  func map(_ source: PasteSource) -> PasteResult
}

public enum PasteResult: Sendable {
  case document(Document)
  /// The mapper doesn't handle this content; the next one tries.
  case unhandled
}

/// How a paste is asked for.
public struct PasteOptions: Sendable, Hashable {
  /// Paste and Match Style (⌘⇧V): text goes in as it is, without mappers.
  public var matchesStyle: Bool

  public init(matchesStyle: Bool = false) {
    self.matchesStyle = matchesStyle
  }
}

extension PluginRegistry {
  /// Adds a handler that may act on a paste itself, before any mapping.
  /// Handlers run from highest priority to lowest; the first to return
  /// `true` ends the paste.
  public mutating func addPasteHandler(
    priority: Priority = .normal,
    _ handler:
      @escaping @MainActor @Sendable (PasteSource, PasteOptions, ComposerController)
      -> Bool
  ) {
    let handlers = paste.handlers
    let index = handlers.firstIndex { $0.0 <= priority } ?? handlers.count
    paste.handlers.insert((priority, handler), at: index)
  }

  /// Adds a mapper, tried before the ones added earlier.
  public mutating func addPasteMapper(_ mapper: any PasteMapper) {
    paste.mappers.insert(mapper, at: 0)
  }

  /// Adds a transform of every pasted fragment, such as autolinking.
  public mutating func addPasteTransform(_ transform: @escaping @Sendable (Document) -> Document) {
    paste.transforms.append(transform)
  }
}

/// The plain-text mapping, when no mapper takes the content: its text as
/// one paragraph, line breaks and all.
func plainFragment(_ source: PasteSource) -> Document? {
  switch source {
  case .plainText(let text):
    let text = Normalizer.lineEndings(text)
    guard !text.isEmpty else { return nil }
    return Document(blocks: [.paragraph([.text(text, marks: Marks())])])
  }
}

extension ComposerController {
  /// Pastes over the marked text or the selection: handlers first, then the
  /// first mapper that takes the content (unless it matches style), then
  /// the plain text; the fragment then goes through the paste transforms.
  public func paste(_ source: PasteSource, options: PasteOptions = PasteOptions()) {
    for (_, handler) in pasteConfiguration.handlers where handler(source, options, self) {
      return
    }
    var fragment: Document?
    if !options.matchesStyle {
      for mapper in pasteConfiguration.mappers {
        if case .document(let document) = mapper.map(source) {
          fragment = document
          break
        }
      }
    }
    guard var fragment = fragment ?? plainFragment(source),
      fragment.length > 0
        || fragment.blocks.count > 1
    else { return }
    for transform in pasteConfiguration.transforms { fragment = transform(fragment) }
    update { state in
      let target = state.markedText?.range ?? state.selection.range
      state.markedText = nil
      state.insert(fragment, over: target)
    }
  }
}

extension EditorState {
  /// Inserts a document fragment over `range` and puts the caret after it.
  /// A single paragraph's content goes into the block at the range, which
  /// keeps its kind; other blocks go in beside it, in its container, with
  /// the first and last paragraphs joining the text before and after.
  /// Into a code block, the fragment goes as plain text.
  public mutating func insert(_ fragment: Document, over range: DocumentRange) {
    let blocks = fragment.blocks
    guard !blocks.isEmpty else { return }
    if blocks.count == 1, case .paragraph(let inlines) = blocks[0] {
      insert(inlines, over: range)
      return
    }
    delete(range)
    let caret = range.lowerBound.offset
    guard let location = document.location(of: Position(caret)) else { return }
    guard case .paragraph(let inlines) = document.block(at: location.path) else {
      // A code block takes the text.
      let text = fragment.textBlocks.map { block -> String in
        switch block.content {
        case .code(_, let text): return text
        case .paragraph(let inlines):
          return inlines.map { inline -> String in
            if case .text(let text, _) = inline { return text }
            return ""
          }.joined()
        }
      }.joined(separator: "\n")
      insert(text, at: .caret(caret), marks: Marks())
      return
    }
    // The paragraph's content before and after the caret.
    var split = EditorState(document: Document(blocks: [.paragraph(inlines)]))
    split.splitBlock(at: Position(caret - location.range.lowerBound.offset))
    guard case .paragraph(let before) = split.document.blocks[0],
      case .paragraph(let after) = split.document.blocks[1]
    else { return }
    var replacement = blocks
    if case .paragraph(let first) = replacement[0] {
      replacement[0] = .paragraph(Normalizer.inlines(before + first))
    } else if !before.isEmpty {
      replacement.insert(.paragraph(before), at: 0)
    }
    // The caret goes after the pasted content: before the text that was
    // after it, or the separator before that text's new paragraph.
    var caretShift = 0
    if case .paragraph(let last) = replacement[replacement.count - 1] {
      replacement[replacement.count - 1] = .paragraph(Normalizer.inlines(last + after))
    } else {
      replacement.append(.paragraph(after))
      caretShift = 1
    }
    let following = document.length - caret
    var document = self.document
    document.modifyBlocks(containing: location.path) { array, index in
      array.replaceSubrange(index...index, with: replacement)
    }
    self.document = document
    // Everything after the caret is kept, so the caret is that far from
    // the end.
    selection = .caret(document.length - following - caretShift)
  }
}

/// A controller's paste configuration, from its plugins.
struct PasteConfiguration: Sendable {
  var handlers:
    [(Priority, @MainActor @Sendable (PasteSource, PasteOptions, ComposerController) -> Bool)] = []
  var mappers: [any PasteMapper] = []
  var transforms: [@Sendable (Document) -> Document] = []
}

// MARK: Markdown paste

/// Pasted plain text that looks like markdown is parsed as markdown, with
/// the composer's schema, so tokens come through. "Looks like markdown"
/// means parsing it finds any syntax: text whose parse is just its own
/// paragraphs goes in as text. Paste and Match Style pastes it literally.
public struct MarkdownPaste: ComposerPlugin {
  public init() {}

  public func register(in registry: inout PluginRegistry) {
    registry.addPasteMapper(MarkdownPasteMapper(schema: registry.schema))
  }
}

struct MarkdownPasteMapper: PasteMapper {
  let schema: Schema

  func map(_ source: PasteSource) -> PasteResult {
    guard case .plainText(let pasted) = source else { return .unhandled }
    let text = Normalizer.lineEndings(pasted)
    let parsed = MarkdownCodec(schema: schema).parse(text)
    // Plain text with no syntax parses to paragraphs of its own lines.
    let isPlain = parsed.blocks.allSatisfy { block in
      guard case .paragraph(let inlines) = block else { return false }
      return inlines.allSatisfy { inline in
        if case .text(_, let marks) = inline { return marks.isEmpty }
        return false
      }
    }
    let literal = text.replacingOccurrences(of: "\n\n", with: "\n")
    if isPlain, plainText(of: parsed) == literal.trimmingMarkdownWhitespace() {
      return .unhandled
    }
    return .document(parsed)
  }

  private func plainText(of document: Document) -> String {
    document.blocks.map { block -> String in
      guard case .paragraph(let inlines) = block else { return "" }
      return inlines.map { inline -> String in
        if case .text(let text, _) = inline { return text }
        return ""
      }.joined()
    }.joined(separator: "\n")
  }
}
