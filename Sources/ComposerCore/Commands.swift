/// A named command with a typed payload. Commands are identified by name.
public struct Command<Payload: Sendable>: Sendable, Hashable {
  public let name: String

  public init(_ name: String) { self.name = name }
  public init(name: String) { self.name = name }
}

extension Command where Payload == Void {
  public static var send: Command { Command("send") }
  public static var insertNewline: Command { Command("insertNewline") }
  public static var toggleBold: Command { Command("toggleBold") }
  public static var toggleItalic: Command { Command("toggleItalic") }
  public static var toggleStrikethrough: Command { Command("toggleStrikethrough") }
  public static var toggleCode: Command { Command("toggleCode") }
  public static var toggleTask: Command { Command("toggleTask") }
  public static var editLink: Command { Command("editLink") }
  public static var indent: Command { Command("indent") }
  public static var outdent: Command { Command("outdent") }
}

/// A command with its payload, as a key binding runs it.
public struct AnyCommand: Sendable {
  public let name: String
  let payload: any Sendable

  public init(_ command: Command<Void>) {
    self.name = command.name
    self.payload = ()
  }

  public init<Payload>(_ command: Command<Payload>, payload: Payload) {
    self.name = command.name
    self.payload = payload
  }
}

public enum CommandResult: Sendable, Hashable {
  /// Stops propagation.
  case handled
  /// Lets lower-priority handlers run.
  case unhandled
}

/// Handler priority. Higher priorities run first.
public struct Priority: Sendable, Hashable, Comparable, ExpressibleByIntegerLiteral {
  public var rawValue: Int

  public init(_ rawValue: Int) { self.rawValue = rawValue }
  public init(integerLiteral value: Int) { self.rawValue = value }

  /// For built-in fallbacks that any plugin should be able to override.
  public static let editor = Priority(0)
  public static let low = Priority(1)
  public static let normal = Priority(2)
  public static let high = Priority(3)
  public static let critical = Priority(4)

  public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Identifies a registered command handler, for removing it.
public struct CommandRegistration: Sendable, Hashable {
  let id: Int
}

/// The priority bus: handlers run from highest priority to lowest, and among
/// equal priorities the most recently registered runs first. The first one to
/// return `.handled` stops propagation.
struct CommandBus {
  struct Registration: Sendable {
    let name: String
    let priority: Priority
    let handler: @MainActor @Sendable (any Sendable, ComposerController) -> CommandResult

    init<Payload>(
      _ command: Command<Payload>, priority: Priority,
      handler: @escaping @MainActor @Sendable (Payload, ComposerController) -> CommandResult
    ) {
      self.name = command.name
      self.priority = priority
      self.handler = { payload, controller in
        // A same-named command with another payload type is a different command.
        guard let payload = payload as? Payload else { return .unhandled }
        return handler(payload, controller)
      }
    }
  }

  private struct Entry {
    let id: Int
    let registration: Registration
  }

  private var handlers: [String: [Entry]] = [:]
  private var nextID = 0

  mutating func add(_ registration: Registration) -> CommandRegistration {
    let entry = Entry(id: nextID, registration: registration)
    nextID += 1
    var entries = handlers[registration.name, default: []]
    // Before the first entry of the same or lower priority: later
    // registrations win ties.
    let index =
      entries.firstIndex { $0.registration.priority <= registration.priority } ?? entries.count
    entries.insert(entry, at: index)
    handlers[registration.name] = entries
    return CommandRegistration(id: entry.id)
  }

  mutating func remove(_ registration: CommandRegistration) {
    for (name, entries) in handlers {
      if let index = entries.firstIndex(where: { $0.id == registration.id }) {
        handlers[name]!.remove(at: index)
        return
      }
    }
  }

  /// The handlers for `name`, in the order they run.
  func handlers(for name: String) -> [Registration] {
    handlers[name]?.map(\.registration) ?? []
  }
}
