// Reply and edit contexts: what the message being written answers or
// replaces, shown in the Header slot and sent with the message.

/// What a message replies to or edits. The app defines the type, carrying
/// whatever it needs (the message, its author); the composer only needs to
/// tell contexts apart and know whether one is an edit.
public protocol ComposerContext: Sendable {
  /// Identifies the context among the app's: two contexts with the same
  /// kind and id are the same.
  var id: String { get }
  var kind: ComposerContextKind { get }
}

public enum ComposerContextKind: Sendable, Hashable {
  case reply
  /// Editing a sent message: send saves it, and its label becomes "Save".
  case edit
}

/// A context in the state: compared by kind and id.
struct ContextValue: Sendable, Equatable {
  let context: any ComposerContext

  static func == (lhs: ContextValue, rhs: ContextValue) -> Bool {
    lhs.context.kind == rhs.context.kind && lhs.context.id == rhs.context.id
  }
}

extension EditorState {
  static let contextKey = PluginKey<ContextValue?>("composer.context", default: nil)

  /// The reply or edit context, if any.
  public var context: (any ComposerContext)? {
    get { self[Self.contextKey]?.context }
    set { self[Self.contextKey] = newValue.map(ContextValue.init) }
  }
}

extension ComposerController {
  /// Sets or clears the context. Editing usually also loads the message
  /// being edited: pass its document, and the caret goes to its end.
  public func setContext(_ context: (any ComposerContext)?, document: Document? = nil) {
    update { state in
      state.context = context
      if let document {
        state.document = document
        state.selection = .caret(document.length)
      }
    }
  }
}

extension Command where Payload == Void {
  /// Clears the reply or edit context (Esc).
  public static var clearContext: Command { Command("clearContext") }
  /// Edits the last message (↑ in an empty composer).
  public static var editLastMessage: Command { Command("editLastMessage") }
}

/// Reply and edit contexts: Esc clears the context, and ↑ in an empty
/// composer calls `editLast`, which only the app can answer: it sets an edit
/// context and the message's document (`setContext(_:document:)`) and
/// returns `true`, or returns `false` when there is nothing to edit.
public struct ReplyAndEdit: ComposerPlugin {
  let editLast: (@MainActor @Sendable (ComposerController) -> Bool)?

  public init(editLast: (@MainActor @Sendable (ComposerController) -> Bool)? = nil) {
    self.editLast = editLast
  }

  public func register(in registry: inout PluginRegistry) {
    registry.addKeyBinding(KeyBinding(.escape, command: .clearContext) { $0.context != nil })
    registry.register(.clearContext) { _, controller in
      guard controller.state.context != nil else { return .unhandled }
      controller.setContext(nil)
      return .handled
    }
    guard let editLast else { return }
    registry.addKeyBinding(
      KeyBinding(.upArrow, command: .editLastMessage) {
        $0.document.isEmpty && $0.markedText == nil
      })
    registry.register(.editLastMessage) { _, controller in
      editLast(controller) ? .handled : .unhandled
    }
  }
}
