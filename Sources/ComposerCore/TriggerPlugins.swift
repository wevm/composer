import Foundation

// The trigger plugins: mentions, hashtags, slash commands, and emoji
// shortcodes, on the shared suggestion machinery (see `Suggestions`).

/// What a token plugin customizes: its markdown codec, its style, and its
/// VoiceOver label.
public protocol TokenPlugin: ComposerPlugin {
  var spec: NodeSpec { get set }
}

extension TokenPlugin {
  /// The node type's markdown codec.
  public func codec(_ codec: MarkdownNodeCodec) -> Self {
    var copy = self
    copy.spec.markdown = codec
    return copy
  }

  public func tokenStyle(_ style: @escaping @Sendable (AtomicNode) -> TokenStyle) -> Self {
    var copy = self
    copy.spec.tokenStyle = style
    return copy
  }

  public func accessibilityLabel(_ label: @escaping @Sendable (AtomicNode) -> String) -> Self {
    var copy = self
    copy.spec.accessibilityLabel = label
    return copy
  }
}

extension NodeType {
  public static let mention: NodeType = "mention"
  public static let hashtag: NodeType = "hashtag"
}

// MARK: Mentions

/// `@` opens suggestions from `source`, and committing one inserts a
/// mention token. Mentions are directives in markdown by default,
/// `:mention[tom]{#user_123}`.
public struct MentionsPlugin: TokenPlugin {
  public var spec: NodeSpec
  private let trigger: Trigger

  /// - `debounce`: 0 ms for a static source, 120 ms for an async one, by
  ///   default.
  public init(
    source: some SuggestionSource<Suggestion>, trigger character: Character = "@",
    debounce: Duration? = nil
  ) {
    spec = NodeSpec(
      .mention, fallbackText: { "\(character)\($0.label)" },
      accessibilityLabel: { CoreStrings.mention($0.label) })
    trigger = Trigger(character, debounce: debounce, source: source) { item, range, controller in
      var attributes = item.attributes
      attributes["id"] = item.id
      controller.replaceTrigger(
        range, with: AtomicNode(type: .mention, label: item.label, attributes: attributes))
    }
  }

  public func register(in registry: inout PluginRegistry) {
    registry.register(spec)
    registry.addTrigger(trigger)
  }
}

// MARK: Hashtags

/// `#tag` turns into a hashtag token when a space or punctuation follows
/// it, and `#` opens suggestions when there is a source. Hashtags are plain
/// `#tag` in markdown.
public struct HashtagsPlugin: TokenPlugin {
  public var spec: NodeSpec
  private let trigger: Trigger?

  public init(source: (any SuggestionSource<Suggestion>)? = nil, debounce: Duration? = nil) {
    spec = NodeSpec(
      .hashtag, markdown: Self.markdownCodec, fallbackText: { "#\($0.label)" },
      accessibilityLabel: { CoreStrings.hashtag($0.label) })
    trigger = source.map { source in
      Trigger("#", debounce: debounce, source: source) { item, range, controller in
        controller.replaceTrigger(range, with: Self.node(item.label))
      }
    }
  }

  static func node(_ tag: String) -> AtomicNode {
    AtomicNode(type: .hashtag, label: tag)
  }

  /// A tag's characters: letters, digits, `_`, and `-`, with at least one
  /// letter.
  static func isTagCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }

  static func isTag(_ tag: Substring) -> Bool {
    !tag.isEmpty && tag.allSatisfy(isTagCharacter) && tag.contains(where: \.isLetter)
      && tag.last != "-"
  }

  static let markdownCodec = MarkdownNodeCodec.custom(
    triggers: ["#"], encode: { "#\($0.label)" },
    decode: { text in
      let rest = text.dropFirst()
      let tag = rest.prefix(while: isTagCharacter)
      var end = tag.endIndex
      var trimmed = tag
      while trimmed.last == "-" {
        trimmed = trimmed.dropLast()
        end = trimmed.endIndex
      }
      guard isTag(trimmed) else { return nil }
      return (node(String(trimmed)), end)
    })

  public func register(in registry: inout PluginRegistry) {
    registry.register(spec)
    if let trigger { registry.addTrigger(trigger) }
    registry.addTransform("hashtags.freeform") { state, range in
      Self.convertFreeform(&state, in: range)
    }
  }

  /// `#tag` followed by a space or punctuation, just typed, becomes a token.
  static func convertFreeform(_ state: inout EditorState, in range: DocumentRange) {
    guard let (location, caret) = MarkdownSupport.caretBlock(state),
      range.lowerBound.offset <= caret, caret <= range.upperBound.offset,
      MarkdownSupport.justTyped(state, at: caret),
      case .paragraph(let inlines) = state.document.block(at: location.path)
    else { return }
    let start = location.range.lowerBound.offset
    var offset = 0
    for inline in inlines {
      let length = inline.length
      defer { offset += length }
      guard start + offset < caret, caret <= start + offset + length else { continue }
      guard case .text(let text, let marks) = inline, !marks.code, marks.link == nil else {
        return
      }
      let units = Array(text.utf16)
      let end = caret - start - offset
      // The boundary just typed.
      guard end >= 3, let typed = Unicode.Scalar(units[end - 1]),
        typed.properties.isWhitespace
          || (typed.properties.generalCategory.isPunctuation
            && typed != "_" && typed != "-")
      else { return }
      var hash = end - 2
      while hash >= 0, units[hash] != 0x23 {  // "#"
        hash -= 1
      }
      guard hash >= 0, hash < end - 2 else { return }
      if hash > 0, !MarkdownSupport.isBoundaryForTrigger(units[hash - 1]) { return }
      let tag = String(decoding: units[(hash + 1)..<(end - 1)], as: UTF16.self)
      guard isTag(Substring(tag)) else { return }
      let tagRange = Position(start + offset + hash)..<Position(start + offset + end - 1)
      state.replace(tagRange, with: [.node(node(tag))])
      state.selection = .caret(tagRange.lowerBound.offset + 2)
      state[Suggestions.sessionKey] = nil
      return
    }
  }
}

