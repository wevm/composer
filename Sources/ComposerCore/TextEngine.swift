import Foundation

/// The boundary between Core and a platform text system. An engine reports
/// input to its controller (`insertText`, `deleteBackward`, …) and applies
/// every update's changeset to its text storage.
@MainActor
public protocol TextEngine: AnyObject {
  /// Applies an update's changeset. `state` is the state after it.
  func apply(_ changeset: Changeset, from state: EditorState)
  /// The selection's rects, in the engine view's coordinates.
  var selectionRects: [CGRect] { get }
  /// The bounding rect of a range, in the engine view's coordinates.
  func rect(for range: DocumentRange) -> CGRect
}
