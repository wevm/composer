// Session drivers that run a session against a real `UITextView` or
// `NSTextView`. Apple-only.
#if canImport(UIKit)
  import ComposerCore
  import ComposerUIKit
  import UIKit

  /// The driver for the platform's text view.
  public typealias NativeDriver = UIKitDriver

  /// Runs sessions against a `ComposerTextView` in a window, as UIKit
  /// delivers input: typing, Return, Tab, ⌫, and marked text through the
  /// `UITextInput` methods the keyboard calls; other hardware keys through
  /// the view's key commands; and ← and → as UIKit's own key handling moves
  /// the caret, by the text input tokenizer's characters.
  @MainActor
  public final class UIKitDriver: SessionDriver {
    public let textView: ComposerTextView
    public let window: UIWindow
    public let undoManager = UndoManager()
    private let pasteboard = UIPasteboard.withUniqueName()

    public var controller: ComposerController { textView.controller }

    public init(_ controller: ComposerController) {
      window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 640))
      textView = ComposerTextView(controller: controller, frame: window.bounds)
      // Without an event loop, groups must close explicitly.
      undoManager.groupsByEvent = false
      textView.composerUndoManager = undoManager
      window.addSubview(textView)
      window.isHidden = false
    }

    public convenience init(
      _ state: EditorState = EditorState(), plugins: [any ComposerPlugin] = []
    ) {
      self.init(ComposerController(state, plugins: plugins))
    }

    isolated deinit {
      UIPasteboard.remove(withName: pasteboard.name)
      window.isHidden = true
    }

    public func perform(_ step: Step) {
      switch step {
      case .type(let text):
        for character in text {
          if character == "\n" {
            perform(.press(.return, []))
          } else {
            textView.insertText(String(character))
          }
        }
      case .marked(let stages, let committing):
        for stage in stages {
          textView.setMarkedText(
            stage, selectedRange: NSRange(location: stage.utf16.count, length: 0))
        }
        if let committing { textView.insertText(committing) }
      case .press(let key, let modifiers):
        press(key, modifiers)
      case .paste(let source):
        switch source {
        case .plainText(let text): pasteboard.string = text
        }
        textView.paste(from: pasteboard)
      case .select(let range):
        // As the controller does, keep the selection inside the document.
        let length = controller.document.length
        textView.selectedRange = textView.storageMap.storage(
          Position(
            min(range.lowerBound.offset, length))..<Position(
              min(range.upperBound.offset, length)))
      case .undo:
        undoManager.undo()
      case .redo:
        undoManager.redo()
      }
    }

    public func engineMismatch() -> String? {
      textView.renderingMismatch()
    }

    private func press(_ key: Key, _ modifiers: KeyModifiers) {
      // A key command, if the view has one that applies.
      if let input = key.keyCommandInput,
        let command = textView.keyCommands?.first(where: {
          $0.input == input && $0.modifierFlags == UIKeyModifierFlags(modifiers)
        }),
        let action = command.action,
        textView.canPerformAction(action, withSender: command)
      {
        textView.handleKeyCommand(command)
        return
      }
      // Otherwise, what the keyboard and UIKit's text handling do.
      switch (key, modifiers) {
      case (.return, []): textView.insertText("\n")
      case (.tab, []): textView.insertText("\t")
      case (.delete, []): textView.deleteBackward()
      case (.leftArrow, []), (.leftArrow, [.shift]), (.rightArrow, []), (.rightArrow, [.shift]):
        textView.handlingKey { moveCaret(key, extending: modifiers == [.shift]) }
      default: break
      }
    }

    /// ← and →, by the tokenizer's characters; with ⇧, the head moves and
    /// the anchor stays.
    private func moveCaret(_ key: Key, extending: Bool) {
      guard let selected = textView.selectedTextRange else { return }
      let forward = key == .rightArrow
      let direction = UITextDirection.storage(forward ? .forward : .backward)
      let selection = controller.selection
      func position(_ offset: Int) -> UITextPosition? {
        textView.position(from: textView.beginningOfDocument, offset: offset)
      }
      func moved(_ from: UITextPosition) -> UITextPosition {
        textView.tokenizer.position(from: from, toBoundary: .character, inDirection: direction)
          ?? from
      }
      if extending {
        let map = textView.storageMap
        guard let anchor = position(map.storage(selection.anchor.offset)),
          let head = position(map.storage(selection.head.offset))
        else { return }
        let newHead = moved(head)
        let ordered =
          textView.compare(anchor, to: newHead) == .orderedDescending
          ? (newHead, anchor) : (anchor, newHead)
        textView.selectedTextRange = textView.textRange(from: ordered.0, to: ordered.1)
      } else if selected.isEmpty {
        let caret = moved(selected.start)
        textView.selectedTextRange = textView.textRange(from: caret, to: caret)
      } else {
        let edge = forward ? selected.end : selected.start
        textView.selectedTextRange = textView.textRange(from: edge, to: edge)
      }
    }
  }
