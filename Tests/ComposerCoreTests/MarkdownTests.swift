import ComposerCore
import Testing

@Suite struct MarkdownTests {
  // MARK: Properties

  @Test(arguments: 0..<4)
  func randomDocumentsRoundTrip(batch: UInt64) {
    var generator = DocumentGenerator(seed: 0xC0DE + batch)
    for _ in 0..<250 {
      let document = generator.document()
      let exported = markdown.serialize(document)
      let expected = markdown.canonical(document)
      let parsed = markdown.parse(exported)
      #expect(
        parsed == expected,
        "\(String(reflecting: document))\nexported:\n\(exported)\nparsed:\n\(String(reflecting: parsed))"
      )
      #expect(markdown.canonical(expected) == expected)
      #expect(markdown.serialize(parsed) == exported)
      if parsed != expected { return }
    }
  }

  @Test(arguments: 0..<4)
  func reexportIsIdempotent(batch: UInt64) {
    var generator = MarkdownGenerator(seed: 0xFACE + batch)
    for _ in 0..<1000 {
      let source = generator.markdown()
      let first = markdown.parse(source)
      let exported = markdown.serialize(first)
      let second = markdown.parse(exported)
      #expect(
        second == first,
        "source:\n\(source.debugDescription)\nexported:\n\(exported.debugDescription)\nfirst: \(String(reflecting: first))\nsecond: \(String(reflecting: second))"
      )
      #expect(markdown.serialize(second) == exported)
      if second != first { return }
    }
  }

  // MARK: Canonical export

  @Test func canonicalSpellings() {
    #expect(markdown.serialize(markdown.parse("*a* __b__ ~c~ * x")) == "_a_ **b** ~~c~~ * x")
    #expect(markdown.serialize(markdown.parse("* one\n+ two")) == "- one\n\n* two")
    #expect(markdown.serialize(markdown.parse("~~~ js\nx\n~~~")) == "```js\nx\n```")
  }

  @Test func marks() {
    let document = markdown.parse("**bold _both_** `co*de` ~~gone~~ [link](https://wevm.dev)")
    #expect(
      document.blocks == [
        paragraph(
          text("bold ", .bold), text("both", Marks(bold: true, italic: true)), text(" "),
          text("co*de", .code), text(" "), text("gone", .strikethrough), text(" "),
          text("link", .link("https://wevm.dev")))
      ])
  }

  @Test func nothingNestsInsideCode() {
    #expect(markdown.parse("`**a**`").blocks == [paragraph(text("**a**", .code))])
    let boldCode = Document(blocks: [paragraph(text("x", Marks(bold: true, code: true)))])
    #expect(markdown.serialize(boldCode) == "**`x`**")
    #expect(markdown.parse("**`x`**") == boldCode)
  }

  @Test func blocks() {
    let source = """
      > quoted
      >
      > - [x] done
      > - [ ] todo

      ```swift
      let a = 1

      ```

      3. three
      4. four
      """
    let document = markdown.parse(source)
    #expect(
      document.blocks == [
        .quote([
          paragraph(text("quoted")),
          .list(
            .bullet,
            items: [
              ListItem(checked: true, blocks: [paragraph(text("done"))]),
              ListItem(checked: false, blocks: [paragraph(text("todo"))]),
            ]),
        ]),
        .codeBlock(language: "swift", text: "let a = 1\n"),
        .list(
          .ordered(start: 3),
          items: [
            ListItem(blocks: [paragraph(text("three"))]),
            ListItem(blocks: [paragraph(text("four"))]),
          ]),
      ])
    #expect(markdown.serialize(document) == source)
  }

  @Test func autolinks() {
    let document = markdown.parse("see <https://wevm.dev/a?b=c> and https://bare.dev")
    #expect(
      document.blocks == [
        paragraph(
          text("see "), text("https://wevm.dev/a?b=c", .link("https://wevm.dev/a?b=c")),
          text(" and https://bare.dev"))
      ])
    #expect(markdown.serialize(document) == "see <https://wevm.dev/a?b=c> and https://bare.dev")
  }

  @Test func atomicNodes() {
    let document = Document(blocks: [
      paragraph(
        text("hi "), mention("tom", id: "user_123"), text(" "),
        .node(AtomicNode(type: .hashtag, label: "swift")))
    ])
    let exported = markdown.serialize(document)
    #expect(exported == "hi :mention[tom]{#user_123} #swift")
    #expect(markdown.parse(exported) == document)
    // Attributes that aren't a plain id are quoted.
    let odd = Document(blocks: [
      paragraph(
        .node(AtomicNode(type: .mention, label: "a]b", attributes: ["id": "a b", "x": "\"&"])))
    ])
    #expect(markdown.serialize(odd) == #":mention[a\]b]{id="a b" x="&quot;&amp;"}"#)
    #expect(markdown.parse(markdown.serialize(odd)) == odd)
  }

  @Test func unregisteredDirectivesStayText() {
    let document = markdown.parse(":poll[lunch]{id=p1} and :mention[tom]")
    #expect(
      document.blocks == [
        paragraph(text(":poll[lunch]{id=p1} and "), .node(AtomicNode(type: .mention, label: "tom")))
      ])
    #expect(MarkdownCodec().parse(":mention[tom]").blocks == [paragraph(text(":mention[tom]"))])
  }

  // MARK: Unsupported syntax

  @Test(arguments: [
    "# Heading", "## h2 _not_ lost", "| a | b |\n| - | - |\n| 1 | 2 |", "![alt](image.png)",
    "<b>raw</b> html", "[titled](https://x.dev \"Title\")", "[ref][1]", "[1]: https://x.dev",
    "a\n---", "***", "- - -", "line\\", "&copy; 2026", "a  b",
  ])
  func unsupportedSyntaxIsKeptLiterally(source: String) {
    let document = markdown.parse(source)
    #expect(document.blocks.count == 1)
    guard case .paragraph(let content)? = document.blocks.first else {
      Issue.record("Expected a paragraph: \(document)")
      return
    }
    // The literal source is the text, minus what the paragraph parse removes.
    let plain = content.map { inline -> String in
      if case .text(let text, _) = inline { return text }
      return ""
    }.joined()
    #expect(plain.filter { !"*_".contains($0) } == source.filter { !"*_".contains($0) })
    // And it exports as it was, so other renderers see the same thing.
    #expect(markdown.serialize(document) == source)
  }

  @Test func indentedCodeBecomesACodeBlock() {
    #expect(
      markdown.parse("    let a = 1\n      b").blocks == [
        .codeBlock(language: nil, text: "let a = 1\n  b")
      ])
  }

  // MARK: Escaping

  @Test func escapesOnlyWhatWouldParse() {
    let cases: [(String, String)] = [
      ("a * b", "a * b"),
      ("snake_case_name", "snake_case_name"),
      ("2*3*4", "2\\*3\\*4"),
      ("_x_", "\\_x\\_"),
      ("1. not a list", "1\\. not a list"),
      ("- not a list", "\\- not a list"),
      ("> not a quote", "\\> not a quote"),
      ("[not](a link)", "[not](a link)"),
      ("[a link](u)", "\\[a link](u)"),
      ("x <https://a.b> y", "x \\<https://a.b> y"),
      ("a <b> c", "a <b> c"),
      ("&amp; &copy;", "\\&amp; &copy;"),
      ("#tag # x", "\\#tag # x"),
      (":mention[tom]", "\\:mention[tom]"),
      ("`tick`", "\\`tick\\`"),
      ("back\\slash \\*", "back\\slash \\\\\\*"),
      ("~~", "~~"),
      ("100%", "100%"),
    ]
    for (plain, expected) in cases {
      let document = Document(blocks: [paragraph(text(plain))])
      #expect(markdown.serialize(document) == expected, "\(plain)")
      #expect(markdown.parse(expected) == document, "\(plain)")
    }
  }

  @Test func whitespaceAtLineEdges() {
    let document = Document(blocks: [paragraph(text("  indented\ntrailing \n\nafter empty"))])
    let exported = markdown.serialize(document)
    #expect(exported == "&#32; indented\ntrailing&#32;\n\\\nafter empty")
    #expect(markdown.parse(exported) == document)
  }

  @Test func intrawordEmphasis() {
    let document = Document(blocks: [paragraph(text("un"), text("believ", .italic), text("able"))])
    #expect(markdown.serialize(document) == "un*believ*able")
    #expect(markdown.parse("un*believ*able") == document)
    let bold = Document(blocks: [paragraph(text("a"), text("\"b\"", .bold), text("c"))])
    #expect(markdown.parse(markdown.serialize(bold)) == bold)
  }

  @Test func whitespaceMovesOutsideMarks() {
    let document = Document(blocks: [paragraph(text("a "), text(" b ", .bold), text("c"))])
    #expect(markdown.serialize(document) == "a  **b** c")
    #expect(markdown.parse("a  **b** c") == document.normalized())
  }

  @Test func overlappingMarksAndLinks() {
    let document = Document(blocks: [
      paragraph(
        text("a", .bold), text("b", Marks(bold: true, link: "u")), text("c", .link("u")),
        text("d", Marks(italic: true, link: "u")), text("e", .italic))
    ])
    let exported = markdown.serialize(document)
    #expect(markdown.parse(exported) == document, "\(exported)")
  }

  @Test func adjacentListsStaySeparate() {
    let document = Document(blocks: [
      bullets([paragraph(text("a"))]), bullets([paragraph(text("b"))]),
      bullets([paragraph(text("c"))]),
      .list(.ordered(start: 1), items: [ListItem(blocks: [paragraph(text("d"))])]),
      .list(.ordered(start: 5), items: [ListItem(blocks: [paragraph(text("e"))])]),
    ])
    let exported = markdown.serialize(document)
    #expect(exported == "- a\n\n* b\n\n- c\n\n1. d\n\n5) e")
    #expect(markdown.parse(exported) == document)
  }

  @Test func plainItemThatLooksLikeATask() {
    let document = Document(blocks: [bullets([paragraph(text("[ ] not a task"))])])
    #expect(markdown.serialize(document) == "- \\[ ] not a task")
    #expect(markdown.parse(markdown.serialize(document)) == document)
  }

  @Test func codeBlockFences() {
    let document = Document(blocks: [.codeBlock(language: nil, text: "```\ninner\n```")])
    #expect(markdown.serialize(document) == "````\n```\ninner\n```\n````")
    #expect(markdown.parse(markdown.serialize(document)) == document)
    let backtickLanguage = Document(blocks: [.codeBlock(language: "a`b", text: "x")])
    #expect(markdown.serialize(backtickLanguage) == "~~~a`b\nx\n~~~")
    #expect(markdown.parse(markdown.serialize(backtickLanguage)) == backtickLanguage)
  }

  // MARK: Nesting

  @Test func deepListsAreClampedToThreeLevels() {
    let source = """
      - one
        - two
          - three
            - four
              - five
            - four b
          - three b
      """
    let document = markdown.parse(source)
    let level3 = [
      ListItem(blocks: [paragraph(text("three"))]), ListItem(blocks: [paragraph(text("four"))]),
      ListItem(blocks: [paragraph(text("five"))]), ListItem(blocks: [paragraph(text("four b"))]),
      ListItem(blocks: [paragraph(text("three b"))]),
    ]
    #expect(
      document.blocks == [
        bullets([
          paragraph(text("one")), bullets([paragraph(text("two")), .list(.bullet, items: level3)]),
        ])
      ])
    #expect(markdown.parse(markdown.serialize(document)) == document)
  }

  @Test func clampingKeepsTasksAndContentAfterNestedLists() {
    let deep = Document(blocks: [
      bullets([
        paragraph(text("1")),
        bullets([
          paragraph(text("2")),
          .list(
            .bullet,
            items: [
              ListItem(
                checked: true,
                blocks: [
                  paragraph(text("3")),
                  .list(
                    .ordered(start: 1),
                    items: [ListItem(checked: false, blocks: [paragraph(text("4"))])]),
                  paragraph(text("3 again")),
                ])
            ]),
        ]),
      ])
    ])
    guard case .list(_, let items1) = deep.normalized().blocks[0],
      case .list(_, let items2) = items1[0].blocks[1],
      case .list(_, let items3) = items2[0].blocks[1]
    else {
      Issue.record("Unexpected shape")
      return
    }
    #expect(
      items3 == [
        ListItem(checked: true, blocks: [paragraph(text("3"))]),
        ListItem(checked: false, blocks: [paragraph(text("4"))]),
        ListItem(blocks: [paragraph(text("3 again"))]),
      ])
  }

  @Test func hostileNestingIsBounded() {
    let quotes = String(repeating: "> ", count: 5_000) + "deep"
    let lists = String(repeating: "- ", count: 5_000) + "deep"
    for source in [quotes, lists] {
      let document = markdown.parse(source)
      #expect(markdown.serialize(document).contains("deep"))
      #expect(markdown.parse(markdown.serialize(document)) == document)
    }
    let stars = String(repeating: "*", count: 10_000) + "a" + String(repeating: "*", count: 10_000)
    #expect(markdown.parse(markdown.serialize(markdown.parse(stars))) == markdown.parse(stars))
  }

  /// Cases the round-trip properties found, kept as regressions.
  @Test func foundByTheProperties() {
    let hashtag = Inline.node(AtomicNode(type: .hashtag, label: "tag"))
    let documents = [
      // An item that is only `---`, and an empty level-3 item: `- ---` and
      // `- - -` are thematic breaks.
      Document(blocks: [bullets([paragraph(text("---"))])]),
      Document(blocks: [bullets([bullets([bullets([])])])]),
      // Text `:` right before a directive.
      Document(blocks: [paragraph(text("a:"), mention("tom", id: "1"))]),
      // A delimiter right after a hard break.
      Document(blocks: [
        paragraph(text("a"), text("b\n\n", .link("u")), text("c", Marks(italic: true)))
      ]),
      Document(blocks: [
        paragraph(text("x "), text("y\n\n", Marks(italic: true, link: "u")), text("z", .italic))
      ]),
      // Italic after a hashtag, next to bold.
      Document(blocks: [
        paragraph(hashtag, text("a", .italic), text("b", Marks(bold: true, code: true)))
      ]),
    ]
    for document in documents {
      let exported = markdown.serialize(document)
      #expect(markdown.parse(exported) == markdown.canonical(document), "\(exported)")
    }
  }

  /// A custom token ending in a word character leaves no room to escape, so
  /// emphasis that couldn't open after it moves off the edge character. The
  /// text is kept.
  @Test func emphasisNextToAWordToken() {
    let hashtag = Inline.node(AtomicNode(type: .hashtag, label: "tag"))
    let fine = Document(blocks: [paragraph(hashtag, text("word", .italic))])
    #expect(markdown.canonical(fine) == fine)
    #expect(markdown.serialize(fine) == "#tag*word*")
    let punctuation = Document(blocks: [paragraph(hashtag, text("(x)", .italic))])
    #expect(
      markdown.canonical(punctuation).blocks == [paragraph(hashtag, text("("), text("x)", .italic))]
    )
    #expect(markdown.parse(markdown.serialize(punctuation)) == markdown.canonical(punctuation))
    let twoMarks = Document(blocks: [
      paragraph(hashtag, text("ab", Marks(bold: true, italic: true)))
    ])
    #expect(
      markdown.canonical(twoMarks).blocks == [
        paragraph(hashtag, text("a"), text("b", Marks(bold: true, italic: true)))
      ])
    #expect(markdown.parse(markdown.serialize(twoMarks)) == markdown.canonical(twoMarks))
  }

  @Test func lineEndingsAreNormalized() {
    #expect(markdown.parse("a\r\nb\rc") == markdown.parse("a\nb\nc"))
  }
}