extension Unicode.GeneralCategory {
  var isPunctuation: Bool {
    switch self {
    case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
      .initialPunctuation, .finalPunctuation, .otherPunctuation:
      true
    default:
      false
    }
  }
}

// MARK: Slash commands

/// What a slash command does when it runs.
public enum SlashResult: Sendable {
  /// It ran a side effect; the `/command` text is removed.
  case perform
  /// The `/command` text becomes a token.
  case insert(AtomicNode)
  /// The `/command` text becomes text.
  case replace(String)
}

/// A command run by typing `/name` at the start of a paragraph and
/// committing it. Anything after the name and a space is its arguments.
public struct SlashCommand: Sendable {
  public var name: String
  public var summary: String?
  /// Runs with the arguments, once the `/command` text is removed; the
  /// result is put where the text was.
  public var run: @MainActor @Sendable (_ arguments: String, ComposerController) -> SlashResult

  public init(
    _ name: String, summary: String? = nil,
    run: @escaping @MainActor @Sendable (_ arguments: String, ComposerController) -> SlashResult
  ) {
    self.name = name
    self.summary = summary
    self.run = run
  }
}

/// `/` at the start of a paragraph opens the slash commands, its own and
/// those other plugins add (the markdown plugins add `/quote`, `/code`, and
/// `/list`).
public struct SlashCommandsPlugin: ComposerPlugin {
  public var commands: [SlashCommand]

  public init(_ commands: [SlashCommand] = []) {
    self.commands = commands
  }

  public func register(in registry: inout PluginRegistry) {
    registry.slashCommandsEnabled = true
    for command in commands { registry.addSlashCommand(command) }
  }
}

/// The commands as a suggestion source: names starting with the query's
/// first word.
struct SlashCommandSource: SuggestionSource {
  let commands: [SlashCommand]

  func results(for query: String) async throws -> [Suggestion] { immediateResults(for: query)! }

  func immediateResults(for query: String) -> [Suggestion]? {
    let name = query.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    let hasArguments = query.contains(" ")
    return commands.filter {
      hasArguments ? $0.name == name : $0.name.lowercased().hasPrefix(name.lowercased())
    }.map { Suggestion(id: $0.name, label: "/\($0.name)", subtitle: $0.summary) }
  }
}

enum SlashCommands {
  static func trigger(_ commands: [SlashCommand]) -> Trigger {
    Trigger(
      "/", atBlockStart: true, allowsSpaces: true, source: SlashCommandSource(commands: commands)
    ) { item, range, controller in
      guard let command = commands.first(where: { $0.name == item.id }) else { return }
      let query = controller.suggestionSession?.query ?? ""
      let arguments =
        query.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
      controller.replaceTrigger(range, with: "")
      switch command.run(arguments, controller) {
      case .perform: break
      case .insert(let node): controller.insertTokenAtCaret(node)
      case .replace(let text): controller.insertText(text)
      }
    }
  }
}

extension ComposerController {
  /// Inserts a token and a space at the caret.
  func insertTokenAtCaret(_ node: AtomicNode) {
    update { state in
      let caret = state.selection.range.lowerBound
      state.replace(state.selection.range, with: [.node(node), .text(" ", marks: Marks())])
      state.selection = .caret(caret.offset + 2)
    }
  }
}

// MARK: Emoji

/// An emoji and the shortcodes that type it.
public struct Emoji: Sendable, Hashable {
  public var character: String
  /// Without colons: `smile`.
  public var shortcodes: [String]

  public init(_ character: String, shortcodes: [String]) {
    self.character = character
    self.shortcodes = shortcodes
  }
}