#elseif canImport(AppKit)
  import AppKit
  import ComposerAppKit
  import ComposerCore

  /// The driver for the platform's text view.
  public typealias NativeDriver = AppKitDriver

  /// Runs sessions against a `ComposerTextView` in an offscreen window, as
  /// AppKit delivers input: typing and marked text through the text input
  /// client methods an input method calls, and key presses as key events.
  @MainActor
  public final class AppKitDriver: SessionDriver {
    public let textView: ComposerTextView
    public let window: NSWindow
    public let undoManager = UndoManager()
    private let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("dev.wevm.composer.testing.\(UUID().uuidString)"))

    public var controller: ComposerController { textView.controller }

    public init(_ controller: ComposerController) {
      _ = NSApplication.shared
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      textView = ComposerTextView(controller: controller, frame: window.contentView!.bounds)
      // Without an event loop, groups must close explicitly.
      undoManager.groupsByEvent = false
      textView.composerUndoManager = undoManager
      window.contentView!.addSubview(textView)
      window.makeFirstResponder(textView)
    }

    public convenience init(
      _ state: EditorState = EditorState(), plugins: [any ComposerPlugin] = []
    ) {
      self.init(ComposerController(state, plugins: plugins))
    }

    isolated deinit {
      pasteboard.releaseGlobally()
      window.close()
    }

    public func perform(_ step: Step) {
      let noRange = NSRange(location: NSNotFound, length: 0)
      switch step {
      case .type(let text):
        for character in text {
          if character == "\n" {
            perform(.press(.return, []))
          } else {
            textView.insertText(String(character), replacementRange: noRange)
          }
        }
      case .marked(let stages, let committing):
        for stage in stages {
          textView.setMarkedText(
            stage, selectedRange: NSRange(location: stage.utf16.count, length: 0),
            replacementRange: noRange)
        }
        if let committing { textView.insertText(committing, replacementRange: noRange) }
      case .press(let key, let modifiers):
        press(key, modifiers)
      case .paste(let source):
        switch source {
        case .plainText(let text):
          pasteboard.clearContents()
          pasteboard.setString(text, forType: .string)
        }
        textView.paste(from: pasteboard)
      case .select(let range):
        // As the controller does, keep the selection inside the document.
        let length = controller.document.length
        textView.setSelectedRange(
          textView.storageMap.storage(
            Position(
              min(range.lowerBound.offset, length))..<Position(
                min(range.upperBound.offset, length))))
      case .undo:
        undoManager.undo()
      case .redo:
        undoManager.redo()
      }
    }

    public func engineMismatch() -> String? {
      textView.renderingMismatch()
    }

    /// Sends a key down event, as the window would: key equivalents first
    /// for ⌘ and ⌃, then `keyDown`.
    private func press(_ key: Key, _ modifiers: KeyModifiers) {
      let (code, characters) = Self.keyCode(for: key)
      var flags: NSEvent.ModifierFlags = []
      if modifiers.contains(.command) { flags.insert(.command) }
      if modifiers.contains(.shift) { flags.insert(.shift) }
      if modifiers.contains(.option) { flags.insert(.option) }
      if modifiers.contains(.control) { flags.insert(.control) }
      if Self.functionKeys.contains(key) { flags.formUnion([.function, .numericPad]) }
      guard
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
          windowNumber: window.windowNumber, context: nil,
          characters: modifiers.contains(.shift) ? characters.uppercased() : characters,
          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
      else { return }
      if !modifiers.isDisjoint(with: [.command, .control]),
        textView.performKeyEquivalent(with: event)
      {
        return
      }
      textView.keyDown(with: event)
    }

    private static let functionKeys: Set<Key> = [
      .upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end, .pageUp, .pageDown,
      .forwardDelete,
    ]

    private static func keyCode(for key: Key) -> (UInt16, String) {
      func function(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }
      switch key {
      case .return: return (36, "\r")
      case .tab: return (48, "\t")
      case .delete: return (51, "\u{7F}")
      case .forwardDelete: return (117, function(NSDeleteFunctionKey))
      case .escape: return (53, "\u{1B}")
      case .leftArrow: return (123, function(NSLeftArrowFunctionKey))
      case .rightArrow: return (124, function(NSRightArrowFunctionKey))
      case .downArrow: return (125, function(NSDownArrowFunctionKey))
      case .upArrow: return (126, function(NSUpArrowFunctionKey))
      case .home: return (115, function(NSHomeFunctionKey))
      case .end: return (119, function(NSEndFunctionKey))
      case .pageUp: return (116, function(NSPageUpFunctionKey))
      case .pageDown: return (121, function(NSPageDownFunctionKey))
      default: return (Self.letterCodes[key.rawValue] ?? 0, key.rawValue)
      }
    }

    /// ANSI key codes for letters, which key equivalents match on.
    private static let letterCodes: [String: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
      "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
  }
#endif
