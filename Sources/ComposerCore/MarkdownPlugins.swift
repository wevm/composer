import Foundation

// The markdown plugins: input rules that convert markdown as it is typed,
// each rule its own plugin. Inline rules convert on the closing delimiter
// and end the mark there (see `EditorState.storedMarks`); block rules convert
// a prefix typed at the start of a paragraph, and handle ↩, ⇥, and ⌫ inside
// lists, quotes, and code blocks. ⌫ right after any conversion reverts it to
// the characters typed.

// MARK: Inline marks

/// `**bold**` and `__bold__`, and ⌘B.
public struct MarkdownBold: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .bold, delimiters: ["**", "__"], command: .toggleBold, key: "b", modifiers: .command,
      title: "Bold", in: &registry)
  }
}

/// `_italic_` and `*italic*`, and ⌘I.
public struct MarkdownItalic: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .italic, delimiters: ["_", "*"], command: .toggleItalic, key: "i", modifiers: .command,
      title: "Italic", in: &registry)
  }
}

/// `~~strikethrough~~`, and ⌘⇧X.
public struct MarkdownStrikethrough: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .strikethrough, delimiters: ["~~"], command: .toggleStrikethrough, key: "x",
      modifiers: [.command, .shift], title: "Strikethrough", in: &registry)
  }
}

/// `` `code` ``, and ⌘E.
public struct MarkdownInlineCode: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerMark(
      .code, delimiters: ["`"], command: .toggleCode, key: "e", modifiers: .command,
      title: "Code", in: &registry)
  }
}

