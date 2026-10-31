import Foundation

// The markdown plugins: input rules that convert markdown as it is typed,
// each rule its own plugin. The inline plugins share one rule that renders
// what is typed as the markdown parser reads it (see
// `MarkdownSupport.convertInline`); block rules convert
// a prefix typed at the start of a paragraph, and handle ↩, ⇥, and ⌫ inside
// lists, quotes, and code blocks. ⌫ right after any conversion reverts it to
// the characters typed.

// MARK: Inline marks

/// `**bold**` and `__bold__`, and ⌘B.
public struct MarkdownBold: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .bold, command: .toggleBold, key: "b", modifiers: .command,
      title: "Bold", in: &registry)
  }
}

/// `_italic_` and `*italic*`, and ⌘I.
public struct MarkdownItalic: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .italic, command: .toggleItalic, key: "i", modifiers: .command,
      title: "Italic", in: &registry)
  }
}

/// `~~strikethrough~~`, and ⌘⇧X.
public struct MarkdownStrikethrough: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .strikethrough, command: .toggleStrikethrough, key: "x",
      modifiers: [.command, .shift], title: "Strikethrough", in: &registry)
  }
}

/// `` `code` ``, and ⌘E.
public struct MarkdownInlineCode: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .code, command: .toggleCode, key: "e", modifiers: .command,
      title: "Code", in: &registry)
  }
}

/// `[text](url)` becomes a link when the `)` is typed.
public struct MarkdownLinks: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerInline(.link, in: &registry)
  }
}

// MARK: Blocks

/// `- `, `* `, and `1. ` at the start of a paragraph make a list item; ↩
/// starts a new item, and ↩ in an empty item leaves the list (or moves it
/// out a level); ⇥ and ⇧⇥ indent and outdent, up to 3 levels; ⌫ at the
/// start of an item outdents it.
public struct MarkdownLists: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerShared(in: &registry)
    registry.addTransform("markdown.listPrefix") { state, range in
      MarkdownSupport.convertPrefix(&state, in: range) { text in
        for bullet in ["- ", "* ", "+ "] where text.hasPrefix(bullet) {
          return (.bullet, 2)
        }
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), text.dropFirst(digits.count).hasPrefix(". "),
          let start = Int(digits)
        else { return nil }
        return (.ordered(start: start), digits.count + 2)
      } apply: { document, location, kind in
        Structure.wrapInList(document, at: location, kind: kind)
      }
    }
    registry.addSlashCommand(
      SlashCommand("list", summary: "Bulleted list") { _, controller in
        MarkdownSupport.restructureCaretBlock(controller) {
          Structure.wrapInList($0, at: $1, kind: .bullet)
        }
        return .perform
      })
    MarkdownSupport.addBlockKey(.return, "markdown.list.return", in: &registry) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state),
        Structure.item(of: location) != nil,
        case .paragraph = state.document.block(at: location.path)
      else { return nil }
      if Structure.isEmptyItem(state.document, at: location) {
        return Structure.liftItem(state.document, at: location).map { ($0, caret) }
      }
      return Structure.splitItem(state.document, at: location, offset: caret).map {
        ($0, caret + 1)
      }
    }
    MarkdownSupport.addBlockKey(
      .tab, "markdown.list.indent", title: "Indent", in: &registry
    ) { state in
      // In a list, ⇥ never types a tab: at the deepest level, or on a
      // first item, it does nothing.
      guard let location = state.document.location(of: state.selection.head),
        location.listLevel > 0
      else { return nil }
      return (
        Structure.sinkItem(state.document, at: location) ?? state.document,
        state.selection.head.offset
      )
    }
    MarkdownSupport.addBlockKey(
      .tab, modifiers: .shift, "markdown.list.outdent", title: "Outdent", in: &registry
    ) { state in
      guard let location = state.document.location(of: state.selection.head) else { return nil }
      return Structure.liftItem(state.document, at: location).map {
        ($0, state.selection.head.offset)
      }
    }
    MarkdownSupport.addBlockKey(.delete, "markdown.list.delete", in: &registry) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state),
        caret == location.range.lowerBound.offset,
        let item = Structure.item(of: location), item.block == 0
      else { return nil }
      if case .list(_, let items) = state.document.block(at: item.list),
        items[item.item].checked != nil
      {
        // A task's box goes first.
        return Structure.setChecked(nil, state.document, at: location).map { ($0, caret) }
      }
      return Structure.liftItem(state.document, at: location).map { ($0, caret) }
    }
  }
}

