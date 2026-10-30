import ComposerCore
import Synchronization
import Testing

let people = [
  Suggestion(id: "u1", label: "tom"), Suggestion(id: "u2", label: "tony"),
  Suggestion(id: "u3", label: "Ann", subtitle: "Design"), Suggestion(id: "u4", label: "Émile"),
]

/// An async source that records its queries.
struct RecordingSource: SuggestionSource {
  let log = Box<[String]>([])
  let items: [Suggestion]
  var queries: [String] { log.value.withLock { $0 } }

  func results(for query: String) async throws -> [Suggestion] {
    log.value.withLock { $0.append(query) }
    return items.filter { $0.label.hasPrefix(query) }
  }
}

final class Box<Value: Sendable>: Sendable {
  let value: Mutex<Value>
  init(_ value: Value) { self.value = Mutex(value) }
}

@MainActor @Suite struct TriggerTests {
  /// Waits for async suggestion results.
  func settle(_ controller: ComposerController) async throws {
    for _ in 0..<200 {
      if controller.suggestions.phase != .loading { return }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  @Test func mentionsSuggestHighlightAndCommit() {
    let controller = ComposerController(plugins: [MentionsPlugin(source: .static(people))])
    type(controller, "hi @to")
    let suggestions = controller.suggestions
    #expect(suggestions.isActive)
    #expect(suggestions.trigger == "@")
    #expect(suggestions.query == "to")
    #expect(suggestions.items.map(\.label) == ["tom", "tony"])
    #expect(suggestions.phase == .results)
    controller.handleKeyPress(.downArrow)
    #expect(controller.suggestions.highlightedIndex == 1)
    controller.handleKeyPress(.downArrow)
    #expect(controller.suggestions.highlightedIndex == 0, "wraps around")
    controller.handleKeyPress(.upArrow)
    controller.handleKeyPress(.return)
    let tony = AtomicNode(type: .mention, label: "tony", attributes: ["id": "u2"])
    #expect(controller.document.blocks == [paragraph(text("hi "), .node(tony), text(" "))])
    #expect(controller.selection == .caret(5))
    #expect(!controller.suggestions.isActive)
    // The trailing space is kept, as a character reference.
    #expect(controller.markdown == "hi :mention[tony]{#u2}&#32;")
    #expect(controller.schema.accessibilityLabel(tony) == "mention, tony")
  }

  @Test func queriesMatchCaseAndDiacriticsInsensitively() {
    let controller = ComposerController(plugins: [MentionsPlugin(source: .static(people))])
    type(controller, "@e")
    #expect(controller.suggestions.items.map(\.label) == ["Émile"])
    type(controller, "⌫⌫@an")
    #expect(controller.suggestions.items.map(\.label) == ["Ann"])
  }

  @Test func aTriggerOpensOnlyAtTheStartOfAWord() {
    let controller = ComposerController(plugins: [MentionsPlugin(source: .static(people))])
    type(controller, "mail a@to")
    #expect(!controller.suggestions.isActive)
    type(controller, " (@to")
    #expect(controller.suggestions.isActive)
    // A space ends the query.
    type(controller, " x")
    #expect(controller.suggestions.session == nil)
    // Moving the caret back into one reopens it.
    controller.selection = .caret(14)
    #expect(controller.suggestions.query == "to")
  }

  @Test func escapeDismissesUntilTheCaretLeaves() {
    let controller = ComposerController(plugins: [MentionsPlugin(source: .static(people))])
    type(controller, "@t")
    controller.handleKeyPress(.escape)
    #expect(!controller.suggestions.isActive)
    type(controller, "o")
    #expect(!controller.suggestions.isActive, "still dismissed")
    // ↩ falls through to a new block while dismissed.
    controller.handleKeyPress(.return)
    #expect(controller.document.blocks.count == 2)
    type(controller, "@t")
    #expect(controller.suggestions.isActive)
  }

  @Test func returnAndTabFallThroughWithNoItems() {
    let controller = ComposerController(plugins: [MentionsPlugin(source: .static(people))])
    type(controller, "@zz")
    #expect(controller.suggestions.phase == .empty)
    controller.handleKeyPress(.tab)
    #expect(controller.document.blocks == [paragraph(text("@zz\t"))])
  }

  @Test func suggestionsWinTheKeysInsideAList() {
    let controller = ComposerController(plugins: [
      PluginGroup.markdown, MentionsPlugin(source: .static(people)),
    ])
    type(controller, "- @tom")
    controller.handleKeyPress(.return)
    #expect(controller.markdown == "- :mention[tom]{#u1}&#32;")
  }

  @Test func asyncSourcesDebounceAndDropStaleQueries() async throws {
    let source = RecordingSource(items: people)
    let controller = ComposerController(plugins: [
      MentionsPlugin(source: source, debounce: .milliseconds(30))
    ])
    type(controller, "@t")
    #expect(controller.suggestions.phase == .loading)
    type(controller, "o")
    type(controller, "n")
    try await settle(controller)
    #expect(source.queries == ["ton"])
    #expect(controller.suggestions.items.map(\.label) == ["tony"])
    #expect(controller.suggestions.phase == .results)
  }

  @Test func hashtagsTurnIntoTokensOnABoundary() {
    let controller = ComposerController(plugins: [HashtagsPlugin()])
    type(controller, "#swift is #1 and a#b, #ok.")
    let tag = { (name: String) in Inline.node(AtomicNode(type: .hashtag, label: name)) }
    #expect(
      controller.document.blocks == [
        paragraph(tag("swift"), text(" is #1 and a#b, "), tag("ok"), text("."))
      ])
    // `a#b` stays text, so its `#` is escaped.
    #expect(controller.markdown == "#swift is #1 and a\\#b, #ok.")
    let codec = MarkdownCodec(schema: controller.schema)
    #expect(codec.parse("#swift and # no").blocks == [paragraph(tag("swift"), text(" and # no"))])
  }

  @Test func slashCommandsRunAtTheStartOfAParagraph() {
    let arguments = Box<[String]>([])
    let controller = ComposerController(plugins: [
      PluginGroup.markdown,
      SlashCommandsPlugin([
        SlashCommand("shrug") { _, _ in .replace("¯\\_(ツ)_/¯") },
        SlashCommand("giphy") { args, _ in
          arguments.value.withLock { $0.append(args) }
          return .perform
        },
      ]),
    ])
    type(controller, "/sh")
    #expect(controller.suggestions.items.map(\.label) == ["/shrug"])
    controller.handleKeyPress(.return)
    #expect(controller.document.blocks == [paragraph(text("¯\\_(ツ)_/¯"))])
    // Not mid-paragraph.
    type(controller, " /sh")
    #expect(!controller.suggestions.isActive)
    // Arguments after the name.
    controller.clear()
    type(controller, "/giphy cats\n")
    #expect(arguments.value.withLock { $0 } == ["cats"])
    #expect(controller.document.isEmpty)
    // The markdown plugins' commands.
    type(controller, "/qu\nx")
    #expect(controller.markdown == "> x")
    controller.clear()
    type(controller, "/li\ny")
    #expect(controller.markdown == "- y")
  }

  @Test func emojiShortcodesConvertAndSuggest() {
    let controller = ComposerController(plugins: [
      EmojiShortcodesPlugin(emoji: [
        Emoji("😄", shortcodes: ["smile"]), Emoji("😏", shortcodes: ["smirk"]),
      ])
    ])
    type(controller, "hi :smile: ")
    #expect(controller.document.blocks == [paragraph(text("hi 😄 "))])
    type(controller, ":s")
    #expect(!controller.suggestions.isActive, "two characters open it")
    type(controller, "m")
    #expect(controller.suggestions.items.map(\.label) == [":smile:", ":smirk:"])
    controller.handleKeyPress(.tab)
    #expect(controller.document.blocks == [paragraph(text("hi 😄 😄"))])
    // Times and unknown codes stay text.
    type(controller, " 12:30: :nope:")
    #expect(controller.document.blocks == [paragraph(text("hi 😄 😄 12:30: :nope:"))])
  }
}
