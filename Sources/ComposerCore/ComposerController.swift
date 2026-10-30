import Observation

/// The headless composer: it holds the state, runs updates and transforms,
/// dispatches commands, and resolves key bindings. UI layers render it and
/// report events to it.
@MainActor
@Observable
public final class ComposerController {
  /// The state. Observers of it are invalidated by every keystroke and
  /// selection change; views that depend on less should observe the narrower
  /// properties below, such as `isEmpty`.
  public private(set) var state: EditorState {
    didSet {
      let isEmpty = state.document.isEmpty
      if isEmpty != self.isEmpty { self.isEmpty = isEmpty }
      let session = state[Suggestions.sessionKey]
      if session != suggestionSession { suggestionSession = session }
    }
  }
  /// The open suggestion session, if any (see `suggestions`). Observed on
  /// its own, so a suggestion list is invalidated only while it is open.
  public private(set) var suggestionSession: SuggestionSession?
  /// Whether the document is empty (see `Document.isEmpty`). Observed on its
  /// own, so a placeholder is invalidated only when it appears or goes.
  public private(set) var isEmpty: Bool
  /// Whether the composer's text view has focus. The engine sets it as its
  /// view becomes and resigns first responder.
  public var isFocused = false
  public var keymap: Keymap
  @ObservationIgnored public let schema: Schema
  @ObservationIgnored public let transforms: [NodeTransform]
  @ObservationIgnored let transientState: [String]
  @ObservationIgnored let stateHooks: [StateHook]
  @ObservationIgnored let didUpdate: [@MainActor @Sendable (ComposerController, Changeset) -> Void]
  /// The suggestion triggers, by character.
  @ObservationIgnored let triggers: [Trigger]
  /// Updates while async suggestion results are fetched.
  @ObservationIgnored var suggestionTask: (key: SuggestionRequest, task: Task<Void, Never>)?
  /// Colors code blocks, if a plugin provides one.
  @ObservationIgnored public let codeHighlighter: (any CodeHighlighter)?
  /// The most transform passes one update runs. Reaching it means a
  /// transform never converges; the update stops there and reports it.
  @ObservationIgnored public var maxTransformPasses = 32

  /// The text view showing this composer. Every update's changeset is
  /// applied to it.
  @ObservationIgnored public weak var engine: (any TextEngine)?
  /// Where updates register undo. Engines set their view's `UndoManager`.
  @ObservationIgnored public var undoManager: (any UndoRegistrar)? {
    didSet { undo = UndoState() }
  }

  @ObservationIgnored private var bus = CommandBus()
  /// Ranges edited while marked text existed, for when the composition ends.
  @ObservationIgnored private var deferredDirty = DirtyRanges()
  @ObservationIgnored var undo = UndoState()

  public convenience init(
    _ state: EditorState = EditorState(), @PluginBuilder plugins: () -> [any ComposerPlugin]
  ) {
    self.init(state, plugins: plugins())
  }

  public init(_ state: EditorState = EditorState(), plugins: [any ComposerPlugin] = []) {
    var registry = PluginRegistry()
    registry.install(plugins)
    self.state = state
    self.isEmpty = state.document.isEmpty
    self.schema = registry.schema
    self.transforms = registry.transforms
    self.codeHighlighter = registry.codeHighlighter
    self.transientState = registry.transientState
    if registry.slashCommandsEnabled {
      registry.addTrigger(SlashCommands.trigger(registry.slashCommands))
    }
    if !registry.triggers.isEmpty { Suggestions.install(in: &registry) }
    self.stateHooks = registry.stateHooks
    self.didUpdate = registry.didUpdate
    self.triggers = registry.triggers
    self.suggestionSession = state[Suggestions.sessionKey]
    self.keymap = Keymap(registry.keyBindings)
    for registration in registry.commandHandlers { _ = bus.add(registration) }
  }

  // MARK: Updates

  /// The single entry point for changes. In order:
  ///
  /// 1. `body` mutates the state.
  /// 2. Transforms run on the text blocks edited since the last pass, until a
  ///    pass changes nothing (a fixed point) or `maxTransformPasses` is
  ///    reached. They are paused while marked text exists, and then run on
  ///    everything edited during the composition once it ends.
  /// 3. The changeset reports the edits and the selection before and after.
  ///
  /// An update that changes the document registers undo with `undoManager`.
  @discardableResult
  public func update(_ body: (inout EditorState) -> Void) -> Changeset {
    update(undo: .register, body)
  }

  @discardableResult
  func update(
    undo behavior: UndoBehavior, runsTransforms: Bool = true, _ body: (inout EditorState) -> Void
  ) -> Changeset {
    let before = self.state
    var state = before
    let selectionBefore = state.selection
    state.tracking = EditorState.Tracking(dirty: deferredDirty)
    deferredDirty.removeAll()
    body(&state)
    var passes = 0
    var reachedLimit = false
    if state.markedText != nil {
      deferredDirty = state.tracking!.dirty
    } else if runsTransforms {
      (passes, reachedLimit) = runTransforms(&state)
    }
    for hook in stateHooks { hook.body(&state) }
    let edits = state.tracking!.edits
    state.tracking = nil
    // Moving the caret ends the stored marks and transient plugin state,
    // unless this update set them; a composition keeps them until it
    // commits.
    if state.selection != selectionBefore, state.markedText == nil, before.markedText == nil {
      if state.storedMarks != nil, state.storedMarks == before.storedMarks {
        state.storedMarks = nil
      }
      for name in transientState where state.pluginState(named: name, equals: before) {
        state.removePluginState(named: name)
      }
    }
    if !edits.isEmpty {
      state.selection = state.selection.clamped(to: state.document.length)
    }
    if edits.isEmpty, state == self.state {
      return Changeset(selectionBefore: selectionBefore, selectionAfter: selectionBefore)
    }
    self.state = state
    let changeset = Changeset(
      edits: edits, selectionBefore: selectionBefore, selectionAfter: state.selection,
      transformPasses: passes, reachedTransformLimit: reachedLimit)
    recordUndo(behavior, before: before, changeset)
    engine?.apply(changeset, from: state)
    for observer in didUpdate { observer(self, changeset) }
    return changeset
  }

