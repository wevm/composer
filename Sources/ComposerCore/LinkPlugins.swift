// The link plugins, all in `.chatDefaults`: autolink while typing and on
// paste, pasting a URL over a selection, and ⌘K link editing.

/// Bare URLs (`https://…`, `http://…`, `www.…`) become links when a space
/// is typed after them, and in pasted text.
public struct Autolink: ComposerPlugin {
  public init() {}

  public func register(in registry: inout PluginRegistry) {
    registry.addTransform("links.autolink") { state, range in
      Self.linkTyped(&state, in: range)
    }
    registry.addPasteTransform { $0.autolinked() }
  }

  /// The URL a word stands for, or `nil`: the word without trailing
  /// punctuation (a closing parenthesis stays if the URL opened one), with
  /// `https://` before a `www.` word.
  static func url(in word: Substring) -> (url: String, length: Int)? {
    var word = word
    while let last = word.last, ".,:;!?'\"]}".contains(last) || last == ")" {
      if last == ")", word.filter({ $0 == "(" }).count >= word.filter({ $0 == ")" }).count {
        break
      }
      word = word.dropLast()
    }
    let lower = word.lowercased()
    let schemes = ["https://", "http://"]
    if let scheme = schemes.first(where: lower.hasPrefix), word.count > scheme.count + 2,
      word.dropFirst(scheme.count).contains(".")
    {
      return (String(word), word.utf16.count)
    }
    if lower.hasPrefix("www."), word.count > 6, word.dropFirst(4).contains(".") {
      return ("https://" + word, word.utf16.count)
    }
    return nil
  }

  /// Links the word before a just-typed space, if it is a URL.
  static func linkTyped(_ state: inout EditorState, in range: DocumentRange) {
    guard let (location, caret) = MarkdownSupport.caretBlock(state),
      range.lowerBound.offset <= caret, caret <= range.upperBound.offset,
      MarkdownSupport.justTyped(state, at: caret),
      let text = state.document.plainTextBefore(Position(caret), in: location, limit: 512),
      let space = text.utf16.last, MarkdownSupport.isWhitespace(space)
    else { return }
    let before = text.dropLast()
    let word = before.split(whereSeparator: \.isWhitespace).last.map { Substring($0) } ?? ""
    guard before.hasSuffix(word), let (url, length) = url(in: word) else { return }
    let start = caret - 1 - word.utf16.count
    let linkRange = Position(start)..<Position(start + length)
    // Not over text that is already a link or code.
    guard state.document.marks(at: Position(start + 1)).link == nil,
      !state.document.marks(at: Position(start + 1)).code
    else { return }
    state.setLink(url, in: linkRange)
  }
}

extension Document {
  /// The document with bare URLs in its paragraphs' unmarked text linked.
  public func autolinked() -> Document {
    Document(blocks: blocks.map(Self.autolinked))
  }

  private static func autolinked(_ block: Block) -> Block {
    switch block {
    case .paragraph(let inlines):
      var result: [Inline] = []
      for inline in inlines {
        guard case .text(let text, let marks) = inline, marks.link == nil, !marks.code else {
          result.append(inline)
          continue
        }
        var rest = Substring(text)
        var plain = ""
        while !rest.isEmpty {
          let wordEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
          let word = rest[..<wordEnd]
          if let (url, length) = Autolink.url(in: word) {
            if !plain.isEmpty { result.append(.text(plain, marks: marks)) }
            plain = ""
            let end = word.utf16.index(word.startIndex, offsetBy: length)
            var linked = marks
            linked.link = url
            result.append(.text(String(word[..<end]), marks: linked))
            plain += word[end...]
          } else {
            plain += word
          }
          let spaceEnd = rest[wordEnd...].firstIndex(where: { !$0.isWhitespace }) ?? rest.endIndex
          plain += rest[wordEnd..<spaceEnd]
          rest = rest[spaceEnd...]
        }
        if !plain.isEmpty { result.append(.text(plain, marks: marks)) }
      }
      return .paragraph(result)
    case .quote(let children):
      return .quote(children.map(autolinked))
    case .list(let kind, let items):
      return .list(
        kind,
        items: items.map { ListItem(checked: $0.checked, blocks: $0.blocks.map(autolinked)) })
    case .codeBlock, .unknown:
      return block
    }
  }
}

/// Pasting a URL over selected text in one block makes the text a link to
/// it, rather than replacing it.
public struct PasteLinkOverSelection: ComposerPlugin {
  public init() {}

  public func register(in registry: inout PluginRegistry) {
    registry.addPasteHandler(priority: .high) { source, _, controller in
      guard case .plainText(let text) = source,
        let (url, length) = Autolink.url(in: Substring(text.trimmingMarkdownWhitespace())),
        length == text.trimmingMarkdownWhitespace().utf16.count
      else { return false }
      let range = controller.selection.range
      guard !range.isEmpty, controller.state.markedText == nil,
        let block = controller.document.textBlock(containing: range.lowerBound),
        case .paragraph = block.content, range.upperBound <= block.range.upperBound
      else { return false }
      controller.update { $0.setLink(url, in: range) }
      return true
    }
  }
}

