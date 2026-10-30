import Foundation

// The shared, headless suggestion machinery behind mentions, hashtags, slash
// commands, and emoji. A trigger character at the start of a word opens a
// session; its query runs against the trigger's source, and the consumer
// renders the items. ↑, ↓, ⇥, ↩, and Esc navigate, commit, and dismiss.

/// An item in a suggestion list: a user, a tag, a command, an emoji.
public struct Suggestion: Sendable, Hashable, Identifiable {
  public var id: String
  /// What the list shows, and what a token made from it is labeled.
  public var label: String
  public var subtitle: String?
  /// Extra data, copied into a token made from the item.
  public var attributes: [String: String]

  public init(
    id: String, label: String, subtitle: String? = nil, attributes: [String: String] = [:]
  ) {
    self.id = id
    self.label = label
    self.subtitle = subtitle
    self.attributes = attributes
  }
}

/// Where suggestions come from.
public protocol SuggestionSource<Item>: Sendable {
  associatedtype Item: Sendable & Identifiable
  func results(for query: String) async throws -> [Item]
  /// The results without waiting, for sources that have them at hand. A
  /// source with them gets no debounce and no loading phase.
  func immediateResults(for query: String) -> [Item]?
}

extension SuggestionSource {
  public func immediateResults(for query: String) -> [Item]? { nil }
}

/// A fixed list, filtered by the query: labels and ids that start with it
/// first, then those that contain it, case- and diacritic-insensitively.
public struct StaticSuggestionSource: SuggestionSource {
  public var items: [Suggestion]
  public var limit: Int

  public init(_ items: [Suggestion], limit: Int = 8) {
    self.items = items
    self.limit = limit
  }

  public func results(for query: String) async throws -> [Suggestion] {
    immediateResults(for: query)!
  }

  public func immediateResults(for query: String) -> [Suggestion]? {
    let query = Self.folded(query)
    guard !query.isEmpty else { return Array(items.prefix(limit)) }
    var prefixed: [Suggestion] = []
    var containing: [Suggestion] = []
    for item in items {
      let label = Self.folded(item.label)
      let id = Self.folded(item.id)
      if label.hasPrefix(query) || id.hasPrefix(query) {
        prefixed.append(item)
      } else if label.contains(query) {
        containing.append(item)
      }
    }
    return Array((prefixed + containing).prefix(limit))
  }

  static func folded(_ text: String) -> String {
    String(
      String.UnicodeScalarView(
        text.lowercased().unicodeScalars.filter {
          // Drop combining marks after decomposition: é matches e.
          !$0.properties.isDiacritic
        }))
  }
}

extension SuggestionSource where Self == StaticSuggestionSource {
  /// A fixed list (see `StaticSuggestionSource`).
  public static func `static`(_ items: [Suggestion]) -> StaticSuggestionSource {
    StaticSuggestionSource(items)
  }
}

/// A character that opens a suggestion session, and what it searches and
/// commits.
public struct Trigger: Sendable {
  public var character: Character
  /// Only at the start of a paragraph, as slash commands are.
  public var atBlockStart: Bool
  /// Whether the query may contain spaces (a slash command's arguments).
  public var allowsSpaces: Bool
  /// The query length at which the session opens.
  public var minimumQueryLength: Int
  /// How long the query must be still before an async search starts.
  public var debounce: Duration
  public var search: @Sendable (String) async throws -> [Suggestion]
  public var immediateSearch: @Sendable (String) -> [Suggestion]?
  /// Commits an item: replaces the trigger and query (`range`) with what
  /// the item stands for.
  public var commit: @MainActor @Sendable (Suggestion, DocumentRange, ComposerController) -> Void