/// `[ ] ` and `[x] ` at the start of a list item make it a task, and
/// `toggleTask` checks and unchecks it.
public struct MarkdownTaskLists: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerShared(in: &registry)
    registry.addTransform("markdown.taskPrefix") { state, range in
      MarkdownSupport.convertPrefix(&state, in: range) { text in
        if text.hasPrefix("[ ] ") { return false }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return true }
        return nil
      } length: { _ in
        4
      } apply: { document, location, checked in
        guard let item = Structure.item(of: location), item.block == 0,
          case .list(_, let items) = document.block(at: item.list),
          items[item.item].checked == nil
        else { return nil }
        return Structure.setChecked(checked, document, at: location)
      }
    }
    registry.register(Command<Void>.toggleTask) { _, controller in
      MarkdownSupport.toggleTask(controller, at: controller.selection.head, onlyTasks: false)
        ? .handled : .unhandled
    }
    registry.register(Command<Position>.toggleTask) { position, controller in
      MarkdownSupport.toggleTask(controller, at: position, onlyTasks: true)
        ? .handled : .unhandled
    }
  }
}

/// `> ` at the start of a paragraph makes a quote; ↩ in an empty paragraph
/// of a quote leaves it, and ⌫ at the start of a quote's first paragraph
/// moves it out.
public struct MarkdownQuotes: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerShared(in: &registry)
    registry.addTransform("markdown.quotePrefix") { state, range in
      MarkdownSupport.convertPrefix(&state, in: range) { text in
        text.hasPrefix("> ") ? () : nil
      } length: { _ in
        2
      } apply: { document, location, _ in
        Structure.wrapInQuote(document, at: location)
      }
    }
    registry.addSlashCommand(
      SlashCommand("quote", summary: "Quote") { _, controller in
        MarkdownSupport.restructureCaretBlock(controller) { Structure.wrapInQuote($0, at: $1) }
        return .perform
      })
    MarkdownSupport.addBlockKey(.return, "markdown.quote.return", in: &registry) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state),
        location.range.isEmpty, Structure.quote(of: location) != nil,
        case .paragraph = state.document.block(at: location.path)
      else { return nil }
      return Structure.liftOutOfQuote(state.document, at: location).map { ($0, caret) }
    }
    MarkdownSupport.addBlockKey(.delete, "markdown.quote.delete", in: &registry) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state),
        caret == location.range.lowerBound.offset,
        let quote = Structure.quote(of: location), quote.child == 0
      else { return nil }
      return Structure.liftOutOfQuote(state.document, at: location).map { ($0, caret) }
    }
  }
}

/// A paragraph of just ```` ``` ```` (with an optional language) becomes a
/// code block on ↩. In a code block, ↩ inserts a line break, ↩ on an empty
/// last line leaves the block, and ⌫ at its start turns it back into a
/// paragraph. A `CodeHighlighter` can color the code; v1 ships none.
public struct MarkdownCodeBlocks: ComposerPlugin {
  public var highlighter: (any CodeHighlighter)?