/// `:smile:` becomes 😄 when its closing colon is typed, and `:sm` opens
/// suggestions. The app supplies the emoji; none ship with Composer.
public struct EmojiShortcodesPlugin: ComposerPlugin {
  public var emoji: [Emoji]
  /// How many characters after `:` open suggestions.
  public var minimumQueryLength: Int

  public init(emoji: [Emoji], minimumQueryLength: Int = 2) {
    self.emoji = emoji
    self.minimumQueryLength = minimumQueryLength
  }

  public func register(in registry: inout PluginRegistry) {
    var byShortcode: [String: String] = [:]
    var items: [Suggestion] = []
    for entry in emoji {
      for code in entry.shortcodes {
        if byShortcode[code] == nil { byShortcode[code] = entry.character }
        items.append(
          Suggestion(
            id: code, label: ":\(code):", subtitle: entry.character,
            attributes: ["emoji": entry.character]))
      }
    }
    let table = byShortcode
    registry.addTrigger(
      Trigger(
        ":", minimumQueryLength: minimumQueryLength,
        source: StaticSuggestionSource(items, limit: 8)
      ) { item, range, controller in
        controller.replaceTrigger(range, with: item.attributes["emoji"] ?? item.label)
      })
    registry.addTransform("emoji.shortcode") { state, range in
      Self.convert(&state, in: range, table: table)
    }
  }

  /// `:code:` just closed, at the start of a word, becomes its emoji.
  static func convert(_ state: inout EditorState, in range: DocumentRange, table: [String: String])
  {
    guard let (location, caret) = MarkdownSupport.caretBlock(state),
      range.lowerBound.offset <= caret, caret <= range.upperBound.offset,
      MarkdownSupport.justTyped(state, at: caret),
      let block = state.document.textBlock(containing: Position(caret)),
      case .paragraph = block.content,
      let text = state.document.plainTextBefore(Position(caret), in: location, limit: 64)
    else { return }
    let units = Array(text.utf16)
    guard units.count >= 3, units.last == 0x3A else { return }  // ":"
    var open = units.count - 2
    while open >= 0, units[open] != 0x3A {
      if MarkdownSupport.isWhitespace(units[open]) { return }
      open -= 1
    }
    guard open >= 0, open < units.count - 2 else { return }
    if open > 0, !MarkdownSupport.isBoundaryForTrigger(units[open - 1]) { return }
    let code = String(decoding: units[(open + 1)..<(units.count - 1)], as: UTF16.self)
    guard let character = table[code] else { return }
    let lower = caret - (units.count - open)
    state.replace(
      Position(lower)..<Position(caret),
      with: [.text(character, marks: state.typingMarks(at: Position(lower)))])
    state.selection = .caret(lower + character.utf16.count)
  }
}

extension Document {
  /// The plain text of a paragraph's last `limit` units before `position`,
  /// from after the last token or code among them.
  func plainTextBefore(_ position: Position, in location: BlockLocation, limit: Int) -> String? {
    guard case .paragraph(let inlines) = block(at: location.path) else { return nil }
    let caret = position.offset - location.range.lowerBound.offset
    let floor = max(caret - limit, 0)
    var result: [UInt16] = []
    var offset = 0
    for inline in inlines {
      guard offset < caret else { break }
      let length = inline.length
      defer { offset += length }
      guard offset + length > floor else { continue }
      switch inline {
      case .text(let text, let marks):
        guard !marks.code else {
          result.removeAll()
          continue
        }
        var unitOffset = offset
        for unit in text.utf16 {
          if unitOffset >= caret { break }
          if unitOffset >= floor { result.append(unit) }
          unitOffset += 1
        }
      case .node, .unknown:
        result.removeAll()
      }
    }
    return String(decoding: result, as: UTF16.self)
  }
}

/// Core's localized strings. On Linux, where Foundation can't look up a
/// String Catalog, they are English.
enum CoreStrings {
  static func mention(_ name: String) -> String {
    #if canImport(Darwin)
      String(localized: "mention, \(name)", bundle: .module)
    #else
      "mention, \(name)"
    #endif
  }

  #if canImport(Darwin)
    static var send: LocalizedText { LocalizedStringResource("Send", bundle: bundle) }
    static var save: LocalizedText { LocalizedStringResource("Save", bundle: bundle) }
    static var attach: LocalizedText { LocalizedStringResource("Attach", bundle: bundle) }
    private static var bundle: LocalizedStringResource.BundleDescription {
      .atURL(Bundle.module.bundleURL)
    }
  #else
    static var send: LocalizedText { "Send" }
    static var save: LocalizedText { "Save" }
    static var attach: LocalizedText { "Attach" }
  #endif

  static func hashtag(_ tag: String) -> String {
    #if canImport(Darwin)
      String(localized: "hashtag, \(tag)", bundle: .module)
    #else
      "hashtag, \(tag)"
    #endif
  }
}