  public init(
    _ character: Character, atBlockStart: Bool = false, allowsSpaces: Bool = false,
    minimumQueryLength: Int = 0, debounce: Duration? = nil,
    source: some SuggestionSource<Suggestion>,
    commit: @escaping @MainActor @Sendable (Suggestion, DocumentRange, ComposerController) -> Void
  ) {
    self.character = character
    self.atBlockStart = atBlockStart
    self.allowsSpaces = allowsSpaces
    self.minimumQueryLength = minimumQueryLength
    let isImmediate = source.immediateResults(for: "") != nil
    self.debounce = debounce ?? (isImmediate ? .zero : .milliseconds(120))
    self.search = { try await source.results(for: $0) }
    self.immediateSearch = { source.immediateResults(for: $0) }
    self.commit = commit
  }
}

/// The open suggestion session, in `EditorState` (see `Suggestions`).
public struct SuggestionSession: Sendable, Hashable {
  public enum Phase: Sendable, Hashable {
    case loading, results, empty
  }

  public var trigger: Character
  /// The trigger character and the query after it.
  public var range: DocumentRange
  public var query: String
  public var phase: Phase
  public var items: [Suggestion]
  public var highlightedIndex: Int
  /// Dismissed with Esc: it stays closed until the caret leaves it.
  public var isDismissed: Bool

  /// Whether the list shows: open and not dismissed.
  public var isActive: Bool { !isDismissed }
}

/// What a fetch is for: a stale one is cancelled when the query changes.
struct SuggestionRequest: Hashable {
  var trigger: Character
  var start: Position
  var query: String
}

/// The headless suggestion state and actions, read through
/// `ComposerController.suggestions`.
@MainActor
public struct ComposerSuggestions {
  let controller: ComposerController

  public var session: SuggestionSession? { controller.suggestionSession }
  public var isActive: Bool { session?.isActive ?? false }
  public var trigger: Character? { session?.trigger }
  public var query: String? { session?.query }
  public var items: [Suggestion] { isActive ? session?.items ?? [] : [] }
  public var highlightedIndex: Int { session?.highlightedIndex ?? 0 }
  public var phase: SuggestionSession.Phase? { isActive ? session?.phase : nil }
  /// The trigger and query's rect, in the input's coordinate space, to
  /// anchor the list to.
  public var anchorRect: CGRect? {
    guard let session, let engine = controller.engine else { return nil }
    let rect = engine.rect(for: session.range)
    // A null rect (no layout yet) has an infinite origin.
    return rect.origin.x.isFinite ? rect : nil
  }

  /// Commits the highlighted item, or the one at `index`.
  @discardableResult
  public func commit(_ index: Int? = nil) -> Bool {
    Suggestions.commit(controller, index: index)
  }

  public func dismiss() {
    guard isActive else { return }
    controller.update(undo: .none) { $0[Suggestions.sessionKey]?.isDismissed = true }
  }

  public func highlight(_ index: Int) {
    guard let session, session.items.indices.contains(index) else { return }
    controller.update(undo: .none) { $0[Suggestions.sessionKey]?.highlightedIndex = index }
  }
}

extension ComposerController {
  /// The headless suggestion state: the active trigger, the query, the
  /// items, the highlighted index, the phase, and the anchor rect.
  public var suggestions: ComposerSuggestions { ComposerSuggestions(controller: self) }
}

extension Command where Payload == Void {
  public static var suggestionUp: Command { Command("suggestions.up") }
  public static var suggestionDown: Command { Command("suggestions.down") }
  public static var suggestionCommit: Command { Command("suggestions.commit") }
  public static var suggestionDismiss: Command { Command("suggestions.dismiss") }
}

enum Suggestions {
  static let sessionKey = PluginKey<SuggestionSession?>("suggestions.session", default: nil)