  public init(highlighter: (any CodeHighlighter)? = nil) {
    self.highlighter = highlighter
  }

  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerShared(in: &registry)
    if let highlighter { registry.codeHighlighter = highlighter }
    registry.addSlashCommand(
      SlashCommand("code", summary: "Code block") { _, controller in
        MarkdownSupport.restructureCaretBlock(controller) { document, location in
          guard case .paragraph(let inlines) = document.block(at: location.path) else {
            return nil
          }
          let text = inlines.map { inline -> String in
            if case .text(let text, _) = inline { return text }
            return ""
          }.joined()
          return Structure.replace(
            document, at: location, with: [.codeBlock(language: nil, text: text)])
        }
        return .perform
      })
    MarkdownSupport.addBlockKey(
      .return, "markdown.code.return", revertible: true, in: &registry
    ) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state) else { return nil }
      switch state.document.block(at: location.path) {
      case .paragraph(let inlines):
        guard caret == location.range.upperBound.offset, inlines.count == 1,
          case .text(let text, let marks) = inlines[0], !marks.code, text.hasPrefix("```")
        else { return nil }
        let info = text.dropFirst(3)
        guard
          info.allSatisfy({
            $0.isLetter || $0.isNumber || "+-#._".contains($0)
          })
        else { return nil }
        let block = Block.codeBlock(language: info.isEmpty ? nil : String(info), text: "")
        return (
          Structure.replace(state.document, at: location, with: [block]),
          location.range.lowerBound.offset
        )
      case .codeBlock(let language, let text):
        guard caret == location.range.upperBound.offset else { return nil }
        if text.isEmpty {
          return (
            Structure.replace(state.document, at: location, with: [.paragraph([])]), caret
          )
        }
        guard text.hasSuffix("\n") else { return nil }
        let kept = String(text.dropLast())
        return (
          Structure.replace(
            state.document, at: location,
            with: [.codeBlock(language: language, text: kept), .paragraph([])]),
          caret
        )
      default:
        return nil
      }
    }
    MarkdownSupport.addBlockKey(.delete, "markdown.code.delete", in: &registry) { state in
      guard let (location, caret) = MarkdownSupport.caretBlock(state),
        caret == location.range.lowerBound.offset,
        case .codeBlock(_, let text) = state.document.block(at: location.path)
      else { return nil }
      let paragraph = Block.paragraph(text.isEmpty ? [] : [.text(text, marks: Marks())])
      return (Structure.replace(state.document, at: location, with: [paragraph]), caret)
    }
  }
}

/// Colors the code in code blocks. v1 ships none; the hook is for apps.
public protocol CodeHighlighter: Sendable {
  func highlight(_ code: String, language: String?) -> [HighlightRun]
}

/// A highlighted span of a code block, in UTF-16 offsets into its text.
public struct HighlightRun: Sendable, Hashable {
  public enum Kind: Sendable, Hashable {
    case keyword, string, comment, number, type, function, other(String)
  }

  public var range: Range<Int>
  public var kind: Kind

  public init(range: Range<Int>, kind: Kind) {
    self.range = range
    self.kind = kind
  }
}

// MARK: Presets

extension PluginGroup {
  /// Every markdown rule, task lists included.
  public static var markdown: PluginGroup {
    PluginGroup([
      MarkdownBold(), MarkdownItalic(), MarkdownStrikethrough(), MarkdownInlineCode(),
      MarkdownLinks(), MarkdownCodeBlocks(), MarkdownQuotes(), MarkdownLists(),
      MarkdownTaskLists(),
    ])
  }
}

extension ComposerPlugin where Self == PluginGroup {
  /// Every markdown rule, task lists included.
  public static var markdown: PluginGroup { PluginGroup.markdown }
}

extension Command where Payload == Position {
  /// Checks or unchecks the task item whose first line holds the position,
  /// as a click on its box does.
  public static var toggleTask: Command { Command("toggleTask") }
}

// MARK: Machinery

/// A conversion's undo by ⌫: the state before it, valid while the state
/// after it is unchanged.
struct MarkdownRevert: Sendable, Equatable {
  var before: Document
  var caretBefore: Int
  var after: Document
  var caretAfter: Int
}

/// A kind of span the inline rule converts.
enum InlineSyntax: Sendable, Hashable {
  case mark(MarkKind)
  case link
}

/// The run of typing the inline rule renders from (see
/// `MarkdownSupport.convertInline`).
struct InlineSession: Sendable, Equatable {
  /// The document with the run's paragraph as typed, syntax and all.
  var source: Document
  var sourceCaret: Int
  /// Where the run began, in `source`.
  var start: Int
  /// The ranges of `source` the rendering removed as syntax.
  var removed: [Range<Int>]
  /// The rendering, and its caret.
  var rendered: Document
  var caret: Int
}

enum MarkdownSupport {
  static let revertKey = PluginKey<MarkdownRevert?>("markdown.revert", default: nil)
  static let revert = Command<Void>("markdown.revert")
  private static let expire = "markdown.revert.expire"

