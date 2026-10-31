import ComposerCore
import ComposerTesting
import Foundation
import Testing

@MainActor @Suite struct InputTests {
  func controller(
    _ blocks: Block..., caret: Int? = nil, plugins: [any ComposerPlugin] = []
  )
    -> ComposerController
  {
    let document = Document(blocks: blocks.isEmpty ? [.paragraph([])] : blocks)
    return ComposerController(
      EditorState(document: document, selection: caret.map(Selection.caret)), plugins: plugins)
  }

  @Test func deleteBackwardRemovesOneGraphemeOrNode() {
    let controller = self.controller(paragraph(text("a👍🏽"), mention("tom", id: "1"), text("é")))
    controller.deleteBackward()
    #expect(controller.document.blocks == [paragraph(text("a👍🏽"), mention("tom", id: "1"))])
    controller.deleteBackward()
    #expect(controller.document.blocks == [paragraph(text("a👍🏽"))])
    controller.deleteBackward()
    #expect(controller.document.blocks == [paragraph(text("a"))])
    #expect(controller.selection == .caret(1))
  }

  @Test func deleteAtABlockBoundaryJoinsBlocks() {
    let controller = self.controller(paragraph(text("ab")), paragraph(text("cd")), caret: 3)
    controller.deleteBackward()
    #expect(controller.document.blocks == [paragraph(text("abcd"))])
    #expect(controller.selection == .caret(2))
    controller.selection = .caret(0)
    controller.deleteBackward()
    #expect(controller.document.blocks == [paragraph(text("abcd"))])
    let forward = self.controller(paragraph(text("ab")), paragraph(text("😀d")), caret: 2)
    forward.deleteForward()
    #expect(forward.document.blocks == [paragraph(text("ab😀d"))])
    forward.deleteForward()
    #expect(forward.document.blocks == [paragraph(text("abd"))])
  }

  @Test func deleteRemovesASelection() {
    let controller = self.controller(paragraph(text("abc")))
    controller.selection = Selection(anchor: 3, head: 1)
    controller.deleteForward()
    #expect(controller.document.blocks == [paragraph(text("a"))])
    #expect(controller.selection == .caret(1))
  }

  /// Deleting or typing over everything leaves a plain paragraph, not the
  /// first block's list item, task, quote, or code block.
  @Test func replacingEverythingReplacesTheStructure() {
    for markdown in ["- [ ] one\n- two\n\nafter", "> q", "```\nx\n```"] {
      let controller = ComposerController(EditorState(document: MarkdownCodec().parse(markdown)))
      controller.selection = Selection(anchor: 0, head: Position(controller.document.length))
      controller.deleteBackward()
      #expect(controller.isEmpty, "\(markdown)")
      controller.insertText("x")
      controller.selection = Selection(anchor: 0, head: 1)
      controller.insertText("y")
      #expect(controller.document.blocks == [paragraph(text("y"))], "\(markdown)")
    }
    let partial = ComposerController(EditorState(document: MarkdownCodec().parse("- one\n- two")))
    partial.selection = Selection(anchor: 0, head: Position(partial.document.length - 1))
    partial.deleteBackward()
    #expect(partial.markdown == "- o", "a partial selection keeps the list")
  }

  @Test func newlineSplitsOrBreaksALine() {
    let controller = self.controller(paragraph(text("abcd")), caret: 2)
    controller.insertNewline()
    #expect(controller.document.blocks == [paragraph(text("ab")), paragraph(text("cd"))])
    #expect(controller.selection == .caret(3))
    controller.insertLineBreak()
    #expect(controller.document.blocks == [paragraph(text("ab")), paragraph(text("\ncd"))])
    let code = self.controller(.codeBlock(language: nil, text: "ab"), caret: 1)
    code.insertNewline()
    #expect(code.document.blocks == [.codeBlock(language: nil, text: "a\nb")])
    #expect(code.selection == .caret(2))
  }

  @Test func markedTextReplacesItselfUntilCommitted() {
    let controller = self.controller(paragraph(text("x")))
    controller.setMarkedText("k", selectedRange: 1..<1)
    controller.setMarkedText("か", selectedRange: 1..<1)
    #expect(controller.state.markedText == MarkedText(range: 1..<2, selectedRange: 1..<1))
    #expect(controller.selection == .caret(2))
    controller.setMarkedText("かな", selectedRange: 0..<2)
    #expect(controller.selection == Selection(anchor: 1, head: 3))
    controller.insertText("仮名")
    #expect(controller.document.blocks == [paragraph(text("x仮名"))])
    #expect(controller.state.markedText == nil)
    #expect(controller.selection == .caret(3))
    // An empty composition ends it.
    controller.setMarkedText("a", selectedRange: 1..<1)
    controller.setMarkedText("", selectedRange: 0..<0)
    #expect(controller.document.blocks == [paragraph(text("x仮名"))])
    #expect(controller.state.markedText == nil)
  }

