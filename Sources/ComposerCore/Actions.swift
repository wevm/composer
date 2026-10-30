import Foundation

#if canImport(Darwin)
  /// User-facing text: a `LocalizedStringResource` on Apple platforms, and a
  /// `String` on Linux, where Foundation has none.
  public typealias LocalizedText = LocalizedStringResource
#else
  /// User-facing text. Linux Foundation has no `LocalizedStringResource`.
  public typealias LocalizedText = String
#endif

/// A button-like action, such as send or the attachment picker. Plugins and
/// consumers both provide them; UI layers loop over a placement
/// (`ComposerController.actions(_:)`) or place one by id.
public struct ComposerAction: Sendable, Identifiable {
  public struct ID: Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
  }

  /// Where an action's control goes.
  public enum Placement: Sendable, Hashable {
    case leading
    case trailing
    /// Only placed by id, or not shown.
    case none

    /// A placement for each platform.
    public struct PerPlatform: Sendable, Hashable {
      public var macOS: Placement
      public var iOS: Placement

      public init(macOS: Placement, iOS: Placement) {
        self.macOS = macOS
        self.iOS = iOS
      }

      public static let leading = PerPlatform(macOS: .leading, iOS: .leading)
      public static let trailing = PerPlatform(macOS: .trailing, iOS: .trailing)
      public static let none = PerPlatform(macOS: .none, iOS: .none)

      /// The placement on the platform this runs on (macOS's on Linux).
      public var current: Placement {
        #if os(iOS) || os(visionOS) || os(tvOS)
          iOS
        #else
          macOS
        #endif
      }
    }
  }

  public var id: ID
  public var label: LocalizedText
  /// The label while an edit context is set ("Save" for send), if it
  /// differs.
  public var editingLabel: LocalizedText?
  /// An SF Symbol name.
  public var systemImage: String?
  public var placement: Placement.PerPlatform
  public var isEnabled: @Sendable (EditorState) -> Bool
  public var isVisible: @Sendable (EditorState) -> Bool
  public var perform: @MainActor @Sendable (ComposerController) async throws -> Void

  public init(
    id: ID, label: LocalizedText, editingLabel: LocalizedText? = nil, systemImage: String? = nil,
    placement: Placement.PerPlatform = .trailing,
    isEnabled: @escaping @Sendable (EditorState) -> Bool = { _ in true },
    isVisible: @escaping @Sendable (EditorState) -> Bool = { _ in true },
    perform: @escaping @MainActor @Sendable (ComposerController) async throws -> Void
  ) {
    self.id = id
    self.label = label
    self.editingLabel = editingLabel
    self.systemImage = systemImage
    self.placement = placement
    self.isEnabled = isEnabled
    self.isVisible = isVisible
    self.perform = perform
  }
}

extension PluginRegistry {
  /// Adds an action. An action with the same id replaces the earlier one,
  /// in its place.
  public mutating func addAction(_ action: ComposerAction) {
    if let index = actions.firstIndex(where: { $0.id == action.id }) {
      actions[index] = action
    } else {
      actions.append(action)
    }
  }
}

extension ComposerController {
  /// The visible actions at a placement on this platform, in registration
  /// order. Reading it observes only which actions are visible.
  public func actions(_ placement: ComposerAction.Placement) -> [ComposerAction] {
    actions.filter { $0.placement.current == placement && visibleActions.contains($0.id) }
  }

  public func action(_ id: ComposerAction.ID) -> ComposerAction? {
    actions.first { $0.id == id }
  }

  /// Whether an action can run now. Observes only the set of enabled
  /// actions, so a keystroke invalidates a button only when it flips.
  public func isEnabled(_ id: ComposerAction.ID) -> Bool {
    enabledActions.contains(id)
  }

  /// The label to show for an action: its editing label while an edit
  /// context is set.
  public func label(of action: ComposerAction) -> LocalizedText {
    if context?.kind == .edit, let label = action.editingLabel { return label }
    return action.label
  }

  /// Runs an action if it is enabled. Returns whether it ran.
  @discardableResult
  public func perform(_ id: ComposerAction.ID) async throws -> Bool {
    guard let action = action(id), isEnabled(id) else { return false }
    try await action.perform(self)
    return true
  }

  /// Recomputes which actions are enabled and visible, assigning only on a
  /// change so observers aren't invalidated for nothing.
  func refreshActions() {
    guard !actions.isEmpty else { return }
    var enabled = Set<ComposerAction.ID>()
    var visible = Set<ComposerAction.ID>()
    for action in actions {
      if action.isVisible(state) { visible.insert(action.id) }
      if action.isEnabled(state), !(action.id == SendAction.id && isSendBlocked) {
        enabled.insert(action.id)
      }
    }
    if enabled != enabledActions { enabledActions = enabled }
    if visible != visibleActions { visibleActions = visible }
  }
}