  /// The revert machinery, once however many markdown plugins install it:
  /// a transform that forgets a conversion once the document moves on
  /// (first, so it runs before the rules in each pass), and ⌫.
  static func registerShared(in registry: inout PluginRegistry) {
    guard !registry.transforms.contains(where: { $0.name == expire }) else { return }
    registry.addTransientState(revertKey)
    registry.addTransform(expire) { state, _ in
      if let revert = state[revertKey], state.document != revert.after { state[revertKey] = nil }
    }
    registry.addKeyBinding(
      KeyBinding(.delete, command: revert, priority: .high) { state in canRevert(state) })
    registry.register(revert) { _, controller in
      guard canRevert(controller.state), let revert = controller.state[revertKey] else {
        return .unhandled
      }
      controller.update(undo: .register, runsTransforms: false) { state in
        state.document = revert.before
        state.selection = .caret(revert.caretBefore)
        state.storedMarks = nil
        state[revertKey] = nil
      }
      return .handled
    }
  }

  private static func canRevert(_ state: EditorState) -> Bool {
    guard let revert = state[revertKey], state.markedText == nil,
      state.selection == .caret(revert.caretAfter)
    else { return false }
    return state.document == revert.after
  }

  /// Records a conversion that `before` and `caretBefore` undo.
  static func recordConversion(_ state: inout EditorState, before: Document, caretBefore: Int) {
    state[revertKey] = MarkdownRevert(
      before: before, caretBefore: caretBefore, after: state.document,
      caretAfter: state.selection.head.offset)
  }

  /// Whether the update typed a character and its latest edit inserted text
  /// ending at `caret`: a rule converts what was just typed, not a paste,
  /// and not what an edit elsewhere (a deletion, or another rule) leaves
  /// before the caret.
  static func justTyped(_ state: EditorState, at caret: Int) -> Bool {
    guard let tracking = state.tracking, tracking.isTyping, let edit = tracking.edits.last else {
      return false
    }
    return edit.replacementLength > 0
      && edit.range.lowerBound.offset + edit.replacementLength == caret
  }

  /// Restructures the text block at the caret, keeping the caret's offset.
  @MainActor static func restructureCaretBlock(
    _ controller: ComposerController, _ body: (Document, BlockLocation) -> Document?
  ) {
    guard let location = controller.document.location(of: controller.selection.head),
      let document = body(controller.document, location)
    else { return }
    let caret = controller.selection.head.offset
    controller.update { state in
      state.document = document
      state.selection = .caret(min(caret, document.length))
    }
  }

  /// The text block holding a collapsed selection, and the caret.
  static func caretBlock(_ state: EditorState) -> (BlockLocation, Int)? {
    guard state.selection.isCollapsed, state.markedText == nil,
      let location = state.document.location(of: state.selection.head)
    else { return nil }
    return (location, state.selection.head.offset)
  }

  /// A key binding and command for a block rule: `plan` returns the new
  /// document and caret, or `nil` when the rule doesn't apply, so the key
  /// falls through to the next binding or the default action.
  static func addBlockKey(
    _ key: Key, modifiers: KeyModifiers = [], _ name: String, title: KeyBindingTitle? = nil,
    revertible: Bool = false, in registry: inout PluginRegistry,
    plan: @escaping @Sendable (EditorState) -> (Document, Int)?
  ) {
    let command = Command<Void>(name)
    registry.addKeyBinding(
      KeyBinding(key, modifiers: modifiers, command: command, discoverabilityTitle: title) {
        plan($0) != nil
      })
    registry.register(command) { _, controller in
      guard let (document, caret) = plan(controller.state) else { return .unhandled }
      controller.update { state in
        let before = state.document
        let caretBefore = state.selection.head.offset
        state.document = document
        state.selection = .caret(caret)
        if revertible { recordConversion(&state, before: before, caretBefore: caretBefore) }
      }
      return .handled
    }
  }

  // MARK: Inline

  static let inlineName = "markdown.inline"
  static let sessionKey = PluginKey<InlineSession?>("markdown.inline.session", default: nil)

  /// Registers a mark's toggle command and key, and its syntax with the
  /// inline rule.
  static func registerMark(
    _ mark: MarkKind, command: Command<Void>, key: Key, modifiers: KeyModifiers,
    title: KeyBindingTitle, in registry: inout PluginRegistry
  ) {
    registerInline(.mark(mark), in: &registry)
    registry.register(command, priority: .editor) { _, controller in
      controller.update { $0.toggleMark(mark, in: $0.selection.range) }
      return .handled
    }
    registry.addKeyBinding(
      KeyBinding(key, modifiers: modifiers, command: command, discoverabilityTitle: title))
  }