  @Test func keysRunTheKeymapThenTheDefaultAction() {
    let log = Log()
    let controller = self.controller(paragraph(text("ab")), caret: 1)
    #expect(controller.handleKeyPress(.return))
    #expect(controller.document.blocks == [paragraph(text("a")), paragraph(text("b"))])
    controller.keymap.add(KeyBinding(.return, command: Command<Void>("send")))
    controller.register(Command<Void>("send")) { _, _ in
      log.append("send")
      return .handled
    }
    #expect(controller.handleKeyPress(.return))
    #expect(log.all == ["send"])
    #expect(controller.document.blocks == [paragraph(text("a")), paragraph(text("b"))])
    #expect(controller.handleKeyPress(.return, modifiers: .shift))
    #expect(controller.document.blocks == [paragraph(text("a")), paragraph(text("\nb"))])
    // Caret movement belongs to the engine's text system.
    #expect(!controller.handleKeyPress(.leftArrow))
  }

  @Test func pasteNormalizesLineEndings() {
    let controller = self.controller()
    controller.paste(.plainText("a\r\nb\rc"))
    #expect(controller.document.blocks == [paragraph(text("a\nb\nc"))])
  }

  @Test func everyUpdateReachesTheEngine() {
    final class Engine: TextEngine {
      var applied: [(Changeset, EditorState)] = []
      func apply(_ changeset: Changeset, from state: EditorState) {
        applied.append((changeset, state))
      }
      var selectionRects: [CGRect] { [] }
      func rect(for range: DocumentRange) -> CGRect { CGRect() }
    }
    let engine = Engine()
    let controller = self.controller()
    controller.engine = engine
    controller.insertText("a")
    controller.selection = .caret(0)
    controller.update { _ in }
    #expect(engine.applied.count == 2)
    #expect(engine.applied[0].0.edits == [.init(range: 0..<0, replacementLength: 1)])
    #expect(engine.applied[1].1 == controller.state)
  }
}

@MainActor @Suite struct UndoTests {
  func controller(plugins: [any ComposerPlugin] = []) -> (ComposerController, UndoStack) {
    let controller = ComposerController(plugins: plugins)
    let stack = UndoStack()
    controller.undoManager = stack
    return (controller, stack)
  }

  @Test func typingIsOneGroup() {
    let (controller, undo) = controller()
    for character in "hello" { controller.insertText(String(character)) }
    undo.undo()
    #expect(plainText(controller.document) == [""])
    #expect(!undo.canUndo)
    undo.redo()
    #expect(plainText(controller.document) == ["hello"])
    #expect(controller.selection == .caret(5))
  }

  @Test func otherEditsAndCaretMovesStartNewGroups() {
    let (controller, undo) = controller()
    controller.insertText("a")
    controller.insertText("b")
    controller.insertNewline()
    controller.insertText("c")
    controller.selection = .caret(0)
    controller.insertText("d")
    #expect(plainText(controller.document) == ["dab", "c"])
    undo.undo()
    #expect(plainText(controller.document) == ["ab", "c"])
    undo.undo()
    #expect(plainText(controller.document) == ["ab", ""])
    undo.undo()
    #expect(plainText(controller.document) == ["ab"])
    undo.undo()
    #expect(plainText(controller.document) == [""])
    undo.redo()
    undo.redo()
    #expect(plainText(controller.document) == ["ab", ""])
  }

  @Test func aCompositionIsOneGroup() {
    let (controller, undo) = controller()
    controller.insertText("x")
    controller.setMarkedText("k", selectedRange: 1..<1)
    controller.setMarkedText("か", selectedRange: 1..<1)
    controller.insertText("か")
    #expect(plainText(controller.document) == ["xか"])
    undo.undo()
    #expect(plainText(controller.document) == ["x"])
    #expect(controller.state.markedText == nil)
  }

  @Test func undoRestoresPluginStateAndSkipsTransforms() {
    let key = PluginKey("count", default: 0)
    let (controller, undo) = controller(plugins: [UppercaseQ()])
    controller.update { state in
      state.insert("a")
      state[key] = 1
    }
    controller.insertText("q")
    #expect(plainText(controller.document) == ["aQ"])
    undo.undo()
    #expect(plainText(controller.document) == ["a"])
    undo.undo()
    #expect(controller.state[key] == 0)
    // Restoring a snapshot doesn't run transforms on it.
    controller.restore(EditorState(document: Document(blocks: [paragraph(text("q"))])))
    #expect(plainText(controller.document) == ["q"])
  }

