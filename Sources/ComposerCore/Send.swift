// Sending: the message, the willSend hooks, and the send action and keys.

/// What `SendAction` sends.
public struct ComposerMessage: Sendable {
  public var document: Document
  /// The document as markdown, with the composer's schema.
  public var markdown: String
  public var attachments: [Attachment]
  public var context: (any ComposerContext)?

  public init(
    document: Document, markdown: String, attachments: [Attachment] = [],
    context: (any ComposerContext)? = nil
  ) {
    self.document = document
    self.markdown = markdown
    self.attachments = attachments
    self.context = context
  }
}

public enum SendDecision: Sendable, Hashable {
  case proceed
  /// Vetoes the send; the draft stays.
  case cancel
}

/// How a send ended.
public enum SendOutcome: Sendable {
  case sent
  /// A willSend hook cancelled it.
  case cancelled
  /// A hook or the send threw. The draft is back in the composer, unless
  /// something new was written while the send was in flight.
  case failed(any Error)
  /// There is no send action, or it isn't enabled.
  case unavailable
}

/// A hook run before every send, which may change the message, cancel the
/// send, or throw (see `PluginRegistry.addWillSend`).
public typealias WillSendHook = @Sendable (inout ComposerMessage) async throws -> SendDecision

extension PluginRegistry {
  /// Adds a `willSend` hook. Hooks run from highest priority to lowest
  /// (the most recently added first among equals), each seeing the message
  /// as the one before left it.
  public mutating func addWillSend(priority: Priority = .normal, _ hook: @escaping WillSendHook) {
    let index = willSend.firstIndex { $0.priority <= priority } ?? willSend.count
    willSend.insert((priority, hook), at: index)
  }
}

/// A controller's send configuration, from `SendAction`.
struct SendConfiguration: Sendable {
  var onSend: @Sendable (ComposerMessage) async throws -> Void
  var clearing: SendAction.Clearing
  var onFailure: (@MainActor @Sendable (any Error, ComposerController) -> Void)?
}

/// Sends the message: the send button, ⌘↩ everywhere, and on macOS ↩
/// outside code blocks and lists (see DESIGN.md, Return).
///
/// By default the composer clears as soon as the willSend hooks proceed,
/// and the draft comes back if the send throws, so chat feels instant and
/// nothing is lost. `.clearing(.afterSuccess)` waits for the send instead.
///
/// The action is enabled when there is something to send (text, a token, or
/// an attachment), no attachment is pending, uploading, or failed, and a
/// soft `MaxLength` isn't exceeded.
public struct SendAction: ComposerPlugin {
  public static let id: ComposerAction.ID = "send"

  public enum Clearing: Sendable, Hashable {
    case immediately
    case afterSuccess
  }

  var configuration: SendConfiguration
  var placement = ComposerAction.Placement.PerPlatform(macOS: .none, iOS: .trailing)
  var returnSends: Bool

  /// - Parameter returnSends: whether ↩ outside code blocks and lists sends,
  ///   as on macOS (the default there); otherwise ↩ inserts a newline and only
  ///   ⌘↩ and the button send, as on iOS.
  public init(
    returnSends: Bool? = nil, onSend: @escaping @Sendable (ComposerMessage) async throws -> Void
  ) {
    configuration = SendConfiguration(onSend: onSend, clearing: .immediately)
    #if os(macOS)
      self.returnSends = returnSends ?? true
    #else
      self.returnSends = returnSends ?? false
    #endif
  }

  public func clearing(_ clearing: Clearing) -> SendAction {
    var copy = self
    copy.configuration.clearing = clearing
    return copy
  }

  public func placement(_ placement: ComposerAction.Placement.PerPlatform) -> SendAction {
    var copy = self
    copy.placement = placement
    return copy
  }

  /// Called when a send started from the button or a key fails, after the
  /// draft is restored. Callers of `ComposerController.send()` get the
  /// outcome instead.
  public func onFailure(
    _ body: @escaping @MainActor @Sendable (any Error, ComposerController) -> Void
  ) -> SendAction {
    var copy = self
    copy.configuration.onFailure = body
    return copy
  }

