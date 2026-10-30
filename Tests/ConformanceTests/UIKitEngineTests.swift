// UIKit-only behavior of the engine: key commands and the keyboard
// accessory slot.
#if canImport(UIKit)
  import ComposerCore
  import ComposerTesting
  import ComposerUIKit
  import Testing
  import UIKit

  @MainActor @Suite struct UIKitEngineTests {
    /// ⌘B with a title, a binding that only applies in code, and a binding
    /// on a plain letter, which typing must keep.
    struct Bindings: ComposerPlugin {
      static let inCode = Command<Void>("inCode")
      static let plainLetter = Command<Void>("plainLetter")

      func register(in registry: inout PluginRegistry) {
        registry.addKeyBinding(
          KeyBinding("b", modifiers: .command, command: .toggleBold, discoverabilityTitle: "Bold"))
        registry.addKeyBinding(
          KeyBinding(.upArrow, command: Self.inCode) { state in
            if case .code = state.document.textBlock(containing: state.selection.head)?.content {
              return true
            }
            return false
          })
        registry.addKeyBinding(KeyBinding("x", command: Self.plainLetter))
        registry.register(.toggleBold) { _, controller in
          controller.update { $0.toggleMark(.bold, in: $0.selection.range) }
          return .handled
        }
      }
    }

    func command(
      _ view: ComposerTextView, _ input: String, _ flags: UIKeyModifierFlags = []
    ) -> UIKeyCommand? {
      view.keyCommands?.first { $0.input == input && $0.modifierFlags == flags }
    }

    @Test func keyCommandsFollowTheKeymap() throws {
      let view = ComposerTextView(controller: ComposerController(plugins: [Bindings()]))
      let bold = try #require(command(view, "b", .command))
      #expect(bold.discoverabilityTitle == "Bold")
      #expect(bold.wantsPriorityOverSystemBehavior)
      #expect(command(view, "\r", .shift) != nil, "⇧↩ inserts a line break")
      #expect(command(view, UIKeyCommand.inputDelete) != nil, "⌦ deletes forward")
      #expect(command(view, "x") == nil, "a plain letter stays typing")

      // The ↑ binding applies only in a code block; elsewhere, UIKit moves
      // the caret.
      let up = try #require(command(view, UIKeyCommand.inputUpArrow))
      #expect(!view.canPerformAction(#selector(view.handleKeyCommand(_:)), withSender: up))
      view.controller.setDocument(Document(blocks: [.codeBlock(language: nil, text: "x")]))
      #expect(view.canPerformAction(#selector(view.handleKeyCommand(_:)), withSender: up))
      #expect(view.canPerformAction(#selector(view.handleKeyCommand(_:)), withSender: bold))

      // Removing a binding removes its command.
      view.controller.keymap.remove(.toggleBold)
      #expect(command(view, "b", .command) == nil)
    }

    @Test func aKeyCommandRunsTheController() throws {
      let view = ComposerTextView(controller: ComposerController(plugins: [Bindings()]))
      view.insertText("hi")
      view.selectedRange = NSRange(location: 0, length: 2)
      view.handleKeyCommand(try #require(command(view, "b", .command)))
      #expect(view.controller.document.blocks == [.paragraph([.text("hi", marks: .bold)])])
      view.selectedRange = NSRange(location: 2, length: 0)
      view.handleKeyCommand(try #require(command(view, "\r", .shift)))
      // A line break, not a new block.
      #expect(view.controller.document.blocks.count == 1)
      #expect(view.controller.document.length == 3)
      #expect(view.controller.selection == .caret(3))
    }

    @Test func theKeyboardAccessorySlotIsTheInputAccessoryView() {
      let view = ComposerTextView(controller: ComposerController())
      #expect(view.keyboardAccessoryView == nil)
      let toolbar = UIToolbar()
      view.keyboardAccessoryView = toolbar
      #expect(view.inputAccessoryView === toolbar)
      #expect(view.keyboardAccessoryView === toolbar)
      view.keyboardAccessoryView = nil
      #expect(view.inputAccessoryView == nil)
    }
  }
#endif
