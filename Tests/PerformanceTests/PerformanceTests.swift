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
    /// Typing goes through `insertText`, as the input system delivers it.
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
      // The budget holds for the typical keystroke; the tail gets twice it,
      // for scheduling noise on shared CI machines.
      XCTAssertLessThan(median, .milliseconds(4), "median keystroke \(median)")
      XCTAssertLessThan(p95, .milliseconds(8), "p95 keystroke \(p95)")
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

    /// Where mount time goes (diagnostic).
    @MainActor func testMountBreakdown() {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let bounds = window.contentView!.bounds
      func median(_ name: String, _ body: () -> Void) {
        var samples: [Duration] = []
        for _ in 0..<25 { samples.append(ContinuousClock().measure(body)) }
        let (median, p95) = statistics(samples.dropFirst(5))
        report(name, median: median, p95: p95)
      }
      median("standard styles") { _ = TextStyles.standard }
      median("map chat document") {
        _ = AttributeMapper(styles: .standard).attributedString(for: document)
      }
      median("plain NSTextView, TextKit 2, laid out") {
        let view = NSTextView(usingTextLayoutManager: true)
        view.frame = bounds
        view.textStorage?.setAttributedString(
          AttributeMapper(styles: .standard).attributedString(for: document))
        window.contentView!.addSubview(view)
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        view.layoutSubtreeIfNeeded()
        view.removeFromSuperview()
      }
      median("composer view, empty, no window") {
        _ = ComposerTextView(controller: ComposerController(), frame: bounds)
      }
      let controller = ComposerController(EditorState(document: document))
      median("composer view, chat document, no window") {
        _ = ComposerTextView(controller: controller, frame: bounds)
      }
      median("composer view, chat document, laid out") {
        let view = ComposerTextView(controller: controller, frame: bounds)
        window.contentView!.addSubview(view)
        layOut(view)
        view.removeFromSuperview()
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