// MARK: Link editing

/// The link being edited with ⌘K: the range it covers, and its URL if it
/// has one. The consumer renders the editor.
public struct LinkEditing: Sendable, Hashable {
  /// The text the link covers: a link at the caret, or the selection. Empty
  /// when ⌘K was pressed at a caret outside a link, so applying inserts the
  /// URL as linked text.
  public var range: DocumentRange
  public var url: String?

  public init(range: DocumentRange, url: String?) {
    self.range = range
    self.url = url
  }
}

/// ⌘K opens link editing over the link at the caret or the selection, as
/// headless state (`controller.linkEditing`) for the consumer to render.
/// Esc, or moving the selection, closes it.
public struct LinkEditingPlugin: ComposerPlugin {
  static let key = PluginKey<LinkEditing?>("links.editing", default: nil)

  public init() {}

  public func register(in registry: inout PluginRegistry) {
    registry.addTransientState(Self.key)
    registry.addKeyBinding(
      KeyBinding("k", modifiers: .command, command: .editLink, discoverabilityTitle: "Link"))
    registry.register(.editLink) { _, controller in
      controller.editLink()
      return .handled
    }
    registry.addKeyBinding(
      KeyBinding(.escape, command: Self.cancel, priority: .high) { $0[Self.key] != nil })
    registry.register(Self.cancel) { _, controller in
      guard controller.linkEditing != nil else { return .unhandled }
      controller.cancelLinkEditing()
      return .handled
    }
  }

  static let cancel = Command<Void>("links.cancelEditing")
}

extension ComposerController {
  /// The link being edited, if ⌘K opened the editor.
  public var linkEditing: LinkEditing? { state[LinkEditingPlugin.key] }

  /// Opens link editing over the link at the caret, or the selection.
  public func editLink() {
    let range = selection.range
    let link = range.isEmpty ? document.linkRun(at: range.lowerBound) : nil
    let target = link?.range ?? range
    let url =
      link?.url
      ?? (range.isEmpty ? nil : document.marks(at: Position(range.lowerBound.offset + 1)).link)
    update(undo: .none) { state in
      state[LinkEditingPlugin.key] = LinkEditing(range: target, url: url)
    }
  }

  /// Links the editing range to `url`, or with an empty range, inserts the
  /// URL as linked text (or `text`, if given).
  public func applyLink(_ url: String, text: String? = nil) {
    guard let editing = linkEditing, !url.isEmpty else { return }
    update { state in
      state[LinkEditingPlugin.key] = nil
      if editing.range.isEmpty || text != nil {
        let label = text ?? url
        state.replace(editing.range, with: [.text(label, marks: Marks(link: url))])
        state.selection = .caret(editing.range.lowerBound.offset + label.utf16.count)
      } else {
        state.setLink(url, in: editing.range)
      }
    }
  }

  /// Removes the link from the editing range.
  public func removeLink() {
    guard let editing = linkEditing else { return }
    update { state in
      state[LinkEditingPlugin.key] = nil
      state.setLink(nil, in: editing.range)
    }
  }

  public func cancelLinkEditing() {
    update(undo: .none) { $0[LinkEditingPlugin.key] = nil }
  }
}

extension Document {
  /// The extent and URL of the link run holding `position`: adjacent text
  /// runs with the same URL, in one paragraph.
  func linkRun(at position: Position) -> (range: DocumentRange, url: String)? {
    guard let block = textBlock(containing: position), case .paragraph(let inlines) = block.content
    else { return nil }
    let local = position.offset - block.range.lowerBound.offset
    var runs: [(Range<Int>, String?)] = []
    var offset = 0
    for inline in inlines {
      let link: String? = if case .text(_, let marks) = inline { marks.link } else { nil }
      let range = offset..<offset + inline.length
      if let last = runs.last, last.1 != nil, last.1 == link {
        runs[runs.count - 1].0 = last.0.lowerBound..<range.upperBound
      } else {
        runs.append((range, link))
      }
      offset += inline.length
    }
    // Inside a run, or at its end (the caret just after a link).
    guard
      let run = runs.first(where: {
        $0.1 != nil && $0.0.lowerBound < local && local <= $0.0.upperBound
      })
        ?? runs.first(where: { $0.1 != nil && $0.0.lowerBound == local }),
      let url = run.1
    else { return nil }
    let start = block.range.lowerBound.offset
    return (Position(start + run.0.lowerBound)..<Position(start + run.0.upperBound), url)
  }
}

// MARK: Presets

extension PluginGroup {
  /// The preset for features that need no app input: every markdown rule,
  /// task lists included; markdown paste; autolink, a URL pasted over a
  /// selection, and ⌘K link editing.
  public static var chatDefaults: PluginGroup {
    PluginGroup([
      PluginGroup.markdown, MarkdownPaste(), Autolink(), PasteLinkOverSelection(),
      LinkEditingPlugin(),
    ])
  }
}

extension ComposerPlugin where Self == PluginGroup {
  /// See `PluginGroup.chatDefaults`.
  public static var chatDefaults: PluginGroup { PluginGroup.chatDefaults }
}
