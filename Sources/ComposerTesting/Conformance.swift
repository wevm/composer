import ComposerCore

/// An intended difference between platforms (see DESIGN.md, Platform
/// behavior). Before two states are compared, each difference normalizes
/// both, so only the differences listed here are tolerated.
public struct PlatformDifference: Sendable {
  public var name: String
  public var normalize: @Sendable (inout EditorState) -> Void

  public init(_ name: String, normalize: @escaping @Sendable (inout EditorState) -> Void) {
    self.name = name
    self.normalize = normalize
  }
}

/// The intended platform differences a comparison tolerates.
public struct Allowlist: Sendable {
  public var differences: [PlatformDifference]

  public init(_ differences: [PlatformDifference] = []) { self.differences = differences }

  /// Nothing differs. The send and Return rules that differ by platform
  /// arrive with their plugins.
  public static let none = Allowlist()

  func normalized(_ state: EditorState) -> EditorState {
    var state = state
    for difference in differences { difference.normalize(&state) }
    return state
  }
}

/// Where two drivers first disagreed while running a session.
public struct Divergence: Sendable, CustomStringConvertible {
  /// The index of the step after which they disagreed.
  public var stepIndex: Int
  public var step: Step
  public var expected: EditorState
  public var actual: EditorState
  /// Set when the engine's own text disagrees with its controller.
  public var engineMismatch: String?

  public var description: String {
    var lines = ["After step \(stepIndex), \(step):"]
    if let engineMismatch {
      lines.append("  the engine's text differs from its document: \(engineMismatch)")
    }
    if expected != actual {
      lines.append("  expected \(summary(expected))")
      lines.append("  actual   \(summary(actual))")
      if expected.document != actual.document {
        lines.append("  expected document: \(expected.document)")
        lines.append("  actual document:   \(actual.document)")
      }
    }
    return lines.joined(separator: "\n")
  }

  private func summary(_ state: EditorState) -> String {
    let marked = state.markedText.map { " marked \($0.range.lowerBound)..<\($0.range.upperBound)" }
    return "\(MarkdownCodec().serialize(state.document).debugDescription) "
      + "\(state.selection)\(marked ?? "")"
  }
}

/// Runs a session on two drivers, comparing their states after every step,
/// and returns the first divergence, or `nil` if they agree throughout.
@MainActor
public func firstDivergence(
  of session: Session, reference: some SessionDriver, engine: some SessionDriver,
  allowing allowlist: Allowlist = .none
) -> Divergence? {
  for (index, step) in session.steps.enumerated() {
    reference.perform(step)
    engine.perform(step)
    let expected = allowlist.normalized(reference.state)
    let actual = allowlist.normalized(engine.state)
    let mismatch = engine.engineMismatch()
    if expected != actual || mismatch != nil {
      return Divergence(
        stepIndex: index, step: step, expected: expected, actual: actual,
        engineMismatch: mismatch)
    }
  }
  return nil
}
