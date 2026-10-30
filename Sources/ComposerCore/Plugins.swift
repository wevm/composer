/// A plugin contributes to the registry: node types, transforms, command
/// handlers, and key bindings. Everything is a plugin, and the core turns no
/// features on.
public protocol ComposerPlugin: Sendable {
  func register(in registry: inout PluginRegistry)
}

/// A key for typed plugin state in `EditorState`. Keys are identified by
/// name. The state is `Equatable` because it is compared along with the
/// document.
public struct PluginKey<State: Sendable & Equatable>: Sendable, Hashable {
  public let name: String
  public let defaultValue: State

  public init(_ name: String, default defaultValue: State) {
    self.name = name
    self.defaultValue = defaultValue
  }

  public static func == (lhs: PluginKey, rhs: PluginKey) -> Bool { lhs.name == rhs.name }
  public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// What plugins contribute, collected in plugin order.
public struct PluginRegistry: Sendable {
  public var schema = Schema()
  public internal(set) var transforms: [NodeTransform] = []
  public internal(set) var keyBindings: [KeyBinding] = []
  var commandHandlers: [CommandBus.Registration] = []
  /// Plugin state that lasts only until the selection moves, like stored
  /// marks: an update that moves the selection outside a composition
  /// clears it, unless the update set it.
  public internal(set) var transientState: [String] = []
  public internal(set) var stateHooks: [StateHook] = []
  var didUpdate: [@MainActor @Sendable (ComposerController, Changeset) -> Void] = []
  /// Suggestion triggers (see `Trigger`), in registration order.
  public internal(set) var triggers: [Trigger] = []
  /// Slash commands, from the slash command plugin and others (the
  /// markdown plugins add `/quote`, `/code`, and `/list`).
  public internal(set) var slashCommands: [SlashCommand] = []
  /// Whether slash commands are on: their trigger is added at the end of
  /// installation, so it sees every plugin's commands.
  public var slashCommandsEnabled = false
  var paste = PasteConfiguration()
  /// Colors code blocks (see `MarkdownCodeBlocks`).
  public var codeHighlighter: (any CodeHighlighter)?

  public init() {}

  /// Registers a node type with its codecs.
  public mutating func register(_ node: NodeSpec) {
    schema.register(node)
  }

  public mutating func addTransform(_ transform: NodeTransform) {
    transforms.append(transform)
  }

  public mutating func addTransform(
    _ name: String, _ body: @escaping @Sendable (inout EditorState, DocumentRange) -> Void
  ) {
    transforms.append(NodeTransform(name, body))
  }

  /// Adds a hook that runs at the end of every update, after transforms,
  /// including updates that only move the selection. Hooks derive plugin
  /// state from the document and selection, such as the open suggestion
  /// session; they shouldn't edit the document.
  public mutating func addStateHook(
    _ name: String, _ body: @escaping @Sendable (inout EditorState) -> Void
  ) {
    guard !stateHooks.contains(where: { $0.name == name }) else { return }
    stateHooks.append(StateHook(name: name, body: body))
  }

  /// Adds an observer called after every update that changes the state,
  /// once the engine has applied it. The `didChange` lifecycle hook.
  public mutating func onDidUpdate(
    _ body: @escaping @MainActor @Sendable (ComposerController, Changeset) -> Void
  ) {
    didUpdate.append(body)
  }

  /// Adds a suggestion trigger. A later trigger for the same character
  /// replaces the earlier one.
  public mutating func addTrigger(_ trigger: Trigger) {
    triggers.removeAll { $0.character == trigger.character }
    triggers.append(trigger)
  }

  public mutating func addSlashCommand(_ command: SlashCommand) {
    slashCommands.removeAll { $0.name == command.name }
    slashCommands.append(command)
  }

  /// Makes a plugin state key transient (see `transientState`).
  public mutating func addTransientState<State>(_ key: PluginKey<State>) {
    if !transientState.contains(key.name) { transientState.append(key.name) }
  }

  public mutating func addKeyBinding(_ binding: KeyBinding) {
    keyBindings.append(binding)
  }

  /// Registers a command handler (see `ComposerController.register`).
  public mutating func register<Payload>(
    _ command: Command<Payload>, priority: Priority = .normal,
    handler: @escaping @MainActor @Sendable (Payload, ComposerController) -> CommandResult
  ) {
    commandHandlers.append(.init(command, priority: priority, handler: handler))
  }

  public mutating func install(_ plugins: [any ComposerPlugin]) {
    for plugin in plugins { plugin.register(in: &self) }
  }
}

/// A hook run at the end of every update (see `PluginRegistry.addStateHook`).
public struct StateHook: Sendable {
  public var name: String
  public var body: @Sendable (inout EditorState) -> Void
}

/// A rewrite that runs during every update on the text blocks edited since
/// its last run, until a pass changes nothing (see `ComposerController.update`).
/// Input rules and token recognition are transforms.
public struct NodeTransform: Sendable {
  public var name: String
  /// Called with a dirty text block's content range, which is current when
  /// the call starts. A transform edits through `EditorState`'s editing
  /// methods; anything it changes is dirty for the next pass. It must reach a
  /// state where it changes nothing, or the update stops at the pass limit.
  public var body: @Sendable (inout EditorState, DocumentRange) -> Void

  public init(
    _ name: String, _ body: @escaping @Sendable (inout EditorState, DocumentRange) -> Void
  ) {
    self.name = name
    self.body = body
  }
}

/// Plugins composed as one, for presets such as `.chatDefaults`.
public struct PluginGroup: ComposerPlugin {
  public var plugins: [any ComposerPlugin]

  public init(@PluginBuilder _ plugins: () -> [any ComposerPlugin]) {
    self.plugins = plugins()
  }

  public init(_ plugins: [any ComposerPlugin]) {
    self.plugins = plugins
  }

  public func register(in registry: inout PluginRegistry) {
    registry.install(plugins)
  }
}

@resultBuilder
public enum PluginBuilder {
  public static func buildExpression(_ plugin: some ComposerPlugin) -> [any ComposerPlugin] {
    [plugin]
  }

  public static func buildExpression(_ plugins: [any ComposerPlugin]) -> [any ComposerPlugin] {
    plugins
  }

  public static func buildBlock(_ parts: [any ComposerPlugin]...) -> [any ComposerPlugin] {
    parts.flatMap(\.self)
  }

  public static func buildOptional(_ part: [any ComposerPlugin]?) -> [any ComposerPlugin] {
    part ?? []
  }

  public static func buildEither(first part: [any ComposerPlugin]) -> [any ComposerPlugin] {
    part
  }

  public static func buildEither(second part: [any ComposerPlugin]) -> [any ComposerPlugin] {
    part
  }

  public static func buildArray(_ parts: [[any ComposerPlugin]]) -> [any ComposerPlugin] {
    parts.flatMap(\.self)
  }

  public static func buildLimitedAvailability(_ part: [any ComposerPlugin]) -> [any ComposerPlugin]
  {
    part
  }
}
