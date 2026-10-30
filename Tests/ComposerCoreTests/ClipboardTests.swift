import ComposerCore
import Foundation
import Testing

@MainActor @Suite struct ClipboardTests {
  // MARK: Fragments and copy

  @Test(arguments: 0..<4) func fragmentsHaveTheTextOfTheirRange(batch: UInt64) {
    var generator = DocumentGenerator(seed: 0xC11B + batch)
    for _ in 0..<200 {
      let document = generator.document()
      let length = document.length
      #expect(document.fragment(Position(0)..<Position(length)).plainText == document.plainText)
      let a = generator.int(0...length)
      let b = generator.int(0...length)
      let range = min(a, b)..<max(a, b)
      let fragment = document.fragment(Position(range.lowerBound)..<Position(range.upperBound))
      #expect(
        fragment.plainText == document.plainText(in: range),
        "\(range) of \(String(reflecting: document))\nfragment: \(String(reflecting: fragment))")
      if fragment.plainText != document.plainText(in: range) { return }
    }
  }

  @Test func fragmentsKeepTheirStructure() {
    let document = MarkdownCodec().parse("intro\n\n3. one\n4. two\n   > deep\n\nend")
    // From inside "one" to inside "deep": the list, renumbered from the
    // first item copied, and the quote inside the second item.
    let one = document.plainText.utf16.count - "ne\ntwo\ndeep\nend".utf16.count
    let fragment = document.fragment(Position(one)..<Position(one + 9))
    #expect(MarkdownCodec().serialize(fragment) == "3. ne\n4. two\n\n   > de")
    // Covering a separator keeps the empty block after it.
    let split = document.fragment(Position(3)..<Position(6))
    #expect(
      split.blocks == [
        paragraph(text("ro")),
        .list(.ordered(start: 3), items: [ListItem(blocks: [.paragraph([])])]),
      ])
  }

  @Test func copyThenPasteBringsTokensThrough() throws {
    let source = ComposerController(
      EditorState(
        document: Document(blocks: [
          paragraph(text("hi "), mention("Ann", id: "u1"), text(" **x**", .bold))
        ])),
      plugins: [MentionsPlugin(source: .static([]))])
    let content = try #require(source.clipboardContent(of: Position(1)..<Position(5)))
    #expect(content.markdown == "i :mention[Ann]{#u1}&#32;")
    #expect(source.clipboardContent(of: Position(2)..<Position(2)) == nil)
    let target = ComposerController(plugins: [MentionsPlugin(source: .static([]))])
    #expect(target.pasteDocument(content.json))
    #expect(
      target.document.blocks == [paragraph(text("i "), mention("Ann", id: "u1"), text(" ", .bold))])
    #expect(!target.pasteDocument(Data("nope".utf8)))
  }

  // MARK: HTML

  func pasted(_ html: String, plugins: [any ComposerPlugin] = []) -> ComposerController {
    let controller = ComposerController(plugins: [RichPaste()] + plugins)
    controller.paste(.html(html))
    return controller
  }

  @Test func htmlMarksAndLinksMapToTheSchema() {
    let controller = pasted(
      #"<meta charset="utf-8"><b>bold</b> <em>it</em> <del>gone</del> <code>x&lt;y</code> "#
        + #"<a href="https://wevm.dev">link</a> <a href="javascript:alert(1)">js</a> <u>under</u>"#
        + #" <span style="font-weight: 700; font-style: italic">both</span>"#)
    #expect(
      controller.document.blocks == [
        paragraph(
          text("bold", .bold), text(" "), text("it", .italic), text(" "),
          text("gone", .strikethrough), text(" "), text("x<y", .code), text(" "),
          text("link", .link("https://wevm.dev")), text(" js under "),
          text("both", Marks(bold: true, italic: true)))
      ])
  }

  @Test func googleDocsWrapperIsNotBold() {
    let controller = pasted(
      #"<b style="font-weight:normal;" id="docs-internal-guid-1"><p><span>plain</span> "#
        + #"<span style="font-weight:700">bold</span></p></b>"#)
    #expect(controller.document.blocks == [paragraph(text("plain "), text("bold", .bold))])
  }

  @Test func htmlBlocksMapToBlocks() {
    let controller = pasted(
      """
      <html><head><title>T</title><style>p { color: red }</style></head><body>
      <h2>Title</h2>
      <p>one
         two<br>three</p>
      <blockquote><p>quoted</p></blockquote>
      <ul>
        <li>a<ul><li>b<ul><li>c<ul><li>d</li></ul></li></ul></li></ul></li>
        <li class="task-list-item"><input type="checkbox" checked disabled> done</li>
      </ul>
      <ol start="3"><li>x</li><li>y</li></ol>
      <pre><code class="language-swift">let a = 1
      let b = 2
      </code></pre>
      <script>ignored()</script><!-- comment -->&amp; &#x1F600; &copy;
      </body></html>
      """)
    #expect(
      controller.markdown == """
        **Title**

        one two
        three

        > quoted

        - a
          - b
            - c
            - d
        - [x] done

        3. x
        4. y

        ```swift
        let a = 1
        let b = 2
        ```

        & 😀 ©
        """)
  }

  @Test func htmlImagesGoToTheTrayOnlyWhenItIsEnabled() {
    let withTray = pasted(
      #"<p>see</p><img src="https://x.dev/a.png" alt="A">"#,
      plugins: [AttachmentsPlugin { _, _ in }])
    #expect(withTray.markdown == "see")
    #expect(withTray.attachments.map(\.name) == ["A"])
    #expect(withTray.attachments.first?.payload as? URL == URL(string: "https://x.dev/a.png"))
    let without = pasted(#"<p>see</p><img src="https://x.dev/a.png">"#)
    #expect(without.markdown == "see")
    #expect(without.attachments.isEmpty)
  }

  @Test func matchStyleAndNoRichPastePasteHTMLAsText() {
    let controller = ComposerController(plugins: [RichPaste()])
    controller.paste(.html("<p><b>a</b></p><p>b</p>"), options: PasteOptions(matchesStyle: true))
    #expect(controller.document.blocks == [paragraph(text("a\nb"))])
    let plain = ComposerController()
    plain.paste(.html("<i>x</i>"))
    #expect(plain.document.blocks == [paragraph(text("x"))])
    #expect(!plain.acceptsRichPaste)
  }

  @Test func filesGoToTheTray() {
    let added = ComposerController(plugins: [AttachmentsPlugin { _, _ in }])
    let file = PastedFile(data: Data([1, 2]), contentType: "public.png", name: "a.png")
    added.paste(.files([file]))
    #expect(added.attachments.map(\.name) == ["a.png"])
    #expect(added.attachments.first?.payload as? PastedFile == file)
    #expect(added.document.isEmpty)
    let dropped = ComposerController()
    dropped.paste(.files([file]))
    #expect(dropped.document.isEmpty)
  }
}
