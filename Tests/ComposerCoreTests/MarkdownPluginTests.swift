import ComposerCore
import Testing

/// Types into a controller as a keyboard does: characters through
/// `insertText`, and `\n`, `\t`, `⇤` (⇧⇥), and `⌫` as key presses.
@MainActor func type(_ controller: ComposerController, _ text: String) {
  for character in text {
    switch character {
    case "\n": controller.handleKeyPress(.return)
    case "\t": controller.handleKeyPress(.tab)
    case "⇤": controller.handleKeyPress(.tab, modifiers: .shift)
    case "⌫": controller.handleKeyPress(.delete)
    default: controller.insertText(String(character))
    }
  }
}

@MainActor @Suite struct MarkdownPluginTests {
  func typed(
    _ text: String, plugins: [any ComposerPlugin] = [PluginGroup.markdown]
  )
    -> ComposerController
  {
    let controller = ComposerController(plugins: plugins)
    type(controller, text)
    return controller
  }

  // MARK: Inline

  @Test func marksConvertOnTheClosingDelimiterAndEndThere() {
    let controller = typed("a **bold** _it_ *it* ~~s~~ `c` z")
    #expect(
      controller.document.blocks == [
        paragraph(
          text("a "), text("bold", .bold), text(" "), text("it", .italic), text(" "),
          text("it", .italic), text(" "), text("s", .strikethrough), text(" "),
          text("c", .code), text(" z"))
      ])
    #expect(controller.markdown == "a **bold** _it_ _it_ ~~s~~ `c` z")
  }

  @Test func theNextCharacterAfterAConversionIsPlain() {
    let controller = typed("**b**x")
    #expect(controller.document.blocks == [paragraph(text("b", .bold), text("x"))])
  }

  @Test func marksNestAcrossRuns() {
    let controller = typed("**a _b_ c**")
    #expect(
      controller.document.blocks == [
        paragraph(text("a ", .bold), text("b", Marks(bold: true, italic: true)), text(" c", .bold))
      ])
  }

  @Test func typingConvertsWhatTheParserWould() {
    for literal in ["snake_case_name", "a * b *", "** x**", "`", "**", "__a__b"] {
      let controller = typed(literal)
      #expect(controller.document.blocks == [paragraph(text(literal))], "\(literal)")
    }
    // `*` emphasis works inside words; `_` doesn't.
    #expect(
      typed("2*3*4").document.blocks == [paragraph(text("2"), text("3", .italic), text("4"))])
    #expect(typed("__a__ b").document.blocks == [paragraph(text("a", .bold), text(" b"))])
  }

  @Test func aLaterCharacterInTheRunChangesTheConversion() {
    // `**bold*` is a literal `*` and italic text, until the second `*`.
    let controller = typed("**bold*")
    #expect(controller.document.blocks == [paragraph(text("*"), text("bold", .italic))])
    type(controller, "*")
    #expect(controller.document.blocks == [paragraph(text("bold", .bold))])
    // A letter after `__a__` makes it literal, and ⌫ makes it bold again.
    let underscores = typed("__a__b")
    type(underscores, "⌫")
    #expect(underscores.document.blocks == [paragraph(text("a", .bold))])
    // Moving the caret ends the run: what it converted stays, and typing
    // continues the mark before the caret.
    let moved = typed("__a__")
    moved.selection = .caret(0)
    moved.selection = .caret(1)
    type(moved, "b")
    #expect(moved.document.blocks == [paragraph(text("ab", .bold))])
  }

  @Test func codeTakesItsTextLiterally() {
    let controller = typed("`**x**`")
    #expect(controller.document.blocks == [paragraph(text("**x**", .code))])
    type(controller, " z")
    #expect(controller.document.blocks == [paragraph(text("**x**", .code), text(" z"))])
  }

  /// Typing without moving the caret converts each paragraph exactly as the
  /// markdown parser reads the characters typed, at every keystroke.
  @Test(arguments: [
    ["a", "word", " ", "*", "**", ".", "!"],
    ["a", "word", " ", "_", "__", "*", ".", "!"],
    ["a", "word", " ", "~~", "~", "**", "."],
    ["a", "word", " ", "`", "**", "_", "."],
    ["a", "word", " ", "[", "]", "(", ")", "](", "x.y", "**"],
    ["a", " ", "*", "_", "~", "`", "[", "]", "(", ")", "<", ">", "http:", "."],
  ])
  func typingMatchesTheParserAtEveryKeystroke(pieces: [String]) {
    var random = SeededGenerator(seed: 1)
    let codec = MarkdownCodec()
    for _ in 0..<1500 {
      let count = Int.random(in: 1...10, using: &random)
      let source = (0..<count).map { _ in pieces.randomElement(using: &random)! }.joined()
      let controller = ComposerController(plugins: [PluginGroup.markdown])
      var prefix = ""
      for character in source {
        controller.insertText(String(character))
        prefix.append(character)
        // The parser trims a paragraph's edges, and block syntax is the
        // block rules' to convert.
        guard let first = prefix.first, let last = prefix.last, !first.isWhitespace,
          !last.isWhitespace
        else { continue }
        let parsed = codec.canonical(codec.parse(prefix))
        guard parsed.blocks.count == 1, case .paragraph = parsed.blocks[0],
          controller.document.blocks.count == 1, case .paragraph = controller.document.blocks[0]
        else { continue }
        guard codec.canonical(controller.document) == parsed else {
          Issue.record(
            "\(prefix.debugDescription): typed \(codec.serialize(controller.document).debugDescription), parsed \(codec.serialize(parsed).debugDescription)"
          )
          return
        }
      }
    }
  }

  @Test func aLinkConvertsOnItsClosingParenthesis() {
    let controller = typed("see [wevm](https://wevm.dev) now")
    #expect(
      controller.document.blocks == [
        paragraph(text("see "), text("wevm", .link("https://wevm.dev")), text(" now"))
      ])
    #expect(typed("[a](b c)").document.blocks == [paragraph(text("[a](b c)"))])
  }

  // MARK: Revert

  @Test func backspaceRightAfterAConversionRevertsIt() {
    let controller = typed("x **b**⌫")
    #expect(controller.document.blocks == [paragraph(text("x **b**"))])
    #expect(controller.selection == .caret(7))
    // It stays literal as typing goes on.
    type(controller, " y")
    #expect(controller.document.blocks == [paragraph(text("x **b** y"))])
    // Deleting back to the delimiter doesn't convert it again: rules
    // convert what is typed.
    type(controller, "⌫⌫")
    #expect(controller.document.blocks == [paragraph(text("x **b**"))])
    let list = typed("- x⌫")
    #expect(list.markdown == "-")
  }

  @Test func backspaceAfterMovingOnDeletesNormally() {
    let controller = typed("**b**x⌫")
    #expect(controller.document.blocks == [paragraph(text("b", .bold))])
    let moved = typed("**b**")
    moved.selection = .caret(0)
    moved.selection = .caret(1)
    type(moved, "⌫")
    #expect(moved.document.blocks == [paragraph(text(""))] || moved.document.length == 0)
  }

  @Test func backspaceRevertsABlockConversion() {
    let controller = typed("- ⌫")
    #expect(controller.document.blocks == [paragraph(text("- "))])
    #expect(typed("> ⌫").document.blocks == [paragraph(text("> "))])
    #expect(typed("```\n⌫").document.blocks == [paragraph(text("```"))])
  }

  // MARK: Lists

  @Test func returnContinuesAListAndAnEmptyItemEndsIt() {
    let controller = typed("- a\nb\n\nc")
    #expect(controller.markdown == "- a\n- b\n\nc")
    #expect(typed("3. x\ny").markdown == "3. x\n4. y")
  }

  @Test func returnSplitsAnItemAtTheCaret() {
    let controller = typed("- ab")
    controller.selection = .caret(1)
    type(controller, "\n")
    #expect(controller.markdown == "- a\n- b")
    #expect(controller.selection == .caret(2))
  }

  @Test func tabIndentsUpToThreeLevels() {
    let controller = typed("- a\n\tb\n\tc\n\td")
    #expect(controller.markdown == "- a\n  - b\n    - c\n    - d")
    // The first item can't indent, and a tab is never typed in a list.
    let first = typed("- a\t")
    #expect(first.markdown == "- a")
  }

  @Test func outdentAndBackspaceLiftItems() {
    let controller = typed("- a\n\tb\n\tc⇤")
    #expect(controller.markdown == "- a\n  - b\n  - c")
    // An empty nested item moves out a level on ↩.
    type(controller, "\n\n")
    #expect(controller.markdown == "- a\n  - b\n  - c\n-")
    // ⌫ at the start of a top-level item leaves the list.
    let lifted = typed("- a\nb")
    lifted.selection = .caret(2)
    type(lifted, "⌫")
    #expect(lifted.markdown == "- a\n\nb")
  }

  @Test func outdentTakesTheFollowingItemsAsChildren() {
    let controller = typed("- a\n\tb\nc\nd")
    controller.selection = .caret(2)  // In "b".
    type(controller, "⇤")
    #expect(controller.markdown == "- a\n- b\n  - c\n  - d")
  }

  @Test func listsWorkInsideQuotes() {
    let controller = typed("> - a\nb")
    #expect(controller.markdown == "> - a\n> - b")
  }

  // MARK: Tasks

  @Test func taskItemsConvertAndToggle() {
    let controller = typed("- [ ] milk\n")
    #expect(controller.markdown == "- [ ] milk\n- [ ]")
    type(controller, "eggs")
    controller.selection = .caret(1)
    controller.run(.toggleTask)
    #expect(controller.markdown == "- [x] milk\n- [ ] eggs")
    // Toggling at a position, as a click on the box does.
    controller.run(Command<Position>.toggleTask, Position(6))
    #expect(controller.markdown == "- [x] milk\n- [x] eggs")
    // ⌫ at the start of a task removes its box first.
    controller.selection = .caret(5)
    type(controller, "⌫")
    #expect(controller.markdown == "- [x] milk\n- eggs")
    #expect(typed("- [x] done").markdown == "- [x] done")
  }

  // MARK: Quotes and code

  @Test func quotesContinueAndAnEmptyLineLeaves() {
    let controller = typed("> q\nr\n\nafter")
    #expect(controller.markdown == "> q\n>\n> r\n\nafter")
  }

  @Test func backspaceAtTheStartOfAQuoteMovesItOut() {
    let controller = typed("> q")
    controller.selection = .caret(0)
    type(controller, "⌫")
    #expect(controller.markdown == "q")
  }

  @Test func codeBlocksOpenOnReturnAndLeaveOnAnEmptyLastLine() {
    let controller = typed("```swift\nlet x\n\nafter")
    #expect(controller.markdown == "```swift\nlet x\n```\n\nafter")
    #expect(
      controller.document.blocks == [
        .codeBlock(language: "swift", text: "let x"), paragraph(text("after")),
      ])
    // Nothing converts inside a code block.
    #expect(typed("```\n**a** - b").markdown == "```\n**a** - b\n```")
  }

  @Test func backspaceAtTheStartOfACodeBlockMakesItAParagraph() {
    let controller = typed("```\nx")
    controller.selection = .caret(0)
    type(controller, "⌫")
    #expect(controller.document.blocks == [paragraph(text("x"))])
  }

  // MARK: Plugins

  @Test func eachRuleIsItsOwnPlugin() {
    let controller = typed("**b** - x", plugins: [MarkdownBold()])
    #expect(controller.document.blocks == [paragraph(text("b", .bold), text(" - x"))])
    let lists = typed("- **b**", plugins: [MarkdownLists()])
    #expect(lists.markdown == "- \\*\\*b\\*\\*")
  }

  @Test func toggleCommandsWorkOnSelectionsAndTheCaret() {
    let controller = typed("ab")
    controller.selection = Selection(Position(0)..<Position(2))
    #expect(controller.handleKey("b", modifiers: .command))
    #expect(controller.document.blocks == [paragraph(text("ab", .bold))])
    controller.selection = .caret(2)
    controller.handleKey("i", modifiers: .command)
    type(controller, "c")
    #expect(
      controller.document.blocks == [
        paragraph(text("ab", .bold), text("c", Marks(bold: true, italic: true)))
      ])
  }

  /// Random typing over markdown syntax never traps, reaches a fixed point,
  /// and always leaves a document whose markdown parses back to it.
  @Test(arguments: 0..<40) func randomTypingKeepsTheDocumentRoundTripping(seed: UInt64) {
    var random = SeededGenerator(seed: seed)
    let alphabet = Array("ab *_~`[]()>-1.\n\n\t⇤⌫⌫")
    let controller = ComposerController(plugins: [PluginGroup.markdown])
    let codec = MarkdownCodec(schema: controller.schema)
    for _ in 0..<120 {
      let character = alphabet[Int(random.next() % UInt64(alphabet.count))]
      if random.next() % 12 == 0 {
        controller.selection = .caret(Int(random.next() % UInt64(controller.document.length + 1)))
      }
      type(controller, String(character))
      let document = controller.document
      #expect(
        codec.parse(codec.serialize(document)) == codec.canonical(document),
        "seed \(seed): \(codec.serialize(document).debugDescription)")
      #expect(listDepth(document.blocks) <= 3)
    }
  }

  func listDepth(_ blocks: [Block]) -> Int {
    blocks.map { block -> Int in
      switch block {
      case .list(_, let items): 1 + (items.map { listDepth($0.blocks) }.max() ?? 0)
      case .quote: 0
      default: 0
      }
    }.max() ?? 0
  }
}
