import Foundation

/// Where Core registers undo. `UndoManager` conforms on Apple platforms;
/// Linux Foundation has none, so tests use their own (see `ComposerTesting`).
public protocol UndoRegistrar: AnyObject {
  var isUndoing: Bool { get }
  var isRedoing: Bool { get }
  /// Registers `action` as one undo group (or, while undoing or redoing, as
  /// the reverse action).
  func registerUndoGroup(_ action: @escaping @Sendable () -> Void)
}

#if canImport(Darwin)
  extension UndoManager: UndoRegistrar {
    public func registerUndoGroup(_ action: @escaping @Sendable () -> Void) {
      let grouped = !isUndoing && !isRedoing
      if grouped { beginUndoGrouping() }
      registerUndo(withTarget: self) { _ in action() }
      if grouped { endUndoGrouping() }
    }
  }
#endif

/// How an update takes part in undo.
enum UndoBehavior {
  /// Registers an undo group if the document changed.
  case register
  /// Typing one character: joins the previous typing group if it continues
  /// at the caret where that one ended.
  case typing
  /// Registers nothing (restoring a snapshot).
  case none
}

/// Undo bookkeeping between updates.
struct UndoState {
  /// Where the current typing group's caret is, if typing would join it.
  var typingCaret: Selection?
  /// The state before an IME composition began. The composition registers
  /// one undo group, when it ends.
  var compositionStart: EditorState?
}

extension ComposerController {
  /// Registers undo for an update, per DESIGN.md: changesets are coalesced
  /// into groups, so consecutive typing is one group, and the native undo
  /// manager keeps the stack.
  func recordUndo(_ behavior: UndoBehavior, before: EditorState, _ changeset: Changeset) {
    guard let undoManager, behavior != .none, !undoManager.isUndoing, !undoManager.isRedoing
    else { return }
    if state.markedText != nil {
      if undo.compositionStart == nil { undo.compositionStart = before }
      return
    }
    let snapshot = undo.compositionStart ?? before
    let endsComposition = undo.compositionStart != nil
    undo.compositionStart = nil
    guard snapshot.document != state.document else {
      // Only the selection moved: typing elsewhere starts a new group.
      if behavior != .typing { undo.typingCaret = nil }
      return
    }
    if behavior == .typing, !endsComposition, let caret = undo.typingCaret,
      caret == changeset.selectionBefore
    {
      undo.typingCaret = changeset.selectionAfter
      return
    }
    undo.typingCaret = behavior == .typing ? changeset.selectionAfter : nil
    registerUndo(restoring: snapshot, with: undoManager)
  }

  /// Registers an action that restores `snapshot` and registers the reverse,
  /// so undo and redo alternate.
  private func registerUndo(restoring snapshot: EditorState, with undoManager: any UndoRegistrar) {
    undoManager.registerUndoGroup { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        let current = self.state
        self.undo = UndoState()
        self.restore(snapshot)
        if let undoManager = self.undoManager {
          self.registerUndo(restoring: current, with: undoManager)
        }
      }
    }
  }
}
