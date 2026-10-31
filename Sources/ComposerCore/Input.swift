import Foundation

// Text input, as engines report it. Engines route their text view's input
// here instead of editing their text storage, so every platform edits the
// document the same way, and Core tests drive the same paths without a text
// view.

/// Where pasted content comes from.
public enum PasteSource: Sendable, Hashable {
  case plainText(String)
  /// HTML from the pasteboard, mapped by `RichPaste`.
  case html(String)
  /// A document already in the schema: composer's own clipboard type, or
  /// rich text (RTF) an engine mapped.
  case document(Document)
  /// Files or images, which go to the attachments tray when
  /// `AttachmentsPlugin` is enabled and are dropped otherwise.
  case files([PastedFile])
}

/// A pasted or dropped file.
public struct PastedFile: Sendable, Hashable {
  public var data: Data
  /// The uniform type identifier, such as `public.png`.
  public var contentType: String
  public var name: String?

  public init(data: Data, contentType: String, name: String? = nil) {
    self.data = data
    self.contentType = contentType
    self.name = name
  }
}

extension ComposerController {
  /// Inserts text, as typed or committed by an input method, over `range`,
  /// or else over the marked text, or else over the selection. It ends any
  /// composition.
  public func insertText(_ text: String, replacing range: DocumentRange? = nil) {
    let isTyping =
      range == nil && state.markedText == nil && state.selection.isCollapsed && text.count == 1
      && text != "\n"
    update(undo: isTyping ? .typing : .register) { state in
      let target = range ?? state.markedText?.range ?? state.selection.range
      state.markedText = nil
      state.tracking?.isTyping = text.count == 1 && text != "\n"
      if !target.isEmpty, target.offsets == 0..<state.document.length {
        let marks = state.typingMarks(at: target.lowerBound)
        state.deleteSelection(target)
        state.insert(text, at: .caret(0), marks: marks)
      } else {
        state.insert(text, at: Selection(target))
      }
    }
  }

  /// Sets the IME composition: `text` replaces `range`, or else the current
  /// marked text, or else the selection, and becomes the marked text, with
  /// the selection at `selectedRange` within it. Empty text ends the
  /// composition. Transforms wait until it ends.
  public func setMarkedText(
    _ text: String, selectedRange: Range<Int>, replacing range: DocumentRange? = nil
  ) {
    update { state in
      let target = range ?? state.markedText?.range ?? state.selection.range
      let lower = target.lowerBound.offset
      state.replace(
        target,
        with: text.isEmpty ? [] : [.text(text, marks: state.typingMarks(at: target.lowerBound))])
      let length = text.utf16.count
      if length == 0 {
        state.markedText = nil
        state.selection = .caret(lower)
        return
      }
      let selected =
        min(
          max(selectedRange.lowerBound, 0), length)..<min(
          max(selectedRange.upperBound, selectedRange.lowerBound, 0), length)
      state.markedText = MarkedText(
        range: Position(lower)..<Position(lower + length), selectedRange: selected)
      state.selection = Selection(
        anchor: Position(lower + selected.lowerBound), head: Position(lower + selected.upperBound))
    }
  }

  /// Commits the marked text as it is.
  public func unmarkText() {
    guard state.markedText != nil else { return }
    update { $0.markedText = nil }
  }

  /// Deletes the selection, or else the character or node before the caret.
  /// At the start of a text block, it joins the block to the previous one.
  public func deleteBackward() {
    update { state in
      state.markedText = nil
      let range = state.selection.range
      if !range.isEmpty {
        state.deleteSelection(range)
        return
      }
      let offset = range.lowerBound.offset
      guard offset > 0 else { return }
      state.delete(Position(state.document.boundary(before: offset))..<range.lowerBound)
    }
  }

  /// Deletes the selection, or else the character or node after the caret.
  /// At the end of a text block, it joins the next block to it.
  public func deleteForward() {
    update { state in
      state.markedText = nil
      let range = state.selection.range
      if !range.isEmpty {
        state.deleteSelection(range)
        return
      }
      let offset = range.lowerBound.offset
      guard offset < state.document.length else { return }
      state.delete(range.lowerBound..<Position(state.document.boundary(after: offset)))
    }
  }