/// `[text](url)` becomes a link when the `)` is typed.
public struct MarkdownLinks: ComposerPlugin {
  public init() {}
  public func register(in registry: inout PluginRegistry) {
    MarkdownSupport.registerShared(in: &registry)
    registry.addTransform("markdown.link") { state, range in
      MarkdownSupport.convertLink(&state, in: range)
    }
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

  /// Whether the update's latest edit inserted text ending at `caret`: a
  /// rule converts what was just typed, not what an edit elsewhere (a
  /// deletion, or another rule) leaves before the caret.
  static func justTyped(_ state: EditorState, at caret: Int) -> Bool {
    guard let edit = state.tracking?.edits.last else { return false }
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

  // MARK: Marks

  static func registerMark(
    _ mark: MarkKind, delimiters: [String], command: Command<Void>, key: Key,
    modifiers: KeyModifiers, title: KeyBindingTitle, in registry: inout PluginRegistry
  ) {
    registerShared(in: &registry)
    let delimiters = delimiters.map { Array($0.utf16) }
    registry.addTransform("markdown.\(mark)") { state, range in
      for delimiter in delimiters where convertMark(&state, in: range, mark, delimiter) {
        return
      }
    }
    registry.register(command, priority: .editor) { _, controller in
      controller.update { $0.toggleMark(mark, in: $0.selection.range) }
      return .handled
    }
    registry.addKeyBinding(
      KeyBinding(key, modifiers: modifiers, command: command, discoverabilityTitle: title))
  }

  /// A paragraph's text as UTF-16 units, nodes as U+FFFC, with whether each
  /// unit is inline code.
  private static func units(of inlines: [Inline]) -> (units: [UInt16], code: [Bool]) {
    var units: [UInt16] = []
    var code: [Bool] = []
    for inline in inlines {
      switch inline {
      case .text(let text, let marks):
        let start = units.count
        units.append(contentsOf: text.utf16)
        code.append(contentsOf: repeatElement(marks.code, count: units.count - start))
      case .node, .unknown:
        units.append(0xFFFC)
        code.append(false)
      }
    }
    return (units, code)
  }

  static func isWhitespace(_ unit: UInt16) -> Bool {
    Unicode.Scalar(unit)?.properties.isWhitespace ?? false
  }

  /// Whether a unit can come before an opening delimiter: whitespace,
  /// punctuation, a symbol, or a node.
  static func isBoundary(_ unit: UInt16) -> Bool {
    if unit == 0xFFFC { return true }
    guard let scalar = Unicode.Scalar(unit) else { return false }
    if scalar.properties.isWhitespace { return true }
    switch scalar.properties.generalCategory {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol,
      .modifierSymbol, .otherSymbol:
      return true
    default:
      return false
    }
  }

  /// Converts `<d>text<d>` when its closing delimiter `d` was just typed at
  /// the caret. The opening delimiter is the nearest one before it on the
  /// same line that starts a word, with text inside that doesn't start or
  /// end with whitespace. A single-character delimiter next to another of
  /// the same character is part of a longer one, so `**bold*` waits for its
  /// second `*`.
  static func convertMark(
    _ state: inout EditorState, in range: DocumentRange, _ mark: MarkKind, _ d: [UInt16]
  ) -> Bool {
    guard let (location, caret) = caretBlock(state),
      range.lowerBound.offset <= caret, caret <= range.upperBound.offset,
      justTyped(state, at: caret),
      case .paragraph(let inlines) = state.document.block(at: location.path)
    else { return false }
    let start = location.range.lowerBound.offset
    let (units, code) = units(of: inlines)
    let end = caret - start
    let close = end - d.count
    guard close >= 1, units[close..<end].elementsEqual(d),
      !code[close..<end].contains(true)
    else { return false }
    let single = d.count == 1
    if single, units[close - 1] == d[0] { return false }
    var open = close - d.count - 1
    var found: Int?
    while open >= 0 {
      defer { open -= 1 }
      if units[open + d.count - 1] == 0x0A { break }
      guard units[open..<open + d.count].elementsEqual(d),
        !code[open..<open + d.count].contains(true)
      else { continue }
      let content = units[(open + d.count)..<close]
      guard let first = content.first, let last = content.last else { break }
      if isWhitespace(first) || isWhitespace(last) { break }
      if single, first == d[0] { continue }
      if open > 0, units[open - 1] == d[0] { continue }
      if open > 0, !isBoundary(units[open - 1]) { continue }
      found = open
      break
    }
    guard let open = found else { return false }
    let before = state.document
    state.delete(Position(start + close)..<Position(start + end))
    state.setMark(mark, true, in: Position(start + open + d.count)..<Position(start + close))
    if mark == .code {
      // Nothing nests inside inline code.
      for other in [MarkKind.bold, .italic, .strikethrough] {
        state.setMark(other, false, in: Position(start + open + d.count)..<Position(start + close))
      }
    }
    state.delete(Position(start + open)..<Position(start + open + d.count))
    var after = state.document.marks(at: state.selection.head)
    after[mark] = false
    state.storedMarks = after
    recordConversion(&state, before: before, caretBefore: caret)
    return true
  }

  /// Converts `[text](url)` when its `)` was just typed at the caret.
  static func convertLink(_ state: inout EditorState, in range: DocumentRange) {
    guard let (location, caret) = caretBlock(state),
      range.lowerBound.offset <= caret, caret <= range.upperBound.offset,
      justTyped(state, at: caret),
      case .paragraph(let inlines) = state.document.block(at: location.path)
    else { return }
    let start = location.range.lowerBound.offset
    let (units, code) = units(of: inlines)
    let end = caret - start
    guard end >= 5, units[end - 1] == 0x29, !code[end - 1] else { return }  // ")"
    // The URL: back to "](", without whitespace.
    var index = end - 2
    while index >= 1, !(units[index - 1] == 0x5D && units[index] == 0x28) {  // "]("
      if isWhitespace(units[index]) || units[index] == 0xFFFC { return }
      index -= 1
    }
    guard index >= 1 else { return }
    let urlRange = (index + 1)..<(end - 1)
    guard !urlRange.isEmpty else { return }
    let url = String(decoding: units[urlRange], as: UTF16.self)
    // The text: back to "[", on the same line.
    let textEnd = index - 1
    var open = textEnd - 1
    while open >= 0, units[open] != 0x5B {  // "["
      if units[open] == 0x0A || units[open] == 0x5D { return }
      open -= 1
    }
    guard open >= 0, open + 1 < textEnd, !code[open...end - 1].contains(true) else { return }
    let before = state.document
    state.delete(Position(start + textEnd)..<Position(start + end))
    state.setLink(url, in: Position(start + open + 1)..<Position(start + textEnd))
    state.delete(Position(start + open)..<Position(start + open + 1))
    recordConversion(&state, before: before, caretBefore: caret)
  }

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
