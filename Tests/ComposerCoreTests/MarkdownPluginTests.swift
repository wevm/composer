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

  @Test func delimitersInsideWordsAndNextToSpacesStayLiteral() {
    for literal in ["snake_case_name", "2*3*4", "a * b *", "** x**", "**bold*", "`", "**"] {
      let controller = typed(literal)
      #expect(controller.document.blocks == [paragraph(text(literal))], "\(literal)")
    }
  }

  @Test func codeTakesNoOtherMarks() {
    let controller = typed("`**x**`")
    // `**x**` converts first, as it is typed; the code then drops the bold.
    #expect(controller.document.blocks == [paragraph(text("x", .code))])
    // The code still ends at its closing delimiter, though the bold
    // conversion before it left the same stored marks.
    type(controller, " z")
    #expect(controller.document.blocks == [paragraph(text("x", .code), text(" z"))])
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
