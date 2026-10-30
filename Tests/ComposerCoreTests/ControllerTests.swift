import ComposerCore
import Observation
import Synchronization
import Testing

/// Records calls from `@Sendable` closures.
final class Log: Sendable {
  private let entries = Mutex<[String]>([])
  func append(_ entry: String) { entries.withLock { $0.append(entry) } }
  var all: [String] { entries.withLock { $0 } }
}

struct Transforms: ComposerPlugin {
  var transforms: [NodeTransform]
  func register(in registry: inout PluginRegistry) {
    for transform in transforms { registry.addTransform(transform) }
  }
}

func plainText(_ document: Document) -> [String] {
  document.textBlocks.map { block in
    switch block.content {
    case .paragraph(let inlines):
      inlines.map { inline -> String in
        if case .text(let text, _) = inline { return text }
        return "◆"
      }.joined()
    case .code(_, let text): text
    }
  }
}

@MainActor @Suite struct TransformTests {
  @Test func transformsRunToAFixedPoint() {
    // `ab` → `c`, then `cc` → `d`, which needs a second pass, and the third
    // pass changes nothing.
    let controller = ComposerController(plugins: [
      Transforms(transforms: [
        replacing("ab", with: "c", name: "ab"), replacing("cc", with: "d", name: "cc"),
      ])
    ])
    let changeset = controller.update { $0.insert("xabab") }
    #expect(plainText(controller.document) == ["xd"])
    #expect(changeset.transformPasses == 3)
    #expect(!changeset.reachedTransformLimit)
    #expect(controller.selection == .caret(2))
  }

  @Test func aTransformThatNeverConvergesStopsAtTheLimit() {
    let controller = ComposerController(plugins: [
      Transforms(transforms: [
        NodeTransform("grow") { state, range in state.insert("!", at: Selection(range.upperBound)) }
      ])
    ])
    controller.maxTransformPasses = 5
    let changeset = controller.update { $0.insert("a") }
    #expect(changeset.reachedTransformLimit)
    #expect(changeset.transformPasses == 5)
    #expect(plainText(controller.document) == ["a!!!!!"])
  }

  @Test func onlyEditedBlocksAreVisited() {
    let log = Log()
    let controller = ComposerController(
      EditorState(
        document: Document(blocks: [
          paragraph(text("one q")), .quote([paragraph(text("two q"))]), paragraph(text("three q")),
        ])),
      plugins: [
        Transforms(transforms: [
          NodeTransform("log") { _, range in log.append("\(range)") },
          replacing("q", with: "Q", name: "q"),
        ])
      ])
    controller.update { $0.insert("q", at: .caret(11)) }
    // Only the second block: the first and third keep their `q`.
    #expect(plainText(controller.document) == ["one q", "two QQ", "three q"])
    #expect(log.all == ["6..<12", "6..<12", "6..<12"])
  }

  @Test func rangesFollowEditsInEarlierBlocks() {
    // Each visited block shrinks; the later block's range must follow.
    let controller = ComposerController(
      EditorState(document: Document(blocks: [paragraph(text("a")), paragraph(text("b"))])),
      plugins: [Transforms(transforms: [replacing("xx", with: "", name: "xx")])])
    controller.update { state in
      state.insert("xx", at: .caret(3))
      state.insert("xxxx", at: .caret(1))
    }
    #expect(plainText(controller.document) == ["a", "b"])
  }

  @Test func transformsWaitForMarkedText() {
    let controller = ComposerController(plugins: [UppercaseQ()])
    controller.update { state in
      state.insert("q")
      state.markedText = MarkedText(range: Position(0)..<Position(1))
    }
    #expect(plainText(controller.document) == ["q"])
    controller.update { $0.selection = .caret(0) }
    #expect(plainText(controller.document) == ["q"])
    // Committing the composition runs them on what was edited during it.
    let changeset = controller.update { $0.markedText = nil }
    #expect(plainText(controller.document) == ["Q"])
    #expect(changeset.transformPasses == 2)
  }

  @Test func anUpdateThatChangesNothingIsEmpty() {
    let controller = ComposerController(plugins: [UppercaseQ()])
    let before = controller.state
    let changeset = controller.update { $0.delete(Position(0)..<Position(0)) }
    #expect(changeset.isEmpty)
    #expect(controller.state == before)
  }

