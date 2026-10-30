import ComposerCore
import Testing

@MainActor @Suite struct LinkAndPasteTests {
  func controller(_ markdown: String = "", caret: Int? = nil) -> ComposerController {
    let document = markdown.isEmpty ? Document.empty : MarkdownCodec().parse(markdown)
    return ComposerController(
      EditorState(document: document, selection: caret.map(Selection.caret)),
      plugins: [PluginGroup.chatDefaults])
  }

  @Test func autolinkLinksAURLWhenASpaceFollowsIt() {
    let controller = controller()
    type(controller, "see https://wevm.dev/x. and www.example.com, or https://x ok")
    #expect(
      controller.document.blocks == [
        paragraph(
          text("see "), text("https://wevm.dev/x", .link("https://wevm.dev/x")),
          text(". and "), text("www.example.com", .link("https://www.example.com")),
          text(", or https://x ok"))
      ])
    // Parentheses the URL opened stay in it.
    let wiki = self.controller()
    type(wiki, "https://en.wikipedia.org/wiki/A_(b) ")
    #expect(wiki.document.marks(at: Position(34)).link == "https://en.wikipedia.org/wiki/A_(b)")
  }

  @Test func pastedMarkdownIsParsedAndItsURLsLinked() {
    let controller = controller()
    controller.paste(.plainText("**b** and https://x.dev"))
    #expect(
      controller.document.blocks == [
        paragraph(text("b", .bold), text(" and "), text("https://x.dev", .link("https://x.dev")))
      ])
    #expect(controller.selection == .caret(controller.document.length))
  }

  @Test func plainTextStaysPlainAndMatchStylePastesLiterally() {
    let controller = controller()
    controller.paste(.plainText("one\n\ntwo"))
    #expect(controller.document.blocks == [paragraph(text("one\n\ntwo"))])
    controller.clear()
    controller.paste(.plainText("**b**"), options: PasteOptions(matchesStyle: true))
    #expect(controller.document.blocks == [paragraph(text("**b**"))])
  }

  @Test func blocksPasteBetweenTheTextBeforeAndAfter() {
    let controller = controller("xy", caret: 1)
    controller.paste(.plainText("- a\n- b"))
    #expect(controller.markdown == "x\n\n- a\n- b\n\ny")
    #expect(controller.selection == .caret(5), "after the pasted list")
    // Paragraphs at the edges join the text around them.
    let joined = self.controller("xy", caret: 1)
    joined.paste(.plainText("_a_\n\nb"))
    #expect(
      joined.document.blocks == [paragraph(text("x"), text("a", .italic)), paragraph(text("by"))])
    #expect(joined.selection == .caret(4))
    // Into a code block, as text.
    let code = self.controller("```\nxy\n```", caret: 1)
    code.paste(.plainText("> q\n\nr"))
    #expect(code.document.blocks == [.codeBlock(language: nil, text: "xq\nry")])
  }

  @Test func aURLPastedOverASelectionLinksIt() {
    let controller = controller("see this")
    controller.selection = Selection(Position(4)..<Position(8))
    controller.paste(.plainText(" https://wevm.dev "))
    #expect(
      controller.document.blocks == [
        paragraph(text("see "), text("this", .link("https://wevm.dev")))
      ])
    // Anything else replaces the selection.
    controller.selection = Selection(Position(0)..<Position(3))
    controller.paste(.plainText("look at"))
    #expect(controller.markdown == "look at [this](https://wevm.dev)")
  }

  @Test func commandKEditsTheLinkAtTheCaretOrTheSelection() {
    let controller = controller("ab [link](https://a.dev) c")
    controller.selection = Selection(Position(0)..<Position(2))
    #expect(controller.handleKey("k", modifiers: .command))
    #expect(controller.linkEditing == LinkEditing(range: Position(0)..<Position(2), url: nil))
    controller.applyLink("https://b.dev")
    #expect(controller.linkEditing == nil)
    #expect(controller.markdown == "[ab](https://b.dev) [link](https://a.dev) c")
    // At a caret in a link, the whole link.
    controller.selection = .caret(5)
    controller.editLink()
    #expect(controller.linkEditing?.range == Position(3)..<Position(7))
    #expect(controller.linkEditing?.url == "https://a.dev")
    controller.removeLink()
    #expect(controller.markdown == "[ab](https://b.dev) link c")
    // At a caret elsewhere, applying inserts the URL as a link.
    controller.selection = .caret(controller.document.length)
    controller.editLink()
    controller.applyLink("https://c.dev", text: " site")
    #expect(controller.markdown.hasSuffix("c[ site](https://c.dev)"))
    // Esc and moving the selection close it.
    controller.editLink()
    controller.handleKeyPress(.escape)
    #expect(controller.linkEditing == nil)
    controller.editLink()
    controller.selection = .caret(0)
    #expect(controller.linkEditing == nil)
  }
}