  public func register(in registry: inout PluginRegistry) {
    registry.send = configuration
    registry.addAction(
      ComposerAction(
        id: Self.id, label: CoreStrings.send, editingLabel: CoreStrings.save,
        systemImage: "arrow.up.circle.fill", placement: placement, isEnabled: Self.canSend
      ) { controller in
        if case .failed(let error) = await controller.send() { throw error }
      })
    registry.register(.send) { _, controller in
      guard controller.isEnabled(Self.id) else { return .handled }
      Task { @MainActor in
        if case .failed(let error) = await controller.send() {
          controller.sendConfiguration?.onFailure?(error, controller)
        }
      }
      return .handled
    }
    registry.addKeyBinding(KeyBinding(.return, modifiers: .command, command: .send))
    if returnSends {
      registry.addKeyBinding(
        KeyBinding(.return, command: .send, priority: .low, when: Self.isPlain))
    }
  }

  /// Whether the state has something to send and nothing blocks it.
  @Sendable public static func canSend(_ state: EditorState) -> Bool {
    if state.attachments.contains(where: { $0.isInFlight || $0.isFailed }) { return false }
    if state[MaxLength.statusKey]?.isOver == true { return false }
    return !state.attachments.isEmpty || !state.document.isBlank
  }

  /// Whether the caret is outside code blocks and lists, where ↩ sends.
  @Sendable static func isPlain(_ state: EditorState) -> Bool {
    guard state.markedText == nil else { return false }
    guard let location = state.document.location(of: state.selection.head) else { return true }
    for container in location.containers {
      if case .item = container { return false }
    }
    if case .codeBlock = state.document.block(at: location.path) { return false }
    return true
  }
}

extension Attachment {
  var isFailed: Bool {
    if case .failed = status { return true }
    return false
  }
}

extension Document {
  /// Whether the document has nothing to send: no tokens, and only
  /// whitespace.
  public var isBlank: Bool {
    var blank = true
    forEachTextBlock(in: Position(0)..<Position(length)) { block, _ in
      guard blank else { return }
      switch block.content {
      case .code(_, let text):
        if !text.allSatisfy(\.isWhitespace) { blank = false }
      case .paragraph(let inlines):
        for inline in inlines {
          guard case .text(let text, _) = inline else {
            blank = false
            return
          }
          if !text.allSatisfy(\.isWhitespace) {
            blank = false
            return
          }
        }
      }
    }
    return blank
  }
}

extension ComposerController {
  /// The message the composer would send now.
  public var message: ComposerMessage {
    ComposerMessage(
      document: state.document, markdown: markdown, attachments: state.attachments,
      context: state.context)
  }

  /// Sends the message, as the send button does: runs the willSend hooks,
  /// clears the composer, and calls the send action.
  ///
  /// If something is written while the hooks or (with `.afterSuccess`) the
  /// send run, it isn't cleared, and a failed send doesn't overwrite it.
  @discardableResult
  public func send() async -> SendOutcome {
    guard let configuration = sendConfiguration, isEnabled(SendAction.id) else {
      return .unavailable
    }
    let draft = state
    var message = self.message
    sendsInFlight += 1
    defer { sendsInFlight -= 1 }
    for (_, hook) in willSend {
      do {
        if try await hook(&message) == .cancel { return .cancelled }
      } catch {
        return .failed(error)
      }
    }
    if configuration.clearing == .immediately { clearDraft(ifStill: draft) }
    do {
      try await configuration.onSend(message)
    } catch {
      if configuration.clearing == .immediately, isClearedDraft { restore(draft) }
      return .failed(error)
    }
    if configuration.clearing == .afterSuccess { clearDraft(ifStill: draft) }
    return .sent
  }

  /// Whether the send action is blocked by a send in flight: with
  /// `.afterSuccess`, the draft is still showing until it finishes.
  var isSendBlocked: Bool {
    sendsInFlight > 0 && sendConfiguration?.clearing == .afterSuccess
  }

  /// Whether the composer is as `clearDraft` leaves it.
  private var isClearedDraft: Bool {
    state.document.isEmpty && state.attachments.isEmpty && state.context == nil
  }

  /// Clears the document, attachments, and context, unless the draft
  /// changed since `draft`. Clearing isn't undoable, and undo history of the
  /// sent draft is dropped.
  private func clearDraft(ifStill draft: EditorState) {
    guard state.document == draft.document, state.attachments == draft.attachments else { return }
    update(undo: .none) { state in
      state.document = .empty
      state.selection = .caret(0)
      state.storedMarks = nil
      state.attachments = []
      state.context = nil
    }
    undo = UndoState()
    undoManager?.removeAllActions()
  }
}