  /// Replaces the selection with a new text block: splits the block at the
  /// caret (in a code block, inserts a line break).
  public func insertNewline() {
    update { state in
      state.markedText = nil
      let range = state.selection.range
      if !range.isEmpty { state.deleteSelection(range) }
      state.splitBlock(at: range.lowerBound)
      state.selection = .caret(range.lowerBound.offset + 1)
    }
  }

  /// Inserts a line break within the text block.
  public func insertLineBreak() {
    insertText("\n")
  }

  /// Handles a key press the way every engine does: the keymap first, then
  /// the default action for the key, if it has one. Returns whether the key
  /// was handled; if not, the engine's text system handles it (caret
  /// movement, for example).
  ///
  /// The default actions: ↩ inserts a new block, ⇧↩ a line break, ⌫ and ⌦
  /// delete, and ⇥ inserts a tab. A default action commits any marked text
  /// first, as its own undo group, the way text views commit a composition
  /// that the input method passes a key through.
  @discardableResult
  public func handleKeyPress(_ key: Key, modifiers: KeyModifiers = []) -> Bool {
    if handleKey(key, modifiers: modifiers) { return true }
    let action: (() -> Void)? =
      switch (key, modifiers) {
      case (.return, []): insertNewline
      case (.return, [.shift]): insertLineBreak
      case (.delete, []), (.delete, [.shift]): deleteBackward
      case (.forwardDelete, []): deleteForward
      case (.tab, []): { self.insertText("\t") }
      default: nil
      }
    guard let action else { return false }
    unmarkText()
    action()
    return true
  }
}

extension Document {
  /// `selection` with its ends on character boundaries: a caret inside a
  /// character moves to its start, and a range grows to whole characters.
  func characterAligned(_ selection: Selection) -> Selection {
    if selection.isCollapsed { return Selection(Position(characterStart(selection.head.offset))) }
    let forward = selection.anchor <= selection.head
    let range = selection.range
    let lower = Position(characterStart(range.lowerBound.offset))
    var upper = characterStart(range.upperBound.offset)
    if upper != range.upperBound.offset { upper = boundary(after: upper) }
    return forward
      ? Selection(anchor: lower, head: Position(upper))
      : Selection(anchor: Position(upper), head: lower)
  }

  /// The start of the character holding `offset`, or `offset` itself if it
  /// is a boundary.
  private func characterStart(_ offset: Int) -> Int {
    guard offset > 0 else { return offset }
    let before = boundary(before: offset)
    let after = boundary(after: before)
    return after <= offset ? offset : before
  }

  /// The position one character or node before `offset`: the start of the
  /// grapheme cluster before it within its text run, or the separator before
  /// a text block's start.
  public func boundary(before offset: Int) -> Int {
    guard let leaf = locate(offset) else { return max(offset - 1, 0) }
    let local = offset - leaf.start
    guard local > 0 else { return offset - 1 }
    let (text, start) = run(in: leaf, containing: local - 1)
    guard let text else { return offset - 1 }
    var position = 0
    var previous = 0
    for character in text {
      if start + position >= local { break }
      previous = position
      position += character.utf16.count
    }
    return leaf.start + start + previous
  }

  /// The position one character or node after `offset`.
  public func boundary(after offset: Int) -> Int {
    guard let leaf = locate(offset) else { return offset }
    let local = offset - leaf.start
    guard local < leaf.length else { return min(offset + 1, length) }
    let (text, start) = run(in: leaf, containing: local)
    guard let text else { return offset + 1 }
    var position = 0
    for character in text {
      position += character.utf16.count
      if start + position > local { break }
    }
    return leaf.start + start + position
  }

  /// The text of the run holding unit `local` of a text block, and where the
  /// run starts; `nil` text for a node.
  private func run(in leaf: LeafLocation, containing local: Int) -> (String?, Int) {
    switch block(at: leaf.path) {
    case .codeBlock(_, let text):
      return (text, 0)
    case .paragraph(let inlines):
      var start = 0
      for inline in inlines {
        let length = inline.length
        if local < start + length {
          if case .text(let text, _) = inline { return (text, start) }
          return (nil, start)
        }
        start += length
      }
      return (nil, start)
    default:
      return (nil, 0)
    }
  }
}