  @Test func undoAppliesTheSmallestEdit() {
    let (controller, undo) = controller()
    controller.setDocument(
      Document(blocks: [paragraph(text("one")), paragraph(text("two")), paragraph(text("three"))]))
    controller.selection = .caret(6)
    controller.insertText("!")
    let changeset = controller.restore(
      EditorState(
        document: Document(blocks: [
          paragraph(text("one")), paragraph(text("two")), paragraph(text("three")),
        ])))
    #expect(changeset.edits == [.init(range: 6..<7, replacementLength: 0)])
    _ = undo
  }
}

@Suite struct DifferenceTests {
  /// Assigning a document records an edit that covers every change and
  /// nothing past the changed blocks.
  @Test @MainActor func assigningADocumentRecordsTheSmallestEdit() {
    var generator = DocumentGenerator(seed: 0xD1FF)
    for _ in 0..<300 {
      let old = generator.document().normalized()
      var edited = EditorState(document: old)
      let length = old.length
      let a = generator.int(0...length)
      let b = generator.int(0...length)
      switch generator.int(0...3) {
      case 0:
        edited.insert(
          generator.pick(["x", "😀", "a\nb"]),
          at: Selection(Position(min(a, b))..<Position(max(a, b))))
      case 1: edited.splitBlock(at: Position(a))
      case 2: edited.toggleMark(.bold, in: Position(min(a, b))..<Position(max(a, b)))
      default: edited.document.blocks.insert(.quote([paragraph(text("new"))]), at: 0)
      }
      let new = edited.document
      var state = EditorState(document: old)
      state.selection = .caret(0)
      let changeset = ComposerController(state).update { $0.document = new }
      #expect(changesetCovers(changeset, from: old, to: new), "\(old)\n\(new)\n\(changeset)")
      #expect(changeset.edits.count <= 1)
    }
  }

  @Test @MainActor func oneChangedCharacterIsOneUnit() {
    let controller = ComposerController(
      EditorState(document: Document(blocks: [paragraph(text("abc")), paragraph(text("d😀f"))])))
    var changeset = controller.update {
      $0.document = Document(blocks: [paragraph(text("abc")), paragraph(text("d😁f"))])
    }
    // 😀 and 😁 share a lead surrogate; the edit keeps the pair whole.
    #expect(changeset.edits == [.init(range: 5..<7, replacementLength: 2)])
    changeset = controller.update {
      $0.document = Document(blocks: [paragraph(text("abc")), .quote([paragraph(text("d😁f"))])])
    }
    // A block whose container changed is replaced, with its separator.
    #expect(changeset.edits == [.init(range: 3..<8, replacementLength: 5)])
  }
}

@Suite struct CombinedEditTests {
  /// Random sequential edits on a string: replacing the combined edit's range
  /// of the original with the same range of the result gives the result.
  @Test func oneReplacementReproducesSequentialEdits() {
    var rng = SeededGenerator(seed: 7)
    for _ in 0..<2_000 {
      let original = Array(repeating: "o", count: Int.random(in: 0...12, using: &rng))
      var current = original
      var edits: [Changeset.Edit] = []
      for index in 0..<Int.random(in: 1...4, using: &rng) {
        let lower = Int.random(in: 0...current.count, using: &rng)
        let upper = Int.random(in: lower...current.count, using: &rng)
        let length = Int.random(in: 0...3, using: &rng)
        current.replaceSubrange(
          lower..<upper, with: Array(repeating: "\(index)", count: length))
        edits.append(.init(range: Position(lower)..<Position(upper), replacementLength: length))
      }
      let changeset = Changeset(edits: edits, selectionBefore: .caret(0), selectionAfter: .caret(0))
      let combined = changeset.combinedEdit!
      if edits.count == 1 { #expect(combined == edits[0]) }
      let lower = combined.range.lowerBound.offset
      var rebuilt = original
      rebuilt.replaceSubrange(
        lower..<combined.range.upperBound.offset,
        with: current[lower..<lower + combined.replacementLength])
      #expect(rebuilt == current, "\(edits)")
      if rebuilt != current { return }
    }
  }

  @Test func noEditsIsNil() {
    #expect(Changeset(selectionBefore: .caret(0), selectionAfter: .caret(1)).combinedEdit == nil)
  }
}

@MainActor @Suite struct SelectionAlignmentTests {
  /// "a👍🏽b": "a" 0..<1, the emoji 1..<5 (two surrogate pairs), "b" 5..<6.
  let controller = ComposerController(
    EditorState(document: Document(blocks: [.paragraph([.text("a👍🏽b")])])))

