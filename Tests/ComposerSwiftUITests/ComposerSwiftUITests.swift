// The SwiftUI binding, hosted in a real window: what a keystroke
// invalidates, intrinsic height between line limits, `isExpanded`, and
// `.focused`. Apple-only.
#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
  @testable import ComposerSwiftUI
  import SwiftUI
  import Testing
  #if canImport(UIKit)
    import ComposerUIKit
    import UIKit
  #else
    import AppKit
    import ComposerAppKit
  #endif

  /// A SwiftUI view in a window of its own.
  @MainActor final class Host {
    #if canImport(UIKit)
      let window: UIWindow
    #else
      let window: NSWindow
    #endif

    init(width: CGFloat = 320, height: CGFloat = 480, _ content: some View) {
      #if canImport(UIKit)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
      #else
        window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)
      #endif
      settle()
    }

    isolated deinit {
      #if canImport(UIKit)
        window.isHidden = true
      #else
        window.close()
      #endif
    }

    /// Lets SwiftUI apply pending updates and lay out.
    func settle() {
      for _ in 0..<3 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #if canImport(UIKit)
          window.layoutIfNeeded()
        #else
          window.contentView?.layoutSubtreeIfNeeded()
        #endif
      }
    }

    var textView: ComposerTextView {
      #if canImport(UIKit)
        let root: UIView = window
      #else
        let root: NSView = window.contentView!
      #endif
      func find(_ view: some AnyObject) -> ComposerTextView? {
        #if canImport(UIKit)
          let view = view as! UIView
        #else
          let view = view as! NSView
        #endif
        if let textView = view as? ComposerTextView { return textView }
        for subview in view.subviews {
          if let found = find(subview) { return found }
        }
        return nil
      }
      return find(root)!
    }

    /// The height the input occupies: its scroll view's on macOS.
    var inputHeight: CGFloat {
      #if canImport(UIKit)
        textView.frame.height
      #else
        textView.enclosingScrollView!.frame.height
      #endif
    }

    /// Types through the text input method the keyboard calls.
    func type(_ text: String) {
      #if canImport(UIKit)
        textView.insertText(text)
      #else
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
      #endif
    }

    var isTextViewFocused: Bool {
      #if canImport(UIKit)
        textView.isFirstResponder
      #else
        window.firstResponder === textView
      #endif
    }
  }

  /// Counts body evaluations of the test's own views.
  @MainActor final class Counter {
    var root = 0
    var footer = 0
    var sibling = 0
  }

  struct Sibling: View {
    let counter: Counter
    var body: some View {
      let _ = counter.sibling += 1
      Text("Sibling")
    }
  }

  @MainActor @Suite(.serialized) struct ComposerSwiftUITests {
    struct Screen: View {
      let controller: ComposerController
      let counter: Counter

      var body: some View {
        let _ = counter.root += 1
        Composer.Root(controller) {
          VStack {
            Composer.Header { context in Text("Replying to \(context.id)") }
            Composer.Attachments()
            Composer.Placeholder { Text("Say something") }
            HStack {
              Composer.Input("Message")
              Composer.Actions(.trailing)
            }
            Composer.Footer { state in
              let _ = counter.footer += 1
              Text("\(state.document.length)")
            }
            Sibling(counter: counter)
          }
        }
      }
    }

    @Test func aKeystrokeInvalidatesOnlyViewsOfTheTextOrSelection() {
      let controller = ComposerController(plugins: [
        SendAction { _ in }.placement(.trailing), AttachmentsPlugin { _, _ in },
      ])
      let counter = Counter()
      let host = Host(Screen(controller: controller, counter: counter))
      let textView = host.textView
      #expect(textView.controller === controller)
      // The first character hides the placeholder.
      let placeholderBefore = RenderCounts.placeholderBodies
      host.type("a")
      host.settle()
      #expect(RenderCounts.placeholderBodies > placeholderBefore)

      let root = counter.root
      let sibling = counter.sibling
      let footer = counter.footer
      let placeholder = RenderCounts.placeholderBodies
      let inputUpdates = RenderCounts.inputUpdates
      let slots = (
        RenderCounts.headerBodies, RenderCounts.attachmentsBodies, RenderCounts.actionsBodies,
        RenderCounts.actionBodies
      )
      #expect(controller.isEnabled(SendAction.id))
      for character in "bcdef" {
        host.type(String(character))
        host.settle()
      }
      controller.selection = .caret(2)
      host.settle()
      #expect(controller.document.length == 6)
      // The footer reads the state, so it updates with each change.
      #expect(counter.footer >= footer + 5)
      // Nothing else does: the input applies the change itself.
      #expect(counter.root == root)
      #expect(counter.sibling == sibling)
      #expect(RenderCounts.placeholderBodies == placeholder)
      #expect(RenderCounts.inputUpdates == inputUpdates)
      // The slots observe their own data, which typing doesn't change.
      #expect(RenderCounts.headerBodies == slots.0)
      #expect(RenderCounts.attachmentsBodies == slots.1)
      #expect(RenderCounts.actionsBodies == slots.2)
      #expect(RenderCounts.actionBodies == slots.3, "send stays enabled")

      // Clearing shows the placeholder again.
      controller.clear()
      host.settle()
      #expect(RenderCounts.placeholderBodies > placeholder)
      #expect(counter.root == root)
    }

    struct Editing: ComposerContext {
      var id = "m1"
      var kind = ComposerContextKind.edit
    }

    @Test func slotsUpdateWithTheirData() {
      let controller = ComposerController(plugins: [
        SendAction { _ in }.placement(.trailing), AttachmentsPlugin { _, _ in },
      ])
      let counter = Counter()
      let host = Host(Screen(controller: controller, counter: counter))
      let (header, tray, action) = (
        RenderCounts.headerBodies, RenderCounts.attachmentsBodies, RenderCounts.actionBodies
      )
      controller.setContext(Editing())
      host.settle()
      #expect(RenderCounts.headerBodies > header)
      #expect(RenderCounts.actionBodies > action, "send's label becomes Save")
      controller.addAttachments([Attachment(payload: 0, name: "a.png", status: .ready)])
      host.settle()
      #expect(RenderCounts.attachmentsBodies > tray)
      #expect(controller.isEnabled(SendAction.id))
    }

    struct Sized: View {
      let controller: ComposerController
      var isExpanded = false

      var body: some View {
        Composer.Root(controller) {
          VStack(spacing: 0) {
            Composer.Input(lines: 1...4, isExpanded: .constant(isExpanded))
            Spacer(minLength: 0)
          }
        }
      }
    }

    @Test func heightGrowsFromMinLinesToMaxLinesAndSettles() {
      let controller = ComposerController()
      let host = Host(Sized(controller: controller))
      let line = TextSizing.lineHeight(of: host.textView.textStyles.base)
      let one = host.inputHeight
      #expect(one > line && one < line * 2.5, "one line: \(one), line \(line)")

      // Line breaks, so there's no space between blocks.
      for index in 0..<2 {
        controller.handleKeyPress(.return, modifiers: .shift)
        controller.insertText("line \(index)")
      }
      host.settle()
      let three = host.inputHeight
      #expect(three > one + line * 1.5, "three lines: \(three), one: \(one)")

      for index in 0..<20 {
        controller.handleKeyPress(.return, modifiers: .shift)
        controller.insertText("more \(index)")
      }
      host.settle()
      let capped = host.inputHeight
      #expect(abs(capped - host.textView.fittingHeight) < 1)
      #expect(capped > three && capped < one + line * 3.5, "capped: \(capped), one: \(one)")

      // No layout loop: settled sizing doesn't size again.
      let sizings = RenderCounts.inputSizings
      host.settle()
      host.settle()
      #expect(RenderCounts.inputSizings == sizings)

      // Back to one line, it shrinks.
      controller.clear()
      host.settle()
      // Heights round up to whole points.
      #expect(abs(host.inputHeight - one) <= 1)
    }

    @Test func anExpandedInputTakesTheOfferedHeight() {
      let host = Host(height: 400, Sized(controller: ComposerController(), isExpanded: true))
      #expect(host.inputHeight > 300, "expanded: \(host.inputHeight)")
    }

    @MainActor @Observable final class FocusModel {
      var request: Bool?
      var reported: [Bool] = []
    }

    struct Focusing: View {
      let controller: ComposerController
      let model: FocusModel
      @FocusState private var focused: Bool

      var body: some View {
        Composer.Root(controller) {
          VStack {
            Composer.Input().focused($focused)
            Spacer()
          }
        }
        .onChange(of: model.request) { _, request in
          if let request { focused = request }
        }
        .onChange(of: focused) { _, focused in model.reported.append(focused) }
      }
    }

    @Test func focusedMovesFocusBothWays() {
      let controller = ComposerController()
      let model = FocusModel()
      let host = Host(Focusing(controller: controller, model: model))
      #expect(!host.isTextViewFocused)

      // Setting the focus state focuses the text view.
      model.request = true
      host.settle()
      #expect(host.isTextViewFocused)
      #expect(controller.isFocused)

      // Focus leaving the text view clears the focus state.
      #if canImport(UIKit)
        _ = host.textView.resignFirstResponder()
      #else
        host.window.makeFirstResponder(nil)
      #endif
      host.settle()
      #expect(!controller.isFocused)
      #expect(model.reported.last == false)

      // And the text view taking focus sets it.
      #if canImport(UIKit)
        _ = host.textView.becomeFirstResponder()
      #else
        host.window.makeFirstResponder(host.textView)
      #endif
      host.settle()
      #expect(model.reported.last == true)

      // Clearing the focus state resigns the text view.
      model.request = false
      host.settle()
      #expect(!host.isTextViewFocused)
    }

    struct Tinted: ComposerActionStyle {
      func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.isEnabled ? .blue : .gray)
      }
    }

    @MainActor final class Seen {
      var style: (any ComposerActionStyle)?
    }

    struct Probe: View {
      @Environment(\.composerActionStyle) var style
      let seen: Seen
      var body: some View {
        let _ = seen.style = style
        Composer.StyledAction(.init(label: Text("Send"), isEnabled: true, isPressed: false))
      }
    }

    @Test func aStyleInTheEnvironmentRendersConfigurations() {
      let seen = Seen()
      let host = Host(Probe(seen: seen).composerActionStyle(Tinted()))
      _ = host
      #expect(seen.style is Tinted)
    }
  }
#endif
