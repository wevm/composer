// Scripted sessions against a real `UITextView` (iOS Simulator) and
// `NSTextView`. Apple-only.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import ComposerAppKit
  import ComposerCore
  import ComposerTesting
  import Testing

  /// Each session runs on the controller alone and on a real
  /// `ComposerTextView`, and the two must agree after every step: the same
  /// `EditorState`, and text storage that matches a fresh rendering of the
  /// document.
  @MainActor @Suite(.serialized) struct AppKitConformanceTests {
    func expectConformance(
      _ session: Session, from state: EditorState = EditorState(),
      plugins: [any ComposerPlugin] = [], sourceLocation: SourceLocation = #_sourceLocation
    ) {
      let reference = ControllerDriver(state, plugins: plugins)
      let engine = AppKitDriver(state, plugins: plugins)
      if let divergence = firstDivergence(of: session, reference: reference, engine: engine) {
        Issue.record("\(divergence)", sourceLocation: sourceLocation)
      }
    }

    @Test func theDesignExample() {
      expectConformance(
        Session {
          Type("hello **wor")
          Marked("l", "ld", committing: "ld")
          Type("**")
          Press(.return, modifiers: .shift)
          Paste(.plainText("https://wevm.dev"))
        })
    }

    @Test func returnSplitsBlocksAndDeleteJoinsThem() {
      expectConformance(
        Session {
          Type("one")
          Press(.return)
          Type("two")
          Press(.return, modifiers: .shift)
          Type("three")
          Select(caret: 3)
          Press(.forwardDelete)
          Press(.delete)
          Press(.delete)
          Press(.return)
          Press(.return)
          Press(.tab)
        })
    }

    @Test func compositionsStageCommitAndCancel() {
      expectConformance(
        Session {
          Type("a")
          Marked("に", "にほ", "にほん", committing: "日本")
          Type(" ")
          // Left open, then committed by moving the caret away.
          Marked("k", "か", committing: nil)
          Select(caret: 0)
          // Composing over a selection replaces it.
          Select(1..<3)
          Marked("e", committing: "é")
          // An emptied composition removes itself.
          Marked("x", "", committing: nil)
          Undo()
          Undo()
          Redo()
        })
    }

    @Test func deletionTakesWholeGraphemesAndNodes() {
      let document = Document(blocks: [
        .paragraph([
          .text("a👍🏽"), .node(AtomicNode(type: "mention", label: "Tom")), .text("é🇺🇸b"),
        ]),
        .paragraph([.text("next")]),
      ])
      expectConformance(
        Session {
          Select(caret: 6)
          Press(.delete)
          Press(.delete)
          Press(.forwardDelete)
          Press(.forwardDelete)
          Press(.forwardDelete)
          Press(.forwardDelete)
          Press(.delete)
        }, from: EditorState(document: document))
    }

    @Test func arrowsMoveLikeTheReference() {
      let document = Document(blocks: [
        .paragraph([.text("a👍🏽"), .node(AtomicNode(type: "mention", label: "Tom")), .text("b")]),
        .codeBlock(language: nil, text: "x\ny"),
      ])
      expectConformance(
        Session {
          Select(caret: 0)
          for _ in 0..<9 { Press(.rightArrow) }
          Press(.leftArrow, modifiers: .shift)
          Press(.leftArrow, modifiers: .shift)
          Press(.leftArrow, modifiers: .shift)
          Press(.leftArrow)
          Press(.rightArrow, modifiers: .shift)
          Press(.rightArrow)
          for _ in 0..<9 { Press(.leftArrow) }
        }, from: EditorState(document: document))
    }

    @Test func pasteNormalizesLineEndingsAndReplacesTheSelection() {
      expectConformance(
        Session {
          Type("start end")
          Select(6..<9)
          Paste(.plainText("one\r\ntwo\rthree\n"))
          Paste(.plainText(""))
          Undo()
          Redo()
        })
    }

    @Test func undoGroupsTypingAndRedoReplaysIt() {
      expectConformance(
        Session {
          Type("abc")
          Select(caret: 1)
          Type("X")
          Press(.return)
          Type("yz")
          Undo()
          Undo()
          Undo()
          Redo()
          Redo()
          Type("!")
          Redo()
          Undo()
          Undo()
          Undo()
          Undo()
        })
    }

    @Test func editsInsideContainersKeepTheirStyles() {
      let document = MarkdownCodec().parse(
        """
        > quoted **bold** text
        > second line

        1. first
        2. second
           - nested
           - [x] done

        ```swift
        let x = 1
        ```

        after
        """)
      expectConformance(
        Session {
          // Into the quote, then split it: "quoted new " | "bold text…".
          Select(caret: 7)
          Type("new ")
          Press(.return)
          // Join the second item into the first, which renumbers the list,
          // then split it again.
          Select(caret: 40)
          Press(.delete)
          Press(.return)
          // A line break inside the code block.
          Select(caret: 64)
          Press(.return, modifiers: .shift)
          Type("y")
          // Delete across the nested list, the code block, and the paragraph.
          Select(50..<72)
          Press(.delete)
          Undo()
        }, from: EditorState(document: document))
    }

    @Test func transformsRunOnInputFromTheTextView() {
      expectConformance(
        Session {
          Type("aqb")
          Marked("q", committing: nil)
          Type("q")
          Paste(.plainText("qq"))
          Undo()
        }, plugins: [UppercaseQ()])
    }

    @Test func keymapCommandsWinOverDefaults() {
      expectConformance(
        Session {
          Type("hello")
          Select(0..<5)
          Press("b", modifiers: .command)
          Press(.return)
          Type("x")
          Press(.tab)
        }, plugins: [BoldAndReturn()])
    }

    /// Random sessions on random documents: every step must agree.
    @Test(arguments: 0..<24) func randomSessions(seed: UInt64) {
      var generator = SessionGenerator(seed: seed)
      let state = EditorState(document: generator.document(), selection: .caret(0))
      expectConformance(generator.session(length: 40), from: state, plugins: [UppercaseQ()])
    }

    @Test func theTextViewAppliesOnlyTheEditedSpan() throws {
      // "one" 0..<3, the separator, "two" 4..<7, and the caret at the end.
      let driver = AppKitDriver(EditorState(document: MarkdownCodec().parse("one\n\ntwo")))
      let storage = try #require(driver.textView.textStorage)
      let recorder = EditRecorder()
      storage.delegate = recorder
      driver.run(Session { Type("!") })
      #expect(recorder.edits == [NSRange(location: 7, length: 1)])
      recorder.edits = []
      driver.run(
        Session {
          Select(caret: 1); Type("?")
        })
      #expect(recorder.edits == [NSRange(location: 1, length: 1)])
    }
  }

  /// Records the character ranges a text storage edits.
  final class EditRecorder: NSObject, NSTextStorageDelegate {
    var edits: [NSRange] = []

    func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      if editedMask.contains(.editedCharacters) { edits.append(editedRange) }
    }
  }

  /// Uppercases `q`, so sessions see transforms run.
  struct UppercaseQ: ComposerPlugin {
    func register(in registry: inout PluginRegistry) {
      registry.addTransform("uppercaseQ") { state, range in
        guard let block = state.document.textBlock(containing: range.lowerBound),
          case .paragraph(let inlines) = block.content
        else { return }
        var offset = block.range.lowerBound.offset
        for inline in inlines {
          if case .text(let text, _) = inline, let index = Array(text.utf16).firstIndex(of: 0x71) {
            let lower = Position(offset + index)
            state.replace(lower..<Position(lower.offset + 1), with: [.text("Q")])
            return
          }
          offset += inline.length
        }
      }
    }
  }

  /// ⌘B toggles bold, and ↩ inserts "⏎" instead of splitting the block.
  struct BoldAndReturn: ComposerPlugin {
    static let insertMarker = Command<Void>(name: "insertMarker")

    func register(in registry: inout PluginRegistry) {
      registry.addKeyBinding(KeyBinding("b", modifiers: .command, command: .toggleBold))
      registry.addKeyBinding(KeyBinding(.return, command: Self.insertMarker))
      registry.register(.toggleBold) { _, controller in
        controller.update { $0.toggleMark(.bold, in: $0.selection.range) }
        return .handled
      }
      registry.register(Self.insertMarker) { _, controller in
        controller.insertText("⏎")
        return .handled
      }
    }
  }

  /// Seeded random documents and sessions.
  struct SessionGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x51ED }

    mutating func next(_ bound: Int) -> Int {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((z ^ (z >> 31)) % UInt64(bound))
    }

    mutating func pick<T>(_ options: [T]) -> T { options[next(options.count)] }

    mutating func text() -> String {
      String((0..<next(6) + 1).map { _ in pick(Array("abq é👍🏽🇺🇸\n")) })
    }

    mutating func inlines() -> [Inline] {
      (0..<next(3) + 1).map { _ in
        next(5) == 0
          ? .node(AtomicNode(type: "mention", label: "Ann"))
          : .text(text(), marks: pick([Marks(), .bold, .italic, .code, .link("https://x.dev")]))
      }
    }

    mutating func block(depth: Int) -> Block {
      switch depth < 2 ? next(6) : 0 {
      case 1: return .codeBlock(language: nil, text: text())
      case 2: return .quote([block(depth: depth + 1), block(depth: depth + 1)])
      case 3:
        return .list(
          pick([.bullet, .ordered(start: 3)]),
          items: (0..<next(3) + 1).map { _ in
            ListItem(checked: pick([nil, true, false]), blocks: [block(depth: depth + 1)])
          })
      default: return .paragraph(inlines())
      }
    }

    mutating func document() -> Document {
      Document(blocks: (0..<next(4) + 1).map { _ in block(depth: 0) }).normalized()
    }

    mutating func session(length: Int) -> Session {
      var steps: [Step] = []
      var lengthEstimate = 40
      for _ in 0..<length {
        switch next(12) {
        case 0, 1: steps.append(.type(text()))
        case 2: steps.append(.marked(["k", "か"], committing: pick(["火", nil])))
        case 3: steps.append(.press(.delete, []))
        case 4: steps.append(.press(.forwardDelete, []))
        case 5: steps.append(.press(.return, pick([[], [.shift]])))
        case 6: steps.append(.press(pick([.leftArrow, .rightArrow]), pick([[], [.shift]])))
        case 7: steps.append(.paste(.plainText(text() + "\n" + text())))
        case 8:
          let lower = next(lengthEstimate)
          steps.append(.select(Position(lower)..<Position(lower + next(6))))
        case 9: steps.append(.undo)
        case 10: steps.append(.redo)
        default: steps.append(.type(pick(["q", " ", "x"])))
        }
        lengthEstimate += 2
      }
      return Session(steps: steps)
    }
  }
#endif
