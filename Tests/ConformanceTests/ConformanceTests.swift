// Scripted sessions against a real `UITextView` (iOS Simulator) and
// `NSTextView`. Apple-only.
#if canImport(UIKit) || canImport(AppKit)
  #if canImport(UIKit)
    import ComposerUIKit
    import UIKit
  #else
    import AppKit
    import ComposerAppKit
  #endif
  import ComposerCore
  import ComposerTesting
  import Testing

  /// Each session runs on the controller alone and on a real
  /// `ComposerTextView` (`UITextView` on iOS, `NSTextView` on macOS), and the
  /// two must agree after every step: the same `EditorState`, and text
  /// storage that matches a fresh rendering of the document.
  @MainActor @Suite(.serialized) struct NativeConformanceTests {
    func expectConformance(
      _ session: Session, from state: EditorState = EditorState(),
      plugins: [any ComposerPlugin] = [], sourceLocation: SourceLocation = #_sourceLocation
    ) {
      let reference = ControllerDriver(state, plugins: plugins)
      let engine = NativeDriver(state, plugins: plugins)
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
    @Test(arguments: 0..<24) func randomSessions(seed: Int) {
      var generator = SessionGenerator(seed: UInt64(seed))
      let state = EditorState(document: generator.document(), selection: .caret(0))
      expectConformance(generator.session(length: 40), from: state, plugins: [UppercaseQ()])
    }

    @Test func markdownRulesAgree() {
      expectConformance(
        Session {
          Type("**bold** and _it_ x")
          Type(" **y**")
          Press(.delete)
          Type("\n- a\nb")
          Press(.tab)
          Type("\n[ ] task")
          Press(.tab, modifiers: .shift)
          Type("\n\n> quote\n\n```swift\ncode\n\nafter [w](https://wevm.dev)")
          Select(caret: 0)
          Press(.delete)
        }, plugins: [PluginGroup.markdown])
    }

    /// Random typing over markdown syntax, with ⇥ and ⇧⇥.
    @Test(arguments: 0..<12) func randomMarkdownSessions(seed: Int) {
      var generator = SessionGenerator(seed: UInt64(seed) &+ 1_000)
      expectConformance(
        generator.markdownSession(length: 60), plugins: [PluginGroup.markdown])
    }

    /// Tokens draw as their labels, several characters for one unit: the
    /// caret steps over them whole, and selections grow to cover them.
    @Test func tokensAreOneUnitDrawnAsTheirLabel() throws {
      let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "1"])
      let state = EditorState(
        document: Document(blocks: [
          .paragraph([.text("a ", marks: Marks()), .node(mention), .text(" b", marks: Marks())])
        ]), selection: .caret(0))
      let plugins: [any ComposerPlugin] = [MentionsPlugin(source: .static(people))]
      expectConformance(
        Session {
          Press(.rightArrow)
          Press(.rightArrow)
          Press(.rightArrow)
          Type("x")
          Press(.leftArrow)
          Press(.leftArrow)
          Press(.rightArrow, modifiers: .shift)
          Press(.delete)
          Type("@to")
          Press(.return)
          Select(0..<4)
          Paste(.plainText("z"))
          Undo()
        }, from: state, plugins: plugins)
      let driver = NativeDriver(state, plugins: plugins)
      let storage: NSTextStorage? = driver.textView.textStorage
      #expect(try #require(storage).string == "a @tom b")
      #expect(driver.textView.storageMap.storage(4) == 7)
    }

    /// HTML, composer's own type, and files paste through the pasteboard as
    /// through the controller.
    @Test func richPastesConform() {
      let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "1"])
      expectConformance(
        Session {
          Paste(
            .html("<p><b>bold</b> and <a href=\"https://x.dev\">link</a></p><ul><li>a</li></ul>"))
          Paste(.document(Document(blocks: [.paragraph([.text("hi "), .node(mention)])])))
        },
        plugins: [
          PluginGroup.chatDefaults, RichPaste(), MentionsPlugin(source: .static(people)),
        ])
      // A file goes to the tray. (Not in the session: each side gives the
      // attachment its own random id.)
      let driver = NativeDriver(plugins: [AttachmentsPlugin { _, _ in }])
      driver.perform(.paste(.files([PastedFile(data: Data([1]), contentType: "public.png")])))
      #expect(driver.controller.attachments.count == 1)
      #expect(driver.controller.document.isEmpty)
    }

    /// Copying writes markdown, RTF, and composer's own type; pasting the
    /// pasteboard into another composer brings tokens through, and RTF alone
    /// maps to marks.
    @Test func copyAndPasteThroughThePasteboard() throws {
      let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "1"])
      let plugins: [any ComposerPlugin] = [
        PluginGroup.chatDefaults, RichPaste(), MentionsPlugin(source: .static(people)),
      ]
      let source = NativeDriver(
        EditorState(
          document: Document(blocks: [
            .paragraph([.text("a ", marks: .bold), .node(mention), .text(" b")])
          ])), plugins: plugins)
      let content = try #require(source.controller.clipboardContent(of: Position(0)..<Position(4)))
      #if canImport(UIKit)
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        source.textView.write(content, to: pasteboard)
        #expect(pasteboard.string == content.markdown)
        let rtf = try #require(pasteboard.data(forPasteboardType: "public.rtf"))
      #else
        let pasteboard = NSPasteboard(name: .init("dev.wevm.composer.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        source.textView.write(content, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == content.markdown)
        let rtf = try #require(pasteboard.data(forType: .rtf))
      #endif
      #expect(content.markdown == "**a** :mention[tom]{#1}&#32;")
      let target = NativeDriver(EditorState(), plugins: plugins)
      target.textView.paste(from: pasteboard)
      #expect(
        target.controller.document.blocks == [
          .paragraph([.text("a ", marks: .bold), .node(mention), .text(" ")])
        ])
      #expect(target.textView.renderingMismatch() == nil)
      // RTF alone: the bold survives as a mark, the token as its text.
      let rtfOnly = NativeDriver(EditorState(), plugins: plugins)
      #if canImport(UIKit)
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.setData(rtf, forPasteboardType: "public.rtf")
      #else
        let board = NSPasteboard(name: .init("dev.wevm.composer.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(rtf, forType: .rtf)
      #endif
      rtfOnly.textView.paste(from: board)
      #expect(rtfOnly.controller.markdown == "**a** @tom")
    }

    @Test func aTaskBoxTogglesItsItem() throws {
      let driver = NativeDriver(
        EditorState(document: MarkdownCodec().parse("- [ ] milk\n- [x] eggs")),
        plugins: [PluginGroup.markdown])
      let layout = try #require(driver.textView.textLayoutManager)
      var first: NSTextLayoutFragment?
      layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        first = fragment
        return false
      }
      let fragment = try #require(first)
      let line = try #require(fragment.textLineFragments.first)
      let textStart = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
      let y = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY
      #expect(layout.taskBox(at: CGPoint(x: textStart + 4, y: y)) == nil, "on the text")
      let box = try #require(layout.taskBox(at: CGPoint(x: textStart - 8, y: y)))
      #expect(box == 0)
      #if canImport(AppKit) && !canImport(UIKit)
        // A click there, as AppKit delivers it.
        let origin = driver.textView.textContainerOrigin
        let point = driver.textView.convert(
          CGPoint(x: textStart - 8 + origin.x, y: y + origin.y), to: nil)
        let event = try #require(
          NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: driver.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
        driver.textView.mouseDown(with: event)
      #else
        driver.controller.run(Command<Position>.toggleTask, Position(box))
      #endif
      #expect(driver.controller.markdown == "- [x] milk\n- [x] eggs")
    }

    /// Hit testing finds the token or link under a point, by the rects the
    /// text draws them in; a read-only content view reports taps on them.
    @Test func hoverTargetsAreWhatIsDrawnAtThePoint() throws {
      let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "1"])
      let document = Document(blocks: [
        .paragraph([
          .text("hi "), .node(mention), .text(" see "),
          .text("site", marks: .link("https://x.dev")), .text(" end"),
        ])
      ])
      let schema = Schema(plugins: [MentionsPlugin(source: .static(people))])
      let view = ComposerContentView(document: document, schema: schema)
      #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.addSubview(view)
        window.isHidden = false
        defer { window.isHidden = true }
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutIfNeeded()
      #else
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView?.addSubview(view)
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        view.layoutSubtreeIfNeeded()
      #endif
      let tokenRect = view.rect(for: Position(3)..<Position(4))
      #expect(tokenRect.width > 10, "the token draws as its label")
      let token = try #require(view.hoverTarget(at: CGPoint(x: tokenRect.midX, y: tokenRect.midY)))
      #expect(token.kind == .node(mention))
      #expect(token.range == Position(3)..<Position(4))
      let linkRect = view.rect(for: Position(9)..<Position(13))
      let link = try #require(view.hoverTarget(at: CGPoint(x: linkRect.midX, y: linkRect.midY)))
      #expect(link.kind == .link("https://x.dev"))
      let plain = view.rect(for: Position(0)..<Position(2))
      #expect(view.hoverTarget(at: CGPoint(x: plain.midX, y: plain.midY)) == nil)
      #expect(view.hoverTarget(at: CGPoint(x: 310, y: tokenRect.midY)) == nil, "past the end")
      #expect(!view.isEditable)
      #expect(view.fittingHeight > 0)
      #if canImport(AppKit) && !canImport(UIKit)
        var tapped: AtomicNode?
        view.onTapNode = { tapped = $0 }
        let point = view.convert(CGPoint(x: tokenRect.midX, y: tokenRect.midY), to: nil)
        let event = try #require(
          NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: 1))
        view.mouseDown(with: event)
        #expect(tapped == mention)
      #endif
    }

    #if canImport(AppKit) && !canImport(UIKit)
      /// Without `composerUndoManager`, undo registers with the window's
      /// manager, so the window's Undo (⌘Z in the Edit menu) undoes a cut.
      @Test func undoUsesTheWindowsUndoManagerByDefault() {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.undoManager?.groupsByEvent = false
        let textView = ComposerTextView(controller: ComposerController(), frame: window.frame)
        window.contentView?.addSubview(textView)
        textView.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.selectAll(nil)
        textView.cut(nil)
        #expect(textView.controller.markdown == "")
        let undo = Selector(("undo:"))
        #expect(
          window.validateUserInterfaceItem(NSMenuItem(title: "", action: undo, keyEquivalent: "")))
        window.tryToPerform(undo, with: nil)
        #expect(textView.controller.markdown == "hello")
      }
    #endif

    #if canImport(AppKit) && !canImport(UIKit)
      /// The placeholder draws exactly where typed text would, so the caret
      /// sits before it, and clicks on it reach the text view.
      @Test func thePlaceholderDrawsAsTextWouldAndTakesNoClicks() {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let empty = ComposerTextView(
          controller: ComposerController(), frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        empty.placeholder = "Message"
        let typed = ComposerTextView(
          controller: ComposerController(), frame: NSRect(x: 0, y: 30, width: 300, height: 30))
        // In the placeholder's color, so both antialias alike at 1×.
        typed.textStyles.foreground = .placeholderTextColor
        typed.insertText("Message", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.contentView?.addSubview(empty)
        window.contentView?.addSubview(typed)
        /// The bounds of the drawn pixels, in pixels.
        func ink(_ view: NSView) -> [Int] {
          guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
          view.cacheDisplay(in: view.bounds, to: rep)
          var bounds = [Int.max, Int.max, -1, -1]
          for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
              bounds = [min(bounds[0], x), min(bounds[1], y), max(bounds[2], x), max(bounds[3], y)]
            }
          }
          return bounds
        }
        #expect(ink(empty) == ink(typed))
        let point = empty.convert(NSPoint(x: 20, y: 15), to: empty.superview)
        #expect(empty.hitTest(point) === empty)
      }
    #endif

    #if canImport(AppKit) && !canImport(UIKit)
      /// Undoing a list item back to an empty composer leaves the caret where
      /// an empty composer's is, not at the item's indent.
      @Test func undoingToEmptyPutsTheCaretAtTheStart() {
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.undoManager?.groupsByEvent = false
        let textView = ComposerTextView(
          controller: ComposerController { PluginGroup.chatDefaults },
          frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        func caretX() -> CGFloat {
          var actual = NSRange()
          let rect = textView.firstRect(
            forCharacterRange: textView.selectedRange(), actualRange: &actual)
          return window.convertFromScreen(rect).minX
        }
        let empty = caretX()
        for character in "- a" {
          textView.insertText(
            String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        while window.undoManager?.canUndo == true { window.undoManager?.undo() }
        #expect(textView.controller.markdown == "")
        #expect(caretX() == empty)
      }
    #endif

    @Test func theTextViewAppliesOnlyTheEditedSpan() throws {
      // "one" 0..<3, the separator, "two" 4..<7, and the caret at the end.
      let driver = NativeDriver(EditorState(document: MarkdownCodec().parse("one\n\ntwo")))
      let textStorage: NSTextStorage? = driver.textView.textStorage
      let storage = try #require(textStorage)
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

  #if canImport(UIKit)
    typealias EditActions = NSTextStorage.EditActions
  #else
    typealias EditActions = NSTextStorageEditActions
  #endif

  /// Records the character ranges a text storage edits.
  final class EditRecorder: NSObject, NSTextStorageDelegate {
    var edits: [NSRange] = []

    func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: EditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      if editedMask.contains(.editedCharacters) { edits.append(editedRange) }
    }
  }

  let people = [Suggestion(id: "1", label: "tom"), Suggestion(id: "2", label: "tony")]

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
          pick([ListKind.bullet, .ordered(start: 3)]),
          items: (0..<next(3) + 1).map { _ in
            ListItem(checked: pick([Bool?.none, true, false]), blocks: [block(depth: depth + 1)])
          })
      default: return .paragraph(inlines())
      }
    }

    mutating func document() -> Document {
      Document(blocks: (0..<next(4) + 1).map { _ in block(depth: 0) }).normalized()
    }

    mutating func markdownSession(length: Int) -> Session {
      var steps: [Step] = []
      for _ in 0..<length {
        switch next(14) {
        case 0: steps.append(.press(.tab, pick([KeyModifiers(), .shift])))
        case 1: steps.append(.press(.delete, []))
        case 2: steps.append(.press(.return, []))
        case 3: steps.append(.press(pick([Key.leftArrow, .rightArrow]), []))
        case 4: steps.append(.undo)
        default:
          steps.append(
            .type(
              pick(["**", "*", "_", "`", "~~", "- ", "1. ", "> ", "[ ] ", "a", "b ", "```", "x"])))
        }
      }
      return Session(steps: steps)
    }

    mutating func session(length: Int) -> Session {
      var steps: [Step] = []
      var lengthEstimate = 40
      for _ in 0..<length {
        switch next(12) {
        case 0, 1: steps.append(.type(text()))
        case 2: steps.append(.marked(["k", "か"], committing: pick([String?("火"), nil])))
        case 3: steps.append(.press(.delete, []))
        case 4: steps.append(.press(.forwardDelete, []))
        case 5: steps.append(.press(.return, pick([KeyModifiers(), .shift])))
        case 6:
          steps.append(.press(pick([Key.leftArrow, .rightArrow]), pick([KeyModifiers(), .shift])))
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
