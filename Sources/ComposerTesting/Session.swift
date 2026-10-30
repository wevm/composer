import ComposerCore

/// A scripted editing session: keys, typing, IME marked text, paste, and
/// selection changes. A session runs against any `SessionDriver`: the
/// controller alone (`ControllerDriver`, on every platform) or a real text
/// view (the native drivers), so the same script checks that every engine
/// edits the same way.
///
/// ```swift
/// let session = Session {
///   Type("hello **wor")
///   Marked("l", "ld", committing: "ld")
///   Type("**")
///   Press(.return, modifiers: .shift)
///   Paste(.plainText("https://wevm.dev"))
/// }
/// ```
public struct Session: Sendable, Hashable {
  public var steps: [Step]

  public init(steps: [Step]) { self.steps = steps }

  public init(@SessionBuilder _ steps: () -> [Step]) { self.steps = steps() }
}

/// One step of a session.
public enum Step: Sendable, Hashable, CustomStringConvertible {
  /// Typing characters one at a time, as the input system inserts them. A
  /// newline is a press of ↩.
  case type(String)
  /// An IME composition: each stage becomes the marked text in turn, with
  /// the caret at its end, then `committing` is inserted in its place, or the
  /// composition stays open if it is `nil`.
  case marked([String], committing: String?)
  /// A key press, as the engine receives it from the keyboard.
  case press(Key, KeyModifiers)
  case paste(PasteSource)
  /// Selects a range, as a click or drag does. Text views don't expose a
  /// selection's direction, so sessions select forward.
  case select(DocumentRange)
  case undo
  case redo

  public var description: String {
    switch self {
    case .type(let text): "Type(\(text.debugDescription))"
    case .marked(let stages, let committing):
      "Marked(\(stages.map(\.debugDescription).joined(separator: ", ")), committing: "
        + "\(committing?.debugDescription ?? "nil"))"
    case .press(let key, let modifiers):
      "Press(\(key)\(modifiers.isEmpty ? "" : ", " + Self.describe(modifiers)))"
    case .paste(let source): "Paste(\(source))"
    case .select(let range): "Select(\(range.lowerBound)..<\(range.upperBound))"
    case .undo: "Undo()"
    case .redo: "Redo()"
    }
  }

  private static func describe(_ modifiers: KeyModifiers) -> String {
    let names: [(KeyModifiers, String)] = [
      (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    return names.filter { modifiers.contains($0.0) }.map(\.1).joined()
  }
}

/// Something that turns into steps in a `Session` builder.
public protocol SessionStep {
  var steps: [Step] { get }
}

extension Step: SessionStep {
  public var steps: [Step] { [self] }
}

@resultBuilder
public enum SessionBuilder {
  public static func buildExpression(_ step: some SessionStep) -> [Step] { step.steps }
  public static func buildExpression(_ steps: [Step]) -> [Step] { steps }
  public static func buildBlock(_ components: [Step]...) -> [Step] { components.flatMap { $0 } }
  public static func buildOptional(_ component: [Step]?) -> [Step] { component ?? [] }
  public static func buildEither(first component: [Step]) -> [Step] { component }
  public static func buildEither(second component: [Step]) -> [Step] { component }
  public static func buildArray(_ components: [[Step]]) -> [Step] { components.flatMap { $0 } }
}

// MARK: Builder steps

/// Types characters one at a time. A newline is a press of ↩.
public struct Type: SessionStep {
  public var steps: [Step]
  public init(_ text: String) { steps = [.type(text)] }
}

/// An IME composition through `stages`, then committed as `committing`, or
/// left open if it is `nil`.
public struct Marked: SessionStep {
  public var steps: [Step]
  public init(_ stages: String..., committing: String?) {
    steps = [.marked(stages, committing: committing)]
  }
}

/// A key press. (Not `Key`, which is Core's key type.)
public struct Press: SessionStep {
  public var steps: [Step]
  public init(_ key: Key, modifiers: KeyModifiers = []) { steps = [.press(key, modifiers)] }
}

public struct Paste: SessionStep {
  public var steps: [Step]
  public init(_ source: PasteSource) { steps = [.paste(source)] }
}

/// Selects a range, or puts the caret at a position.
public struct Select: SessionStep {
  public var steps: [Step]
  public init(_ range: Range<Int>) {
    steps = [.select(Position(range.lowerBound)..<Position(range.upperBound))]
  }
  public init(caret: Int) { steps = [.select(Position(caret)..<Position(caret))] }
}

public struct Undo: SessionStep {
  public var steps: [Step] { [.undo] }
  public init() {}
}

public struct Redo: SessionStep {
  public var steps: [Step] { [.redo] }
  public init() {}
}