  /// The shared machinery, once: the state hook that opens, updates, and
  /// closes the session, the async fetch, and the keys.
  static func install(in registry: inout PluginRegistry) {
    let triggers = registry.triggers
    registry.addStateHook("suggestions") { state in
      session(&state, triggers: triggers)
    }
    registry.onDidUpdate { controller, _ in fetch(controller) }
    let open: @Sendable (EditorState) -> Bool = { state in
      guard let session = state[sessionKey] else { return false }
      return session.isActive
    }
    let hasItems: @Sendable (EditorState) -> Bool = { state in
      guard let session = state[sessionKey], session.isActive else { return false }
      return !session.items.isEmpty
    }
    for (key, command) in [
      (Key.upArrow, Command<Void>.suggestionUp), (.downArrow, .suggestionDown),
    ] {
      registry.addKeyBinding(KeyBinding(key, command: command, priority: .high, when: hasItems))
    }
    for key in [Key.return, .tab] {
      registry.addKeyBinding(
        KeyBinding(key, command: .suggestionCommit, priority: .high, when: hasItems))
    }
    registry.addKeyBinding(
      KeyBinding(.escape, command: .suggestionDismiss, priority: .high, when: open))
    registry.register(.suggestionUp, priority: .high) { _, controller in
      move(controller, by: -1)
    }
    registry.register(.suggestionDown, priority: .high) { _, controller in
      move(controller, by: 1)
    }
    registry.register(.suggestionCommit, priority: .high) { _, controller in
      commit(controller, index: nil) ? .handled : .unhandled
    }
    registry.register(.suggestionDismiss, priority: .high) { _, controller in
      guard controller.suggestions.isActive else { return .unhandled }
      controller.suggestions.dismiss()
      return .handled
    }
  }

  @MainActor private static func move(
    _ controller: ComposerController, by step: Int
  )
    -> CommandResult
  {
    guard let session = controller.suggestionSession, session.isActive, !session.items.isEmpty
    else { return .unhandled }
    let count = session.items.count
    let index = ((session.highlightedIndex + step) % count + count) % count
    controller.suggestions.highlight(index)
    return .handled
  }

  @MainActor static func commit(_ controller: ComposerController, index: Int?) -> Bool {
    guard let session = controller.suggestionSession, session.isActive,
      let trigger = controller.triggers.first(where: { $0.character == session.trigger })
    else { return false }
    let index = index ?? session.highlightedIndex
    guard session.items.indices.contains(index) else { return false }
    trigger.commit(session.items[index], session.range, controller)
    return true
  }

  /// Finds the trigger and query that end at the caret: the nearest trigger
  /// character before it in the same paragraph, at the start of a word
  /// (or of the paragraph, for triggers that need it), with a query that
  /// has no line breaks, tokens, code, or (unless the trigger allows them)
  /// spaces.
  static func find(
    in state: EditorState, triggers: [Trigger]
  ) -> (
    Trigger, DocumentRange, String
  )? {
    guard state.selection.isCollapsed,
      let block = state.document.textBlock(containing: state.selection.head),
      case .paragraph(let inlines) = block.content
    else { return nil }
    let start = block.range.lowerBound.offset
    let caret = state.selection.head.offset - start
    // The paragraph's text before the caret, at most 64 units back.
    let floor = max(caret - 64, 0)
    var units: [UInt16] = []
    var codes: [Bool] = []
    var offset = 0
    for inline in inlines {
      guard offset < caret else { break }
      let length = inline.length
      defer { offset += length }
      guard offset + length > floor else { continue }
      switch inline {
      case .text(let text, let marks):
        var unitOffset = offset
        for unit in text.utf16 {
          if unitOffset >= caret { break }
          if unitOffset >= floor {
            units.append(unit)
            codes.append(marks.code)
          }
          unitOffset += 1
        }
      case .node, .unknown:
        units.append(0xFFFC)
        codes.append(false)
      }
    }
    // `units[i]` is at paragraph offset `base + i`.
    let base = caret - units.count
    var index = units.count - 1
    var sawSpace = false
    while index >= 0 {
      let unit = units[index]
      if unit == 0x0A || unit == 0xFFFC || codes[index] { return nil }
      let paragraphOffset = base + index
      if let trigger = triggers.first(where: { $0.character.utf16.first == unit }),
        paragraphOffset == 0
          || (!trigger.atBlockStart && index > 0
            && MarkdownSupport.isBoundaryForTrigger(units[index - 1]))
      {
        if sawSpace, !trigger.allowsSpaces { return nil }
        let query = String(decoding: units[(index + 1)...], as: UTF16.self)
        guard query.utf16.count >= trigger.minimumQueryLength, !query.hasPrefix(" ") else {
          return nil
        }
        let range = Position(start + paragraphOffset)..<Position(start + caret)
        return (trigger, range, query)
      }
      if MarkdownSupport.isWhitespace(unit) { sawSpace = true }
      index -= 1
    }
    return nil
  }

