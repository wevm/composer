import ComposerCore
import Foundation
import Testing

@Suite struct ContentTests {
  let renderer = ContentRenderer(schema: testSchema)

  func runs(_ string: AttributedString) -> [(String, Marks?, AtomicNode?, Bool)] {
    string.runs.map { run in
      (
        String(string[run.range].characters), run[ComposerAttributes.MarksAttribute.self],
        run[ComposerAttributes.NodeAttribute.self],
        run[ComposerAttributes.DecorationAttribute.self] ?? false
      )
    }
  }

  @Test func blocksAreLinesWithTheirMarkersAndBars() {
    let document = MarkdownCodec(schema: testSchema).parse(
      """
      **hi** there
      next

      > quoted
      > on two lines

      3. one
         - inner
           - [x] done

      ```
      a
      b
      ```
      """)
    let rendered = renderer.attributedString(document)
    #expect(
      String(rendered.characters) == """
        hi there
        next
        ┃ quoted
        ┃ on two lines
        3. one
           • inner
             ☑ done
        a
        b
        """)
    let first = runs(rendered)[0]
    #expect(first.0 == "hi" && first.1 == .bold)
    #expect(runs(rendered).contains { $0.0 == "┃ " && $0.3 }, "bars are decoration")
    #expect(
      rendered.runs.contains { $0[ComposerAttributes.CodeBlockAttribute.self] == true },
      "code block text is marked")
  }

  @Test func tokensCarryTheirNodeAndANodeURLAndLinksTheirURL() throws {
    let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "u&1 x"])
    let document = Document(blocks: [
      .paragraph([
        .text("hey "), .node(mention), .text(" see "), text("site", .link("https://x.dev")),
      ])
    ])
    let rendered = renderer.attributedString(document)
    #expect(String(rendered.characters) == "hey @tom see site")
    let token = try #require(
      rendered.runs.first { $0[ComposerAttributes.NodeAttribute.self] != nil })
    #expect(token[ComposerAttributes.NodeAttribute.self] == mention)
    let url = try #require(token.link)
    #expect(AtomicNode(url: url) == mention, "the node survives its URL")
    #expect(AtomicNode(url: URL(string: "https://x.dev")!) == nil)
    let link = try #require(rendered.runs.first { $0.link?.host == "x.dev" })
    #expect(String(rendered[link.range].characters) == "site")
  }

  @Test func hoverFindsTokensAndWholeLinks() throws {
    let mention = AtomicNode(type: .mention, label: "tom")
    let document = Document(blocks: [
      .paragraph([
        .text("a "), text("li", .link("u")), text("nk", Marks(bold: true, link: "u")),
        text("x", .link("v")), .node(mention), .text(" b"),
      ])
    ])
    #expect(document.hoverKind(at: 0) == nil)
    let link = try #require(document.hoverKind(at: 3))
    #expect(link.kind == .link("u"))
    #expect(link.range == Position(2)..<Position(6), "across its runs, not into the next link")
    #expect(document.hoverKind(at: 6)?.kind == .link("v"))
    #expect(document.hoverKind(at: 7)?.kind == .node(mention))
    #expect(document.hoverKind(at: 7)?.range == Position(7)..<Position(8))
    #expect(document.hoverKind(at: 8) == nil)
  }

  // MARK: Hover intent

  func target(_ label: String, at offset: Int = 0) -> HoverTarget {
    HoverTarget(
      kind: .node(AtomicNode(type: .mention, label: label)),
      range: Position(offset)..<Position(offset + 1),
      anchor: CGRect(x: offset, y: 0, width: 10, height: 10))
  }

  @Test func hoverOpensAfterTheDelayAndStaysForTheGracePeriod() {
    var intent = HoverIntent()
    intent.pointer(over: target("a"), at: 0)
    #expect(intent.advance(to: 0.3) == 0.5)
    #expect(intent.shown == nil)
    // Moving within the same target doesn't restart the delay.
    intent.pointer(over: target("a"), at: 0.4)
    intent.advance(to: 0.5)
    #expect(intent.shown == target("a"))
    // Leaving starts the grace period; coming back keeps it open.
    intent.pointer(over: nil, at: 1)
    #expect(intent.advance(to: 1.1) == 1.15)
    intent.pointer(over: target("a"), at: 1.1)
    intent.advance(to: 2)
    #expect(intent.shown == target("a"))
    // Onto the card within the grace period: it stays as long as the card
    // is hovered, and goes a grace period after the card is left.
    intent.pointer(over: nil, at: 3)
    intent.card(isHovered: true, at: 3.1)
    intent.advance(to: 10)
    #expect(intent.shown == target("a"))
    intent.card(isHovered: false, at: 10)
    intent.advance(to: 10.1)
    #expect(intent.shown != nil)
    intent.advance(to: 10.15)
    #expect(intent.shown == nil)
  }

  @Test func hoverDoesNotFlickerAcrossTextAndSwitchesAfterTheDelay() {
    var intent = HoverIntent()
    intent.pointer(over: target("a"), at: 0)
    intent.advance(to: 0.5)
    // Across plain text toward another token, briefly: no flicker.
    intent.pointer(over: nil, at: 1)
    intent.pointer(over: target("b", at: 5), at: 1.05)
    intent.advance(to: 1.1)
    #expect(intent.shown == target("a"))
    intent.advance(to: 1.15)
    #expect(intent.shown == nil)
    #expect(intent.advance(to: 1.2) == 1.55)
    intent.advance(to: 1.55)
    #expect(intent.shown == target("b", at: 5))
    // Leaving before the delay never opens it.
    var brief = HoverIntent()
    brief.pointer(over: target("a"), at: 0)
    brief.pointer(over: nil, at: 0.4)
    #expect(brief.advance(to: 5) == nil)
    #expect(brief.shown == nil)
  }
}
