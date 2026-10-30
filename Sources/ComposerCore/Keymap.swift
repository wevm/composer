import Foundation

#if canImport(Darwin)
  /// A key binding's title, for menus and the iPad shortcut overlay.
  public typealias KeyBindingTitle = LocalizedStringResource
#else
  /// A key binding's title. Linux Foundation has no `LocalizedStringResource`.
  public typealias KeyBindingTitle = String
#endif

/// A key, independent of any UI framework. Letters are stored lowercase; the
/// Shift modifier says whether Shift was held.
public struct Key: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue.count == 1 ? rawValue.lowercased() : rawValue
  }

  public init(stringLiteral value: String) { self.init(value) }

  public static let `return` = Key("return")
  public static let tab = Key("tab")
  public static let escape = Key("escape")
  public static let space = Key(" ")
  /// Backspace.
  public static let delete = Key("delete")
  public static let forwardDelete = Key("forwardDelete")
  public static let upArrow = Key("upArrow")
  public static let downArrow = Key("downArrow")
  public static let leftArrow = Key("leftArrow")
  public static let rightArrow = Key("rightArrow")
  public static let home = Key("home")
  public static let end = Key("end")
  public static let pageUp = Key("pageUp")
  public static let pageDown = Key("pageDown")

  public var description: String { rawValue }
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  public static let command = KeyModifiers(rawValue: 1 << 0)
  public static let shift = KeyModifiers(rawValue: 1 << 1)
  public static let option = KeyModifiers(rawValue: 1 << 2)
  public static let control = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyBinding: Sendable {
  public var key: Key
  public var modifiers: KeyModifiers
  public var command: AnyCommand
  public var priority: Priority
  /// Whether the binding applies in a state. A binding that doesn't apply is
  /// skipped as if absent.
  public var when: @Sendable (EditorState) -> Bool
  public var discoverabilityTitle: KeyBindingTitle?

  public init(
    _ key: Key, modifiers: KeyModifiers = [], command: AnyCommand, priority: Priority = .normal,
    discoverabilityTitle: KeyBindingTitle? = nil,
    when: @escaping @Sendable (EditorState) -> Bool = { _ in true }
  ) {
    self.key = key
    self.modifiers = modifiers
    self.command = command
    self.priority = priority
    self.when = when
    self.discoverabilityTitle = discoverabilityTitle
  }

  public init(
    _ key: Key, modifiers: KeyModifiers = [], command: Command<Void>, priority: Priority = .normal,
    discoverabilityTitle: KeyBindingTitle? = nil,
    when: @escaping @Sendable (EditorState) -> Bool = { _ in true }
  ) {
    self.init(
      key, modifiers: modifiers, command: AnyCommand(command), priority: priority,
      discoverabilityTitle: discoverabilityTitle, when: when)
  }
}

/// The key bindings plugins contribute. Exported, so apps can build their own
/// menus; consumers can add, override, or remove any binding.
public struct Keymap: Sendable {
  /// In the order they are tried: highest priority first, and among equal
  /// priorities the most recently added first.
  public private(set) var bindings: [KeyBinding] = []

  public init(_ bindings: [KeyBinding] = []) {
    for binding in bindings { add(binding) }
  }

  public mutating func add(_ binding: KeyBinding) {
    let index = bindings.firstIndex { $0.priority <= binding.priority } ?? bindings.count
    bindings.insert(binding, at: index)
  }

  /// Removes every binding that runs `command`.
  public mutating func remove<Payload>(_ command: Command<Payload>) {
    bindings.removeAll { $0.command.name == command.name }
  }

  /// Removes every binding for a key combination.
  public mutating func remove(_ key: Key, modifiers: KeyModifiers = []) {
    bindings.removeAll { $0.key == key && $0.modifiers == modifiers }
  }

  /// The bindings that apply to a key press in `state`, in the order they are
  /// tried.
  public func bindings(
    for key: Key, modifiers: KeyModifiers, in state: EditorState
  )
    -> [KeyBinding]
  {
    bindings.filter { $0.key == key && $0.modifiers == modifiers && $0.when(state) }
  }
}
