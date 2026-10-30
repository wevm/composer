// The performance budgets (DESIGN.md, Performance), measured against the
// native text views. XCTest, as the design asks for performance tests.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import ComposerAppKit
  import ComposerCore
  import ComposerTesting
  import XCTest

  final class AppKitPerformanceTests: XCTestCase {
    /// A chat-sized document: about 2,000 characters of mixed blocks.
    static let chatMarkdown: String = {
      let paragraph =
        "Some **bold** words, _italic_ ones, `code`, and a [link](https://wevm.dev) in a "
        + "message that runs long enough to wrap across a few lines."
      let sections = [
        paragraph, "> " + paragraph, "- " + paragraph + "\n- [ ] " + paragraph,
        "```\nlet x = 1\nlet y = 2\n```", paragraph, "1. " + paragraph + "\n2. " + paragraph,
        paragraph, paragraph,
      ]
      return (sections + sections).joined(separator: "\n\n")
    }()

    /// Main-thread work per keystroke: the update, transforms, the
    /// changeset applied to text storage, and layout of the viewport.
    @MainActor func testKeystrokeIsUnder4Milliseconds() {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      XCTAssertGreaterThan(document.length, 1_800)
      let driver = AppKitDriver(EditorState(document: document))
      let textView = driver.textView
      layOut(textView)
      // Typing in the middle of a paragraph, the common case.
      textView.setSelectedRange(NSRange(location: document.length / 2, length: 0))
      let noRange = NSRange(location: NSNotFound, length: 0)
      var samples: [Duration] = []
      for index in 0..<300 {
        let character = index % 10 == 9 ? " " : "a"
        samples.append(
          ContinuousClock().measure {
            textView.insertText(character, replacementRange: noRange)
            layOut(textView)
          })
      }
      let (median, p95) = statistics(samples.dropFirst(20))
      report("keystroke", median: median, p95: p95)
      XCTAssertLessThan(p95, .milliseconds(4), "p95 keystroke \(p95)")
    }

    /// A 20,000-character paste into a chat-sized document, through layout
    /// of the viewport. "No visible hitch" is taken as within 100 ms, the
    /// limit for a response to feel immediate (see DESIGN.md).
    @MainActor func testPasteOf20kCharactersHasNoHitch() {
      let line = "A pasted line of plain text, about sixty characters long ok.\n"
      let pasted = String(repeating: line, count: 20_000 / line.count + 1).prefix(20_000)
      var samples: [Duration] = []
      for _ in 0..<6 {
        let driver = AppKitDriver(
          EditorState(document: MarkdownCodec().parse(Self.chatMarkdown)))
        layOut(driver.textView)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString(String(pasted), forType: .string)
        samples.append(
          ContinuousClock().measure {
            driver.textView.paste(from: pasteboard)
            layOut(driver.textView)
          })
        pasteboard.releaseGlobally()
        XCTAssertGreaterThan(driver.controller.document.length, 21_000)
      }
      let (median, p95) = statistics(samples.dropFirst())
      report("paste 20k", median: median, p95: p95)
      XCTAssertLessThan(median, .milliseconds(100), "median paste \(median)")
    }

    /// Creating a text view for a chat-sized document, through its first
    /// layout in a window.
    @MainActor func testMountIsUnder5Milliseconds() {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      var samples: [Duration] = []
      for _ in 0..<30 {
        let controller = ComposerController(EditorState(document: document))
        var textView: ComposerTextView?
        samples.append(
          ContinuousClock().measure {
            let view = ComposerTextView(
              controller: controller, frame: window.contentView!.bounds)
            window.contentView!.addSubview(view)
            layOut(view)
            textView = view
          })
        textView?.removeFromSuperview()
      }
      let (median, p95) = statistics(samples.dropFirst(5))
      report("mount", median: median, p95: p95)
      XCTAssertLessThan(median, .milliseconds(5), "median mount \(median)")
    }

    /// Where a 20k paste's time goes (diagnostic).
    @MainActor func testPasteBreakdown() {
      let line = "A pasted line of plain text, about sixty characters long ok.\n"
      let pasted = String(String(repeating: line, count: 20_000 / line.count + 1).prefix(20_000))
      let clock = ContinuousClock()
      func time(_ name: String, _ body: () -> Void) {
        report(name, median: clock.measure(body), p95: .zero)
      }
      let mapper = AttributeMapper(styles: .standard)
      let lines = Document(blocks: [.paragraph([.text(pasted)])])
      let blocks = MarkdownCodec().parse(pasted.replacingOccurrences(of: "\n", with: "\n\n"))
      time("map one 20k paragraph") { _ = mapper.attributedString(for: lines) }
      time("map 334 paragraphs") { _ = mapper.attributedString(for: blocks) }
      for (name, document) in [("one paragraph", lines), ("334 paragraphs", blocks)] {
        let driver = AppKitDriver(EditorState(document: Document.empty))
        layOut(driver.textView)
        time("setDocument, \(name)") { driver.controller.setDocument(document) }
        time("layout, \(name)") { layOut(driver.textView) }
        time("type at end, \(name)") {
          driver.textView.insertText(
            "a", replacementRange: NSRange(location: NSNotFound, length: 0))
          layOut(driver.textView)
        }
      }
      let storage = NSTextStorage()
      time("bare storage replace 20k") {
        storage.replaceCharacters(in: NSRange(), with: mapper.attributedString(for: lines))
      }
    }

    // MARK: Helpers

    @MainActor private func layOut(_ textView: ComposerTextView) {
      textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      textView.layoutSubtreeIfNeeded()
    }

    private func statistics(_ samples: some Collection<Duration>) -> (Duration, Duration) {
      let sorted = samples.sorted()
      return (sorted[sorted.count / 2], sorted[min(sorted.count * 95 / 100, sorted.count - 1)])
    }

    private func report(_ name: String, median: Duration, p95: Duration) {
      func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let value = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return String(format: "%.3f ms", value)
      }
      print("[performance] \(name): median \(milliseconds(median)), p95 \(milliseconds(p95))")
    }
  }
#endif
