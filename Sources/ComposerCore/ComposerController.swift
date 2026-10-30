import Observation

/// The headless composer: it holds the state, runs updates and transforms,
/// dispatches commands, and resolves key bindings. UI layers render it and
/// report events to it.
@MainActor
@Observable
public final class ComposerController {
  public private(set) var state: EditorState
  public var keymap: Keymap
  @ObservationIgnored public let schema: Schema
  @ObservationIgnored public let transforms: [NodeTransform]
  /// The most transform passes one update runs. Reaching it means a
  /// transform never converges; the update stops there and reports it.
  @ObservationIgnored public var maxTransformPasses = 32

  @ObservationIgnored private var bus = CommandBus()
  /// Ranges edited while marked text existed, for when the composition ends.
  @ObservationIgnored private var deferredDirty = DirtyRanges()

  public convenience init(
    _ state: EditorState = EditorState(), @PluginBuilder plugins: () -> [any ComposerPlugin]
  ) {
    self.init(state, plugins: plugins())
  }

  public init(_ state: EditorState = EditorState(), plugins: [any ComposerPlugin] = []) {
    var registry = PluginRegistry()
    registry.install(plugins)
    self.state = state
    self.schema = registry.schema
    self.transforms = registry.transforms
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
  @discardableResult
  public func update(_ body: (inout EditorState) -> Void) -> Changeset {
    var state = self.state
    let selectionBefore = state.selection
    state.tracking = EditorState.Tracking(dirty: deferredDirty)
    deferredDirty.removeAll()
    body(&state)
    var passes = 0
    var reachedLimit = false
    if state.markedText == nil {
      (passes, reachedLimit) = runTransforms(&state)
    } else {
      deferredDirty = state.tracking!.dirty
    }
    let edits = state.tracking!.edits
    state.tracking = nil
    if !edits.isEmpty {
      state.selection = state.selection.clamped(to: state.document.length)
    }
    if edits.isEmpty, state == self.state {
      return Changeset(selectionBefore: selectionBefore, selectionAfter: selectionBefore)
    }
    self.state = state
    return Changeset(
      edits: edits, selectionBefore: selectionBefore, selectionAfter: state.selection,
      transformPasses: passes, reachedTransformLimit: reachedLimit)
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

  public var selection: Selection {
    get { state.selection }
    set { update { $0.selection = newValue } }
  }

  /// Inserts a text run or node at the selection.
  public func insert(_ inline: Inline) {
    update { $0.insert([inline], over: $0.selection.range) }
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
