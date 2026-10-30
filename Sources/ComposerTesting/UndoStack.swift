import ComposerCore

/// A minimal undo stack: one group per registration, for driving undo where
/// `UndoManager` isn't available (Linux) and in reference sessions.
@MainActor
public final class UndoStack: UndoRegistrar {
  private var undos: [@MainActor @Sendable () -> Void] = []
  private var redos: [@MainActor @Sendable () -> Void] = []
  public private(set) var isUndoing = false
  public private(set) var isRedoing = false

  public init() {}

  public var canUndo: Bool { !undos.isEmpty }
  public var canRedo: Bool { !redos.isEmpty }

  public func registerUndoGroup(_ action: @escaping @MainActor @Sendable () -> Void) {
    if isUndoing {
      redos.append(action)
    } else {
      undos.append(action)
      if !isRedoing { redos.removeAll() }
    }
  }

  public func removeAllActions() {
    undos.removeAll()
    redos.removeAll()
  }

  public func undo() {
    guard let action = undos.popLast() else { return }
    isUndoing = true
    action()
    isUndoing = false
  }

  public func redo() {
    guard let action = redos.popLast() else { return }
    isRedoing = true
    action()
    isRedoing = false
  }
}