  @Test func consecutiveTypingIsOneEdit() {
    let controller = ComposerController()
    let changeset = controller.update { state in
      for character in "hello" { state.insert(String(character)) }
      state.delete(Position(4)..<Position(5))
    }
    #expect(changeset.edits == [.init(range: Position(0)..<Position(0), replacementLength: 4)])
  }

  @Test func replacingTheDocumentDirectlyIsOneEdit() {
    let controller = ComposerController(
      EditorState(document: Document(blocks: [paragraph(text("abc"))])))
    let changeset = controller.update { $0.document = Document(blocks: [paragraph(text("xy"))]) }
    #expect(changeset.edits == [.init(range: Position(0)..<Position(3), replacementLength: 2)])
    #expect(controller.selection == .caret(2))
  }
}

@MainActor @Suite struct CommandTests {
  nonisolated static let ping = Command<Void>("ping")

  @Test func handlersRunFromHighestPriority() {
    let log = Log()
    let controller = ComposerController()
    for (name, priority) in [("low", Priority.low), ("critical", .critical), ("normal", .normal)] {
      controller.register(Self.ping, priority: priority) { _, _ in
        log.append(name)
        return .unhandled
      }
    }
    #expect(!controller.run(Self.ping))
    #expect(log.all == ["critical", "normal", "low"])
  }

  @Test func theFirstHandledStopsPropagation() {
    let log = Log()
    let controller = ComposerController()
    controller.register(Self.ping, priority: .low) { _, _ in
      log.append("low")
      return .handled
    }
    let high = controller.register(Self.ping, priority: .high) { _, _ in
      log.append("high")
      return .handled
    }
    #expect(controller.run(Self.ping))
    #expect(log.all == ["high"])
    controller.unregister(high)
    #expect(controller.run(Self.ping))
    #expect(log.all == ["high", "low"])
  }

  @Test func laterRegistrationsWinTies() {
    let log = Log()
    let controller = ComposerController()
    for name in ["first", "second", "third"] {
      controller.register(Self.ping) { _, _ in
        log.append(name)
        return .unhandled
      }
    }
    controller.run(Self.ping)
    #expect(log.all == ["third", "second", "first"])
  }

  @Test func payloadsAreTyped() {
    let log = Log()
    let controller = ComposerController()
    controller.register(Command<Int>("set")) { value, _ in
      log.append("int \(value)")
      return .handled
    }
    controller.register(Command<String>("set"), priority: .low) { value, _ in
      log.append("string \(value)")
      return .handled
    }
    #expect(controller.run(Command<String>("set"), "x"))
    #expect(controller.run(Command<Int>("set"), 1))
    #expect(log.all == ["string x", "int 1"])
  }

  @Test func handlersCanUpdateAndRunCommands() {
    let controller = ComposerController()
    controller.register(.toggleBold) { _, controller in
      controller.update { $0.toggleMark(.bold, in: $0.selection.range) }
      return .handled
    }
    controller.register(Self.ping) { _, controller in
      controller.run(.toggleBold) ? .handled : .unhandled
    }
    controller.setDocument(Document(blocks: [paragraph(text("ab"))]))
    controller.selection = Selection(Position(0)..<Position(1))
    #expect(controller.run(Self.ping))
    #expect(controller.document.blocks == [paragraph(text("a", .bold), text("b"))])
  }

  @Test func registeringDuringARunTakesEffectNextRun() {
    let log = Log()
    let controller = ComposerController()
    controller.register(Self.ping, priority: .low) { _, controller in
      log.append("low")
      controller.register(Self.ping, priority: .high) { _, _ in
        log.append("added")
        return .handled
      }
      return .unhandled
    }
    controller.run(Self.ping)
    controller.run(Self.ping)
    #expect(log.all == ["low", "added"])
  }