  @Test func aCaretInsideACharacterMovesToItsStart() {
    for offset in 2...4 {
      controller.selection = .caret(offset)
      #expect(controller.selection == .caret(1), "caret \(offset)")
    }
    controller.selection = .caret(5)
    #expect(controller.selection == .caret(5))
  }

  @Test func aRangeGrowsToWholeCharactersAndKeepsItsDirection() {
    controller.selection = Selection(anchor: 3, head: 6)
    #expect(controller.selection == Selection(anchor: 1, head: 6))
    controller.selection = Selection(anchor: 2, head: 0)
    #expect(controller.selection == Selection(anchor: 5, head: 0))
    controller.selection = Selection(anchor: 0, head: 9)
    #expect(controller.selection == Selection(anchor: 0, head: 6))
  }

  @Test func aKeyPressCommitsTheCompositionFirst() {
    let driver = ControllerDriver()
    driver.run(
      Session {
        Type("a")
        Marked("か", committing: nil)
        Press(.return, modifiers: .shift)
        Undo()
      })
    #expect(driver.state.document.blocks == [.paragraph([.text("aか")])])
  }
}

@MainActor @Suite struct StoredMarkTests {
  func toggleBold(_ controller: ComposerController) {
    controller.update { $0.toggleMark(.bold, in: $0.selection.range) }
  }

  func type(_ controller: ComposerController, _ text: String) {
    for character in text { controller.insertText(String(character)) }
  }

  @Test func togglingAtTheCaretAppliesToTheNextTypedText() {
    let controller = ComposerController(
      EditorState(document: Document(blocks: [paragraph(text("ab"))])))
    toggleBold(controller)
    #expect(controller.state.storedMarks == .bold)
    #expect(controller.document.blocks == [paragraph(text("ab"))], "nothing changes yet")
    type(controller, "cd")
    #expect(controller.state.storedMarks == nil, "typing uses them up")
    // Off again in the middle of bold text: the next character is plain,
    // though the text before it is bold.
    toggleBold(controller)
    #expect(controller.state.storedMarks == Marks())
    type(controller, "e")
    #expect(controller.document.blocks == [paragraph(text("ab"), text("cd", .bold), text("e"))])
    // Toggling twice is no stored mark at all.
    toggleBold(controller)
    toggleBold(controller)
    #expect(controller.state.storedMarks == nil)
  }

  @Test func movingTheCaretEndsTheStoredMarks() {
    let controller = ComposerController(
      EditorState(document: Document(blocks: [paragraph(text("ab"))])))
    toggleBold(controller)
    controller.selection = .caret(1)
    #expect(controller.state.storedMarks == nil)
    type(controller, "x")
    #expect(controller.document.blocks == [paragraph(text("axb"))])
    // Deleting moves the caret too.
    toggleBold(controller)
    controller.deleteBackward()
    #expect(controller.state.storedMarks == nil)
  }

  @Test func aCompositionTakesTheStoredMarksUntilItCommits() {
    let controller = ComposerController()
    toggleBold(controller)
    controller.setMarkedText("k", selectedRange: 1..<1)
    controller.setMarkedText("か", selectedRange: 1..<1)
    #expect(controller.state.storedMarks == .bold, "the caret moving inside keeps them")
    controller.insertText("火")
    #expect(controller.document.blocks == [paragraph(text("火", .bold))])
    #expect(controller.state.storedMarks == nil)
  }

  @Test func aTransformCanEndTheMarkItConverts() {
    // Like a markdown conversion: `!x!` becomes a bold `x`, and the mark
    // ends there.
    let convert = NodeTransform("bang") { state, range in
      guard let block = state.document.textBlock(containing: range.lowerBound),
        case .paragraph(let inlines) = block.content, inlines == [text("!x!")]
      else { return }
      let start = block.range.lowerBound.offset
      state.replace(
        Position(start)..<Position(start + 3), with: [text("x", .bold)])
      state.storedMarks = Marks()
    }
    let controller = ComposerController(plugins: [Transforms(transforms: [convert])])
    type(controller, "!x!y")
    #expect(controller.document.blocks == [paragraph(text("x", .bold), text("y"))])
  }

  @Test func storedMarksArePartOfTheState() {
    var state = EditorState()
    let plain = state
    state.storedMarks = .bold
    #expect(state != plain)
  }
}