  /// The state hook: keeps the session in step with the caret.
  static func session(_ state: inout EditorState, triggers: [Trigger]) {
    let previous = state[sessionKey]
    guard state.markedText == nil, let (trigger, range, query) = find(in: state, triggers: triggers)
    else {
      if previous != nil, state.markedText == nil { state[sessionKey] = nil }
      return
    }
    var session =
      previous.flatMap {
        $0.trigger == trigger.character && $0.range.lowerBound == range.lowerBound
          ? $0 : nil
      }
      ?? SuggestionSession(
        trigger: trigger.character, range: range, query: query, phase: .loading, items: [],
        highlightedIndex: 0, isDismissed: false)
    if session.query != query || previous == nil || session.range != range {
      let queryChanged = session.query != query || previous == nil
      session.range = range
      session.query = query
      if queryChanged {
        session.highlightedIndex = 0
        if let items = trigger.immediateSearch(query) {
          session.items = items
          session.phase = items.isEmpty ? .empty : .results
        } else {
          session.phase = .loading
        }
      }
    }
    if session != previous { state[sessionKey] = session }
  }

  /// Starts an async search when the session's query needs one, cancelling
  /// a stale one.
  @MainActor static func fetch(_ controller: ComposerController) {
    guard let session = controller.state[sessionKey], session.phase == .loading,
      let trigger = controller.triggers.first(where: { $0.character == session.trigger })
    else {
      controller.suggestionTask?.task.cancel()
      controller.suggestionTask = nil
      return
    }
    let request = SuggestionRequest(
      trigger: session.trigger, start: session.range.lowerBound, query: session.query)
    if controller.suggestionTask?.key == request { return }
    controller.suggestionTask?.task.cancel()
    let task = Task { @MainActor [weak controller] in
      do {
        if trigger.debounce > .zero { try await Task.sleep(for: trigger.debounce) }
        let items = try await trigger.search(request.query)
        try Task.checkCancellation()
        guard let controller else { return }
        controller.update(undo: .none) { state in
          guard var current = state[sessionKey], current.query == request.query,
            current.range.lowerBound == request.start
          else { return }
          current.items = items
          current.phase = items.isEmpty ? .empty : .results
          current.highlightedIndex = min(current.highlightedIndex, max(items.count - 1, 0))
          state[sessionKey] = current
        }
      } catch {
        guard !Task.isCancelled, let controller else { return }
        controller.update(undo: .none) { state in
          guard state[sessionKey]?.query == request.query else { return }
          state[sessionKey]?.phase = .empty
          state[sessionKey]?.items = []
        }
      }
    }
    controller.suggestionTask = (request, task)
  }
}

extension MarkdownSupport {
  /// Whether a trigger may follow a unit: at the start of a word.
  static func isBoundaryForTrigger(_ unit: UInt16) -> Bool {
    if isWhitespace(unit) { return true }
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return "([{\"'".unicodeScalars.contains(scalar)
  }
}

// MARK: Committing

extension ComposerController {
  /// Replaces a trigger and its query with a token followed by a space, as
  /// committing a mention or hashtag does.
  public func replaceTrigger(_ range: DocumentRange, with node: AtomicNode) {
    update { state in
      state.markedText = nil
      state.replace(range, with: [.node(node), .text(" ", marks: Marks())])
      state.selection = .caret(range.lowerBound.offset + 2)
      state[Suggestions.sessionKey] = nil
    }
  }

  /// Replaces a trigger and its query with text.
  public func replaceTrigger(_ range: DocumentRange, with text: String) {
    update { state in
      state.markedText = nil
      state.replace(range, with: text.isEmpty ? [] : [.text(text, marks: Marks())])
      state.selection = .caret(range.lowerBound.offset + text.utf16.count)
      state[Suggestions.sessionKey] = nil
    }
  }
}