  @Test func pluginsRegisterHandlersThroughTheBuilder() {
    struct Handler: ComposerPlugin {
      var name: String
      var priority: Priority
      var log: Log
      func register(in registry: inout PluginRegistry) {
        let (name, log) = (name, log)
        registry.register(CommandTests.ping, priority: priority) { _, _ in
          log.append(name)
          return .unhandled
        }
      }
    }
    let log = Log()
    let includeOptional = true
    let controller = ComposerController {
      Handler(name: "a", priority: .low, log: log)
      if includeOptional {
        Handler(name: "b", priority: .high, log: log)
      } else {
        Handler(name: "never", priority: .high, log: log)
      }
      for name in ["c", "d"] { Handler(name: name, priority: .normal, log: log) }
      PluginGroup([Handler(name: "e", priority: .critical, log: log)])
    }
    controller.run(Self.ping)
    #expect(log.all == ["e", "b", "d", "c", "a"])
  }
}

@MainActor @Suite struct KeymapTests {
  static let a = Command<Void>("a")
  static let b = Command<Void>("b")

  @Test func bindingsAreTriedInPriorityOrderUntilOneIsHandled() {
    let log = Log()
    let controller = ComposerController()
    controller.keymap.add(KeyBinding(.return, command: Self.a, priority: .low))
    controller.keymap.add(KeyBinding(.return, command: Self.b, priority: .high))
    controller.register(Self.a) { _, _ in
      log.append("a")
      return .handled
    }
    controller.register(Self.b) { _, _ in
      log.append("b")
      return .unhandled
    }
    #expect(controller.handleKey(.return))
    #expect(log.all == ["b", "a"])
    #expect(!controller.handleKey(.return, modifiers: .shift))
  }

  @Test func whenPredicatesSeeTheState() {
    let log = Log()
    let controller = ComposerController()
    controller.keymap.add(
      KeyBinding(.upArrow, command: Self.a, priority: .high) { $0.document.length == 0 })
    controller.keymap.add(KeyBinding(.upArrow, command: Self.b))
    for command in [Self.a, Self.b] {
      controller.register(command) { _, _ in
        log.append(command.name)
        return .handled
      }
    }
    controller.handleKey(.upArrow)
    controller.insert(.text("x"))
    controller.handleKey(.upArrow)
    #expect(log.all == ["a", "b"])
  }

  @Test func bindingsCanBeRemoved() {
    var keymap = Keymap([
      KeyBinding("b", modifiers: .command, command: .toggleBold),
      KeyBinding("X", modifiers: [.command, .shift], command: .toggleStrikethrough),
      KeyBinding(.return, command: .send),
    ])
    #expect(keymap.bindings(for: "x", modifiers: [.command, .shift], in: EditorState()).count == 1)
    keymap.remove(.toggleStrikethrough)
    keymap.remove("b", modifiers: .command)
    #expect(keymap.bindings.map(\.command.name) == ["send"])
  }
}

@MainActor @Suite struct ObservationTests {
  /// Calls `body`, and returns whether reading `read` was invalidated.
  func invalidates(_ read: @escaping () -> Void, _ body: () -> Void) -> Bool {
    let log = Log()
    withObservationTracking(read) { log.append("changed") }
    body()
    return !log.all.isEmpty
  }

  @Test func isEmptyIsObservedApartFromTheState() {
    let controller = ComposerController()
    #expect(controller.isEmpty)
    // The first character makes the document non-empty.
    #expect(invalidates({ _ = controller.isEmpty }) { controller.insertText("a") })
    #expect(!controller.isEmpty)
    // Further keystrokes and selection changes invalidate the state only.
    #expect(!invalidates({ _ = controller.isEmpty }) { controller.insertText("b") })
    #expect(!invalidates({ _ = controller.isEmpty }) { controller.selection = .caret(0) })
    #expect(invalidates({ _ = controller.state }) { controller.insertText("c") })
    // A new empty block after text is content too.
    #expect(!invalidates({ _ = controller.isEmpty }) { controller.handleKeyPress(.return) })
    #expect(invalidates({ _ = controller.isEmpty }) { controller.clear() })
    #expect(controller.isEmpty)
    // An empty list item shows, so it isn't empty.
    controller.setDocument(Document(blocks: [.list(.bullet, items: [ListItem(blocks: [])])]))
    #expect(!controller.isEmpty)
  }
}