  /// Adds a kind of span to the one inline rule, which converts the kinds
  /// registered so far.
  static func registerInline(_ syntax: InlineSyntax, in registry: inout PluginRegistry) {
    registerShared(in: &registry)
    registry.addTransientState(sessionKey)
    registry.markdownInline.insert(syntax)
    let enabled = registry.markdownInline
    let transform = NodeTransform(inlineName) { state, range in
      convertInline(&state, in: range, enabled)
    }
    if let index = registry.transforms.firstIndex(where: { $0.name == inlineName }) {
      registry.transforms[index] = transform
    } else {
      registry.transforms.append(transform)
    }
  }

  static func isWhitespace(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit)?.properties.isWhitespace ?? false
  }

  /// The inline rule. Typing at the caret, without moving it, is a run: the
  /// session keeps the run's paragraph as typed, delimiters and all, and
  /// every keystroke renders the paragraph from it with the markdown
  /// parser, converting the spans whose closing syntax the run typed. So a
  /// conversion is always what the parser makes of the characters typed,
  /// even when a later character changes it (`__a__` is bold, `__a__b` is
  /// not). ⌫ at the end of the run takes the character out of the run, and
  /// any other edit, or moving the caret, ends it.
  static func convertInline(
    _ state: inout EditorState, in range: DocumentRange, _ enabled: Set<InlineSyntax>
  ) {
    guard state.markedText == nil, state.selection.isCollapsed, let tracking = state.tracking,
      let edit = tracking.edits.last
    else { return }
    let caret = state.selection.head.offset
    guard range.lowerBound.offset <= caret, caret <= range.upperBound.offset else { return }
    let session = state[sessionKey]
    // Already rendered in an earlier pass of this update.
    if let session, session.caret == caret, session.rendered == state.document { return }
    var source: Document
    var sourceCaret: Int
    var start: Int
    let length = edit.replacementLength
    if tracking.isTyping, length > 0, edit.range.lowerBound.offset + length == caret {
      let typedStart = caret - length
      if let session, edit.range.isEmpty, session.caret == typedStart,
        removing(typedStart..<caret, from: state.document) == session.rendered,
        let typed = inlines(in: typedStart..<caret, of: state.document)
      {
        // The typed text takes the source's marks where it took those of
        // the rendering, so a converted mark doesn't carry on in the source.
        let rendered = session.rendered.marks(at: Position(typedStart))
        let original = session.source.marks(at: Position(session.sourceCaret))
        let typed = typed.map { inline -> Inline in
          guard case .text(let text, var marks) = inline else { return inline }
          for kind in [MarkKind.bold, .italic, .strikethrough, .code]
          where marks[kind] == rendered[kind] {
            marks[kind] = original[kind]
          }
          if marks.link == rendered.link { marks.link = original.link }
          return .text(text, marks: marks)
        }
        source = session.source
        _ = source.replace(session.sourceCaret..<session.sourceCaret, with: typed)
        sourceCaret = session.sourceCaret + length
        start = session.start
      } else {
        source = state.document
        sourceCaret = caret
        start = typedStart
      }
    } else if !tracking.isTyping, length == 0, let session,
      edit.range.upperBound.offset == session.caret, edit.range.lowerBound.offset == caret
    {
      // ⌫ at the end of the run, over characters the rendering kept.
      let from = session.sourceCaret - (session.caret - caret)
      guard from >= session.start,
        !session.removed.contains(where: {
          $0.lowerBound < session.sourceCaret && $0.upperBound > from
        }),
        removing(caret..<session.caret, from: session.rendered) == state.document
      else {
        state[sessionKey] = nil
        return
      }
      source = session.source
      _ = source.replace(from..<session.sourceCaret, with: [])
      sourceCaret = from
      start = session.start
    } else {
      state[sessionKey] = nil
      return
    }
    let rendering = renderInline(source, caret: sourceCaret, start: start, enabled)
    if rendering.document != state.document {
      state.document = rendering.document
      state.selection = .caret(rendering.caret)
    }
    if rendering.closesAtCaret {
      // The spans end at the caret: the next character takes the marks it
      // would have in the source.
      let next = source.marks(at: Position(sourceCaret))
      if next != state.document.marks(at: Position(rendering.caret)) { state.storedMarks = next }
      // ⌫ restores the characters as typed.
      recordConversion(&state, before: source, caretBefore: sourceCaret)
    }
    state[sessionKey] = InlineSession(
      source: source, sourceCaret: sourceCaret, start: start, removed: rendering.removed,
      rendered: state.document, caret: state.selection.head.offset)
  }

  /// The content of `range`, inside one paragraph.
  private static func inlines(in range: Range<Int>, of document: Document) -> [Inline]? {
    guard let location = document.location(of: Position(range.lowerBound)),
      case .paragraph(let inlines) = document.block(at: location.path)
    else { return nil }
    let base = location.range.lowerBound.offset
    let rest = Document.split(inlines, at: range.lowerBound - base).1
    return Document.split(rest, at: range.count).0
  }

  private static func removing(_ range: Range<Int>, from document: Document) -> Document {
    var document = document
    _ = document.replace(range, with: [])
    return document
  }

  /// Renders the paragraph at `caret` in `source`: the spans the parser
  /// finds whose closing syntax overlaps `start..<caret`, and the spans
  /// inside them, take their marks, and their syntax is removed.
  static func renderInline(
    _ source: Document, caret: Int, start: Int, _ enabled: Set<InlineSyntax>
  ) -> (document: Document, caret: Int, removed: [Range<Int>], closesAtCaret: Bool) {
    let unchanged = (source, caret, [Range<Int>](), false)
    guard let location = source.location(of: Position(caret)),
      case .paragraph(let inlines) = source.block(at: location.path)
    else { return unchanged }
    let base = location.range.lowerBound.offset
    // The paragraph's units, each with its marks; a node is one unit.
    var units: [UInt16] = []
    var marks: [Marks] = []
    var nodes: [Int: Inline] = [:]
    var hasSyntax = false
    for inline in inlines {
      switch inline {
      case .text(let text, let runMarks):
        for unit in text.utf16 {
          if !runMarks.code, unit < 0x80, syntaxUnits.contains(unit) { hasSyntax = true }
          units.append(unit)
          marks.append(runMarks)
        }
      case .node, .unknown:
        nodes[units.count] = inline
        units.append(0xFFFC)
        marks.append(Marks())
      }
    }
    guard hasSyntax else { return unchanged }
    // The parser's source: code and nodes are opaque symbols to it.
    var scalars: [Unicode.Scalar] = []
    var unitOf: [Int] = []
    var index = 0
    while index < units.count {
      unitOf.append(index)
      let unit = units[index]
      if marks[index].code || nodes[index] != nil {
        scalars.append("\u{FFFC}")
        index += 1
      } else if UTF16.isLeadSurrogate(unit), index + 1 < units.count,
        UTF16.isTrailSurrogate(units[index + 1])
      {
        let value = 0x10000 + (UInt32(unit) - 0xD800) << 10 + (UInt32(units[index + 1]) - 0xDC00)
        scalars.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        index += 2
      } else {
        scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
        index += 1
      }
    }
    unitOf.append(units.count)
    func unitRange(_ range: Range<Int>) -> Range<Int> {
      unitOf[range.lowerBound]..<unitOf[range.upperBound]
    }
    var parser = InlineParser(schema: Schema(), source: scalars)
    _ = parser.parse()
    let typed = max(start - base, 0)..<(caret - base)
    let conversions = parser.conversions.compactMap { conversion -> InlineConversion? in
      let syntax: InlineSyntax
      switch conversion.kind {
      case .mark(let mark): syntax = .mark(mark)
      case .link: syntax = .link
      }
      guard enabled.contains(syntax) else { return nil }
      var conversion = conversion
      conversion.open = unitRange(conversion.open)
      conversion.close = unitRange(conversion.close)
      // Inline code never spans a line break.
      if case .mark(.code) = conversion.kind, units[conversion.content].contains(0x0A) {
        return nil
      }
      return conversion
    }
    let closing = conversions.filter {
      $0.close.lowerBound < typed.upperBound && $0.close.upperBound > typed.lowerBound
    }
    guard !closing.isEmpty else { return unchanged }
    let applied = conversions.filter { conversion in
      closing.contains {
        $0.open.lowerBound <= conversion.open.lowerBound
          && conversion.close.upperBound <= $0.close.upperBound
      }
    }
    var removed = [Bool](repeating: false, count: units.count)
    for conversion in applied {
      for index in conversion.open { removed[index] = true }
      for index in conversion.close { removed[index] = true }
      for index in conversion.content where nodes[index] == nil {
        switch conversion.kind {
        case .mark(let mark): marks[index][mark] = true
        case .link(let url): marks[index].link = url
        }
      }
    }
    var content: [Inline] = []
    var run: [UInt16] = []
    var runMarks = Marks()
    func flush() {
      guard !run.isEmpty else { return }
      Normalizer.append(.text(String(decoding: run, as: UTF16.self), marks: runMarks), to: &content)
      run.removeAll()
    }
    for index in units.indices where !removed[index] {
      if let node = nodes[index] {
        flush()
        content.append(node)
      } else {
        if marks[index] != runMarks { flush() }
        runMarks = marks[index]
        run.append(units[index])
      }
    }
    flush()
    var document = source
    _ = document.replace(base..<base + units.count, with: content)
    var removedRanges: [Range<Int>] = []
    var removedBeforeCaret = 0
    for index in units.indices where removed[index] {
      if index < caret - base { removedBeforeCaret += 1 }
      if let last = removedRanges.last, last.upperBound == base + index {
        removedRanges[removedRanges.count - 1] = last.lowerBound..<base + index + 1
      } else {
        removedRanges.append(base + index..<base + index + 1)
      }
    }
    let closesAtCaret = applied.contains { $0.close.upperBound == caret - base }
    return (document, caret - removedBeforeCaret, removedRanges, closesAtCaret)
  }

  /// The ASCII characters that can start or end inline syntax.
  private static let syntaxUnits = Set("*_~`[]()<>".utf16)

  /// Converts a prefix just typed at the start of a paragraph: `match`
  /// reads it from the paragraph's text, and `apply` restructures the
  /// document once it is deleted.
  static func convertPrefix<Value>(
    _ state: inout EditorState, in range: DocumentRange, match: (String) -> (Value, Int)?,
    apply: (Document, BlockLocation, Value) -> Document?
  ) {
    guard let (location, caret) = caretBlock(state),
      location.range.lowerBound == range.lowerBound, justTyped(state, at: caret),
      case .paragraph(let inlines) = state.document.block(at: location.path),
      case .text(let text, let marks)? = inlines.first, !marks.code,
      let (value, length) = match(text),
      caret == location.range.lowerBound.offset + length
    else { return }
    let prefix = location.range.lowerBound..<Position(caret)
    var trial = state
    trial.delete(prefix)
    guard let location = trial.document.location(of: prefix.lowerBound),
      let document = apply(trial.document, location, value)
    else { return }
    let before = state.document
    state.delete(prefix)
    state.document = document
    state.selection = .caret(prefix.lowerBound.offset)
    recordConversion(&state, before: before, caretBefore: caret)
  }

  static func convertPrefix<Value>(
    _ state: inout EditorState, in range: DocumentRange, match: (String) -> Value?,
    length: (Value) -> Int, apply: (Document, BlockLocation, Value) -> Document?
  ) {
    convertPrefix(
      &state, in: range, match: { text in match(text).map { ($0, length($0)) } }, apply: apply)
  }

  /// Toggles the task item whose first block holds `position`. Unless
  /// `onlyTasks`, a plain list item becomes an unchecked task.
  @MainActor static func toggleTask(
    _ controller: ComposerController, at position: Position, onlyTasks: Bool
  ) -> Bool {
    guard let location = controller.document.location(of: position) else { return false }
    // The innermost item, from any of its blocks.
    guard
      let (list, item) = location.containers.reversed().lazy.compactMap({
        container -> ([Int], Int)? in
        if case .item(let list, let item) = container { return (list, item) }
        return nil
      }).first,
      case .list(let kind, var items) = controller.document.block(at: list)
    else { return false }
    if onlyTasks, items[item].checked == nil { return false }
    if onlyTasks, Structure.item(of: location)?.block != 0 { return false }
    items[item].checked = !(items[item].checked ?? true)
    var document = controller.document
    document.modifyBlock(at: list) { $0 = .list(kind, items: items) }
    controller.update { $0.document = document }
    return true
  }
}
