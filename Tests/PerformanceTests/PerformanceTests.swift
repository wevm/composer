// The performance budgets (DESIGN.md, Performance), measured against the
// native text views: `NSTextView` on macOS, `UITextView` on the iOS
// Simulator. XCTest, as the design asks for performance tests.
#if canImport(UIKit) || canImport(AppKit)
  #if canImport(UIKit)
    import ComposerUIKit
    import UIKit

    typealias PlatformTextView = UITextView
  #else
    import AppKit
    import ComposerAppKit

    typealias PlatformTextView = NSTextView
  #endif
  import ComposerCore
  import ComposerTesting
  import XCTest

  final class PerformanceTests: XCTestCase {
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
    /// Typing goes through the text input methods, as the keyboard or input
    /// system delivers it.
    @MainActor func testKeystrokeIsUnder4Milliseconds() {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      XCTAssertGreaterThan(document.length, 1_800)
      let driver = NativeDriver(EditorState(document: document))
      layOut(driver.textView)
      // Typing in the middle of a paragraph, the common case.
      driver.perform(.select(Position(document.length / 2)..<Position(document.length / 2)))
      var samples: [Duration] = []
      for index in 0..<300 {
        let step = Step.type(index % 10 == 9 ? " " : "a")
        samples.append(
          ContinuousClock().measure {
            driver.perform(step)
            layOut(driver.textView)
          })
      }
      let (median, p95) = statistics(samples.dropFirst(20))
      report("keystroke", median: median, p95: p95)
      reportPlainKeystroke(document)
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
      let pasted = String(String(repeating: line, count: 20_000 / line.count + 1).prefix(20_000))
      var samples: [Duration] = []
      for _ in 0..<6 {
        let driver = NativeDriver(
          EditorState(document: MarkdownCodec().parse(Self.chatMarkdown)))
        layOut(driver.textView)
        samples.append(
          ContinuousClock().measure {
            driver.perform(.paste(.plainText(pasted)))
            layOut(driver.textView)
          })
        XCTAssertGreaterThan(driver.controller.document.length, 21_000)
      }
      let (median, p95) = statistics(samples.dropFirst())
      report("paste 20k", median: median, p95: p95)
      XCTAssertLessThan(median, .milliseconds(100), "median paste \(median)")
    }

    /// Creating a composer and laying it out in a window, as a chat screen
    /// mounts its input: empty, and restoring a short draft.
    @MainActor func testMountIsUnder5Milliseconds() {
      let draft = MarkdownCodec().parse(
        "Restoring a **draft** with a [link](https://wevm.dev) and `code`, about the length "
          + "of a typical message, which wraps onto a second line.")
      for (name, document) in [("empty", Document.empty), ("draft", draft)] {
        let median = mountTime(name: "mount, \(name)") {
          ComposerTextView(
            controller: ComposerController(EditorState(document: document)), frame: $0)
        }
        XCTAssertLessThan(median, .milliseconds(5), "median mount (\(name)) \(median)")
      }
    }

    /// With a 2k-character document, layout dominates mounting, and a plain
    /// TextKit 2 text view showing the same text is the floor: the composer
    /// must stay near it. The two are measured interleaved, so a slow patch
    /// on a shared CI machine hits both, and the composer also maps the
    /// document, which the plain view gets for free.
    @MainActor func testMountOfAChatSizedDocumentStaysNearTextKit() {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      let text = AttributeMapper(styles: .standard).attributedString(for: document)
      let (plain, composer) = mountTimes(
        { frame in
          let view = PlatformTextView(usingTextLayoutManager: true)
          view.frame = frame
          #if canImport(UIKit)
            view.attributedText = text
          #else
            view.textStorage?.setAttributedString(text)
          #endif
          return view
        },
        {
          ComposerTextView(
            controller: ComposerController(EditorState(document: document)), frame: $0)
        })
      report("mount 2k, plain text view", median: plain.median, p95: plain.p95)
      report("mount 2k, composer", median: composer.median, p95: composer.p95)
      XCTAssertLessThan(
        composer.median, plain.median * 1.5 + .milliseconds(2),
        "composer \(composer.median), plain \(plain.median)")
    }

    // MARK: Helpers

    /// A keystroke into a plain TextKit 2 text view showing the same text,
    /// for comparison (diagnostic).
    @MainActor private func reportPlainKeystroke(_ document: Document) {
      let text = AttributeMapper(styles: .standard).attributedString(for: document)
      let view = PlatformTextView(usingTextLayoutManager: true)
      #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        window.isHidden = false
        defer { window.isHidden = true }
        view.frame = window.bounds
        window.addSubview(view)
        view.attributedText = text
        view.selectedRange = NSRange(location: document.length / 2, length: 0)
      #else
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = window.contentView!.bounds
        window.contentView!.addSubview(view)
        view.textStorage?.setAttributedString(text)
        view.setSelectedRange(NSRange(location: document.length / 2, length: 0))
      #endif
      layOut(view)
      var samples: [Duration] = []
      for index in 0..<300 {
        let character = index % 10 == 9 ? " " : "a"
        samples.append(
          ContinuousClock().measure {
            #if canImport(UIKit)
              view.insertText(character)
            #else
              view.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            #endif
            layOut(view)
          })
      }
      let (median, p95) = statistics(samples.dropFirst(20))
      report("keystroke, plain text view", median: median, p95: p95)
    }

    /// The median time to create a view, add it to a window, and lay out
    /// its viewport, after warm-up.
    @MainActor private func mountTime(
      name: String, _ make: (CGRect) -> PlatformTextView
    ) -> Duration {
      let (time, _) = mountTimes(make, make)
      report(name, median: time.median, p95: time.p95)
      return time.median
    }

    /// The mount times of two kinds of view, measured alternately.
    @MainActor private func mountTimes(
      _ first: (CGRect) -> PlatformTextView, _ second: (CGRect) -> PlatformTextView
    ) -> ((median: Duration, p95: Duration), (median: Duration, p95: Duration)) {
      #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 320))
        window.isHidden = false
        defer { window.isHidden = true }
        let container: UIView = window
      #else
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container: NSView = window.contentView!
      #endif
      func mount(_ make: (CGRect) -> PlatformTextView) -> Duration {
        var mounted: PlatformTextView?
        let time = ContinuousClock().measure {
          let view = make(container.bounds)
          container.addSubview(view)
          layOut(view)
          mounted = view
        }
        mounted?.removeFromSuperview()
        return time
      }
      var firstSamples: [Duration] = []
      var secondSamples: [Duration] = []
      for _ in 0..<30 {
        firstSamples.append(mount(first))
        secondSamples.append(mount(second))
      }
      return (statistics(firstSamples.dropFirst(5)), statistics(secondSamples.dropFirst(5)))
    }

    @MainActor private func layOut(_ textView: PlatformTextView) {
      textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      #if canImport(UIKit)
        textView.layoutIfNeeded()
      #else
        textView.layoutSubtreeIfNeeded()
      #endif
    }

    private func statistics(
      _ samples: some Collection<Duration>
    ) -> (median: Duration, p95: Duration) {
      let sorted = samples.sorted()
      return (sorted[sorted.count / 2], sorted[min(sorted.count * 95 / 100, sorted.count - 1)])
    }

    private func report(_ name: String, median: Duration, p95: Duration) {
      func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        let value = Double(seconds) * 1_000 + Double(attoseconds) / 1e15
        return String(format: "%.3f ms", value)
      }
      #if canImport(UIKit)
        let platform = "iOS"
      #else
        let platform = "macOS"
      #endif
      print(
        "[performance] \(platform) \(name): median \(milliseconds(median)), "
          + "p95 \(milliseconds(p95))")
    }
  }
#endif
