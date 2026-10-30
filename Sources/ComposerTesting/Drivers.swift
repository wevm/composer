import ComposerCore

/// Runs session steps against an editor. The native drivers drive a real
/// text view; `ControllerDriver` drives the controller alone and is the
/// reference the native drivers are compared with.
@MainActor
public protocol SessionDriver: AnyObject {
  var controller: ComposerController { get }
  func perform(_ step: Step)
  /// A description of how the engine's own text differs from the
  /// controller's document, or `nil` if it matches. The reference driver has
  /// no engine.
  func engineMismatch() -> String?
}

extension SessionDriver {
  public var state: EditorState { controller.state }

  public func engineMismatch() -> String? { nil }

  /// Runs a session's steps in order.
  public func run(_ session: Session) {
    for step in session.steps { perform(step) }
  }
}

/// The reference driver: the steps go straight to the controller, the way an
/// engine reports them, with `UndoStack` as the undo manager. ← and → move by
/// character or node, as text views do; other keys the controller doesn't
/// handle do nothing.
@MainActor
public final class ControllerDriver: SessionDriver {
  public let controller: ComposerController
  public let undoStack = UndoStack()

  public init(_ controller: ComposerController) {
    self.controller = controller
    controller.undoManager = undoStack
  }

  public convenience init(
    _ state: EditorState = EditorState(), plugins: [any ComposerPlugin] = []
  ) {
    self.init(ComposerController(state, plugins: plugins))
  }

  public func perform(_ step: Step) {
    switch step {
    case .type(let text):
      for character in text {
        if character == "\n" {
          perform(.press(.return, []))
        } else {
          controller.insertText(String(character))
        }
      }
    case .marked(let stages, let committing):
      for stage in stages {
        let length = stage.utf16.count
        controller.setMarkedText(stage, selectedRange: length..<length)
      }
      if let committing { controller.insertText(committing) }
    case .press(let key, let modifiers):
      if !controller.handleKeyPress(key, modifiers: modifiers) {
        moveCaret(key, modifiers)
      }
    case .paste(let source):
      controller.paste(source)
    case .select(let range):
      controller.selection = Selection(range)
    case .undo:
      undoStack.undo()
    case .redo:
      undoStack.redo()
    }
  }

  /// ← and →, with or without ⇧, as text views move the caret.
  private func moveCaret(_ key: Key, _ modifiers: KeyModifiers) {
    guard key == .leftArrow || key == .rightArrow, modifiers == [] || modifiers == [.shift]
    else { return }
    let document = controller.document
    let selection = controller.selection
    let forward = key == .rightArrow
    func step(_ position: Position) -> Position {
      if forward {
        return Position(min(document.boundary(after: position.offset), document.length))
      }
      return Position(max(document.boundary(before: position.offset), 0))
    }
    if modifiers == [.shift] {
      controller.selection = Selection(anchor: selection.anchor, head: step(selection.head))
    } else if selection.isCollapsed {
      controller.selection = Selection(step(selection.head))
    } else {
      // A selection collapses to the edge in the direction of the arrow.
      let range = selection.range
      controller.selection = Selection(forward ? range.upperBound : range.lowerBound)
    }
  }
}
