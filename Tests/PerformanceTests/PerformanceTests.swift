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

  /// A plain TextKit 2 text view in a window, the floor the composer is
  /// compared with.
  @MainActor final class PlainTextView {
    let view = PlatformTextView(usingTextLayoutManager: true)
    #if canImport(UIKit)
      private var window: UIWindow?
    #else
      private var window: NSWindow?
    #endif

    /// A view showing `text`, not yet in a window.
    init(_ text: NSAttributedString, frame: CGRect) {
      view.frame = frame
      #if canImport(UIKit)
        view.attributedText = text
      #else
        view.textStorage?.setAttributedString(text)
      #endif
    }

    /// A view showing a document in its own window, with the caret at
    /// `selection`.
    convenience init(_ document: Document, selection: Int) {
      let text = AttributeMapper(styles: .standard).attributedString(for: document)
      #if canImport(UIKit)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
        window.isHidden = false
        self.init(text, frame: window.bounds)
        window.addSubview(view)
        view.selectedRange = NSRange(location: selection, length: 0)
      #else
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.init(text, frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        view.setSelectedRange(NSRange(location: selection, length: 0))
      #endif
      self.window = window
    }

    func type(_ character: String) {
      #if canImport(UIKit)
        view.insertText(character)
      #else
        view.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
      #endif
    }
  }

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
    ///
    /// A keystroke into a plain TextKit 2 text view showing the same text is
    /// measured alternately with it, as the floor (see `bar`).
    @MainActor func testKeystrokeIsUnder4Milliseconds() {
      expectWithinBars("keystroke") { measureKeystrokes() }
    }

    @MainActor private func measureKeystrokes() -> [Check] {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      XCTAssertGreaterThan(document.length, 1_800)
      let driver = NativeDriver(EditorState(document: document))
      layOut(driver.textView)
      // Typing in the middle of a paragraph, the common case.
      driver.perform(.select(Position(document.length / 2)..<Position(document.length / 2)))
      let plain = PlainTextView(document, selection: document.length / 2)
      var samples: [Duration] = []
      var plainSamples: [Duration] = []
      for index in 0..<300 {
        let character = index % 10 == 9 ? " " : "a"
        samples.append(
          ContinuousClock().measure {
            driver.perform(.type(character))
            layOut(driver.textView)
          })
        plainSamples.append(
          ContinuousClock().measure {
            plain.type(character)
            layOut(plain.view)
          })
      }
      let (median, p95) = statistics(samples.dropFirst(20))
      let floor = statistics(plainSamples.dropFirst(20))
      report("keystroke", median: median, p95: p95)
      report("keystroke, plain text view", median: floor.median, p95: floor.p95)
      // The budget holds for the typical keystroke; the tail gets twice it,
      // for scheduling noise on shared CI machines.
      return [
        Check("median keystroke", median, bar(.milliseconds(4), plain: floor.median)),
        Check("p95 keystroke", p95, bar(.milliseconds(8), plain: floor.p95)),
      ]
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
    /// mounts its input: empty, and restoring a short draft. A plain text
    /// view with the same text is mounted alternately, as the floor.
    @MainActor func testMountIsUnder5Milliseconds() {
      expectWithinBars("mount") { measureMounts() }
    }

    @MainActor private func measureMounts() -> [Check] {
      var checks: [Check] = []
      let draft = MarkdownCodec().parse(
        "Restoring a **draft** with a [link](https://wevm.dev) and `code`, about the length "
          + "of a typical message, which wraps onto a second line.")
      for (name, document) in [("empty", Document.empty), ("draft", draft)] {
        let text = AttributeMapper(styles: .standard).attributedString(for: document)
        let (plain, composer) = mountTimes(
          { PlainTextView(text, frame: $0).view },
          {
            ComposerTextView(
              controller: ComposerController(EditorState(document: document)), frame: $0)
          })
        report("mount, \(name)", median: composer.median, p95: composer.p95)
        report("mount, \(name), plain text view", median: plain.median, p95: plain.p95)
        checks.append(
          Check(
            "median mount (\(name))", composer.median, bar(.milliseconds(5), plain: plain.median)))
      }
      return checks
    }

    /// With a 2k-character document, layout dominates mounting, and a plain
    /// TextKit 2 text view showing the same text is the floor: the composer
    /// must stay near it. The two are measured interleaved, so a slow patch
    /// on a shared CI machine hits both, and the composer also maps the
    /// document, which the plain view gets for free.
    @MainActor func testMountOfAChatSizedDocumentStaysNearTextKit() {
      expectWithinBars("mount 2k") { measureChatSizedMount() }
    }

    @MainActor private func measureChatSizedMount() -> [Check] {
      let document = MarkdownCodec().parse(Self.chatMarkdown)
      let text = AttributeMapper(styles: .standard).attributedString(for: document)
      let (plain, composer) = mountTimes(
        { PlainTextView(text, frame: $0).view },
        {
          ComposerTextView(
            controller: ComposerController(EditorState(document: document)), frame: $0)
        })
      report("mount 2k, plain text view", median: plain.median, p95: plain.p95)
      report("mount 2k, composer", median: composer.median, p95: composer.p95)
      return [
        Check(
          "median mount 2k (plain \(plain.median))", composer.median,
          plain.median * 1.5 + .milliseconds(2))
      ]
    }

    // MARK: Helpers

    /// A measurement and the bar it must stay under.
    struct Check {
      var name: String
      var value: Duration
      var bar: Duration

      init(_ name: String, _ value: Duration, _ bar: Duration) {
        self.name = name
        self.value = value
        self.bar = bar
      }

      var passes: Bool { value < bar }
    }

    /// Fails for each check that misses its bar. On the iOS Simulator, where
    /// shared CI machines stall for tens of milliseconds at a time, a missed
    /// measurement is taken again once, fresh and still interleaved with the
    /// plain view, and fails only if it misses in both attempts: noise rarely
    /// strikes twice, and a real regression misses every time. macOS gets one
    /// attempt, so its absolute budgets stay binding.
    @MainActor private func expectWithinBars(_ name: String, _ measure: () -> [Check]) {
      #if targetEnvironment(simulator)
        let attempts = 2
      #else
        let attempts = 1
      #endif
      var missed: [Check] = []
      for attempt in 1...attempts {
        missed = measure().filter { !$0.passes }
        if missed.isEmpty { return }
        if attempt < attempts {
          for check in missed {
            print(
              "[performance] \(name): \(check.name) \(check.value) missed \(check.bar) "
                + "on attempt \(attempt); measuring again")
          }
        }
      }
      for check in missed {
        XCTFail("\(check.name) \(check.value), over \(check.bar)")
      }
    }

    /// The bar a measurement must clear: its budget, except on the iOS
    /// Simulator, where a plain text view doing the same work can miss the
    /// budget on shared CI machines. There the composer must instead stay
    /// within 1.5 times the plain view plus 2 ms, if that is looser. The
    /// budgets are for devices.
    private func bar(_ budget: Duration, plain: Duration) -> Duration {
      #if targetEnvironment(simulator)
        return max(budget, plain * 1.5 + .milliseconds(2))
      #else
        return budget
      #endif
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
