import ComposerCore
import ComposerTesting
import Testing

@MainActor @Suite struct SessionTests {
  @Test func theBuilderKeepsStepOrderThroughControlFlow() {
    let shift = true
    let session = Session {
      Type("a")
      if shift { Press(.return, modifiers: .shift) } else { Press(.return) }
      for word in ["b", "c"] { Type(word) }
      Undo()
    }
    #expect(
      session.steps == [.type("a"), .press(.return, [.shift]), .type("b"), .type("c"), .undo])
  }

  @Test func theDesignExampleRunsOnTheController() {
    let driver = ControllerDriver()
    driver.run(
      Session {
        Type("hello **wor")
        Marked("l", "ld", committing: "ld")
        Type("**")
        Press(.return, modifiers: .shift)
        Paste(.plainText("https://wevm.dev"))
      })
    // No markdown plugin is installed, so the syntax stays literal.
    let expected = "hello **world**\nhttps://wevm.dev"
    #expect(driver.state.document == Document(blocks: [paragraph(text(expected))]))
    #expect(driver.state.selection == .caret(expected.utf16.count))
    #expect(driver.state.markedText == nil)
  }

  @Test func aNewlineInTypeIsAReturnPress() {
    let driver = ControllerDriver()
    driver.run(Session { Type("a\nb") })
    #expect(driver.state.document.blocks == [paragraph(text("a")), paragraph(text("b"))])
  }

  @Test func arrowsMoveByGraphemeAndNode() {
    // "a👍🏽" is 1 + 4 UTF-16 units; the mention is one unit.
    let document = Document(blocks: [
      paragraph(text("a👍🏽"), mention("Tom", id: "1")), paragraph(text("b")),
    ])
    let driver = ControllerDriver(EditorState(document: document, selection: .caret(0)))
    var carets: [Int] = []
    for _ in 0..<5 {
      driver.perform(.press(.rightArrow, []))
      carets.append(driver.state.selection.head.offset)
    }
    // Past the emoji, past the mention, over the separator, past "b", stuck at the end.
    #expect(carets == [1, 5, 6, 7, 8])
    driver.perform(.press(.leftArrow, [.shift]))
    driver.perform(.press(.leftArrow, [.shift]))
    #expect(driver.state.selection == Selection(anchor: 8, head: 6))
    driver.perform(.press(.rightArrow, []))
    #expect(driver.state.selection == .caret(8))
    driver.run(Session { Select(caret: 0) })
    driver.perform(.press(.leftArrow, []))
    #expect(driver.state.selection == .caret(0))
  }

  @Test func undoAndRedoWalkTheGroups() {
    let driver = ControllerDriver()
    driver.run(Session { Type("abc\nd") })
    var states: [String] = []
    for _ in 0..<4 {
      driver.perform(.undo)
      states.append(plainText(driver.state.document))
    }
    // "d", then the split, then the typing; the fourth undo has nothing left.
    #expect(states == ["abc|", "abc", "", ""])
    driver.perform(.redo)
    driver.perform(.redo)
    #expect(plainText(driver.state.document) == "abc|")
  }

  @Test func selectingOutsideTheMarkedTextCommitsIt() {
    let driver = ControllerDriver()
    driver.run(
      Session {
        Type("ab")
        Marked("k", committing: nil)
      })
    #expect(driver.state.markedText != nil)
    driver.run(Session { Select(caret: 3) })
    #expect(driver.state.markedText != nil, "A caret at the composition's end stays in it.")
    driver.run(Session { Select(caret: 0) })
    #expect(driver.state.markedText == nil)
    #expect(plainText(driver.state.document) == "abk")
    driver.perform(.undo)
    #expect(plainText(driver.state.document) == "ab", "The composition is one undo group.")
  }

  @Test func divergenceNamesTheFirstStepThatDisagrees() throws {
    let session = Session {
      Type("ab")
      Type("q")
      Type("c")
    }
    #expect(
      firstDivergence(of: session, reference: ControllerDriver(), engine: ControllerDriver())
        == nil)
    let divergence = try #require(
      firstDivergence(
        of: session, reference: ControllerDriver(),
        engine: ControllerDriver(plugins: [UppercaseQ()])))
    #expect(divergence.stepIndex == 1)
    #expect(divergence.step == .type("q"))
    #expect(divergence.description.contains("abQ"))
  }

  @Test func theAllowlistToleratesOnlyWhatItNormalizes() {
    let session = Session { Type("q") }
    let caseInsensitive = Allowlist([
      PlatformDifference("case") { state in
        state.document = Document(
          blocks: [paragraph(text(plainText(state.document).lowercased()))])
      }
    ])
    #expect(
      firstDivergence(
        of: session, reference: ControllerDriver(),
        engine: ControllerDriver(plugins: [UppercaseQ()]), allowing: caseInsensitive) == nil)
    let other = Session { Type("x") }
    #expect(
      firstDivergence(
        of: other, reference: ControllerDriver(),
        engine: ControllerDriver(EditorState(document: Document(blocks: [paragraph(text("y"))]))),
        allowing: caseInsensitive) != nil)
  }
}

/// The text blocks' text, separated by `|`.
private func plainText(_ document: Document) -> String {
  document.textBlocks.map { block in
    switch block.content {
    case .code(_, let text): text
    case .paragraph(let inlines):
      inlines.map { inline in
        if case .text(let text, _) = inline { return text }
        return "◆"
      }.joined()
    }
  }.joined(separator: "|")
}