  private func runTransforms(_ state: inout EditorState) -> (passes: Int, reachedLimit: Bool) {
    var passes = 0
    while !state.tracking!.dirty.isEmpty {
      guard !transforms.isEmpty else {
        state.tracking!.dirty.removeAll()
        break
      }
      if passes == maxTransformPasses { return (passes, true) }
      passes += 1
      state.tracking!.pass = textBlockRanges(touching: state.tracking!.dirty, in: state.document)
      state.tracking!.dirty.removeAll()
      for transform in transforms {
        var index = 0
        while index < state.tracking!.pass.ranges.count {
          transform.body(&state, .init(offsets: state.tracking!.pass.ranges[index]))
          index += 1
        }
      }
      state.tracking!.pass.removeAll()
    }
    return (passes, false)
  }

  /// The content ranges of the text blocks that touch any dirty range.
  private func textBlockRanges(touching dirty: DirtyRanges, in document: Document) -> DirtyRanges {
    var result = DirtyRanges()
    let ranges = dirty.ranges
    var index = 0
    document.forEachLeaf { _, _, start, length in
      let end = start + length
      while index < ranges.count, ranges[index].upperBound < start { index += 1 }
      if index == ranges.count { return true }
      if ranges[index].lowerBound <= end { result.insert(start..<end) }
      return false
    }
    return result
  }

  // MARK: Commands

  /// Registers a handler on the priority bus. Handlers run from highest
  /// priority to lowest, and among equal priorities the most recently
  /// registered runs first. The first to return `.handled` stops propagation.
  @discardableResult
  public func register<Payload>(
    _ command: Command<Payload>, priority: Priority = .normal,
    handler: @escaping @MainActor @Sendable (Payload, ComposerController) -> CommandResult
  ) -> CommandRegistration {
    bus.add(.init(command, priority: priority, handler: handler))
  }

  public func unregister(_ registration: CommandRegistration) {
    bus.remove(registration)
  }

  /// Runs a command. Returns whether a handler handled it. Handlers
  /// registered or removed while it runs take effect from the next run.
  @discardableResult
  public func run<Payload>(_ command: Command<Payload>, _ payload: Payload) -> Bool {
    dispatch(command.name, payload)
  }

  @discardableResult
  public func run(_ command: Command<Void>) -> Bool {
    dispatch(command.name, ())
  }

  @discardableResult
  public func run(_ command: AnyCommand) -> Bool {
    dispatch(command.name, command.payload)
  }

  private func dispatch(_ name: String, _ payload: any Sendable) -> Bool {
    for registration in bus.handlers(for: name) {
      if registration.handler(payload, self) == .handled { return true }
    }
    return false
  }

  /// Runs the bindings for a key press, in keymap order, until one's command
  /// is handled. Returns whether the key was handled.
  @discardableResult
  public func handleKey(_ key: Key, modifiers: KeyModifiers = []) -> Bool {
    for binding in keymap.bindings(for: key, modifiers: modifiers, in: state) {
      if run(binding.command) { return true }
    }
    return false
  }

  // MARK: Conveniences

  public var document: Document { state.document }

  /// The selection. Setting it outside the marked text commits the
  /// composition, as clicking elsewhere does in a text view. It is clamped to
  /// the document, and its ends move out of any character they fall inside
  /// (a surrogate pair or grapheme cluster), as text views do: a caret moves
  /// to the character's start, and a range grows to cover it.
  public var selection: Selection {
    get { state.selection }
    set {
      update { state in
        let newValue = state.document.characterAligned(
          newValue.clamped(to: state.document.length))
        if let marked = state.markedText,
          newValue.range.lowerBound < marked.range.lowerBound
            || newValue.range.upperBound > marked.range.upperBound
        {
          state.markedText = nil
        }
        state.selection = newValue
      }
    }
  }

  /// Inserts a text run or node at the selection.
  public func insert(_ inline: Inline) {
    update { $0.insert([inline], over: $0.selection.range) }
  }

  /// Restores a snapshot, such as for undo: its document (as the smallest
  /// edit), selection, and plugin state. Transforms don't run, so undoing a
  /// transform's rewrite doesn't redo it, and nothing registers undo.
  @discardableResult
  public func restore(_ snapshot: EditorState) -> Changeset {
    deferredDirty.removeAll()
    return update(undo: .none, runsTransforms: false) { state in
      state.document = snapshot.document
      state.selection = snapshot.selection
      state.markedText = nil
      state.storedMarks = nil
      state.copyPluginState(from: snapshot)
    }
  }

  /// Replaces the document and puts the caret at its end.
  public func setDocument(_ document: Document) {
    update { state in
      state.document = document
      state.selection = .caret(document.length)
    }
  }

  public func clear() {
    setDocument(.empty)
  }

  /// The document as markdown, with this composer's schema.
  public var markdown: String {
    MarkdownCodec(schema: schema).serialize(state.document)
  }
}
