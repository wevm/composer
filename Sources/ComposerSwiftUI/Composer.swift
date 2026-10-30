// The SwiftUI binding: representables around the native text views, and the
// compound primitives in the `Composer` namespace. Empty off Apple
// platforms.
#if canImport(SwiftUI)
  @_exported import ComposerCore
  import SwiftUI

  /// The compound primitives: `Composer.Root`, `Composer.Input`, and the
  /// slot views, which share their composer through the environment.
  ///
  /// ```swift
  /// Composer.Root(controller) {
  ///   Composer.Input("Message", isExpanded: $expanded)
  ///     .focused($focused)
  ///   Composer.Footer { state in Counter(state) }
  /// }
  /// ```
  ///
  /// Each view observes only what it shows, so a keystroke invalidates the
  /// views that read the text or selection (`ComposerController.state`, as
  /// `Composer.Footer` does) and no others.
  public enum Composer {}

  /// How often the primitives render, for the tests of what a keystroke
  /// invalidates and that sizing settles.
  @MainActor package enum RenderCounts {
    /// `Composer.Input`'s representable updates.
    package static var inputUpdates = 0
    /// `Composer.Input`'s sizing passes.
    package static var inputSizings = 0
    /// `Composer.Placeholder` body evaluations.
    package static var placeholderBodies = 0
  }

  extension Composer {
    /// The root of a composer: puts its controller in the environment for
    /// the primitives inside. It adds no layout of its own.
    public struct Root<Content: View>: View {
      private let controller: ComposerController
      private let content: Content

      public init(_ controller: ComposerController, @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.content = content()
      }

      public var body: some View {
        content.environment(controller)
      }
    }

    /// The Placeholder slot: its content shows while the document is empty.
    /// It observes only `isEmpty`, so typing doesn't invalidate it.
    /// `Composer.Input`'s placeholder text uses the text view's own, aligned
    /// with the text; use this slot for anything else.
    public struct Placeholder<Content: View>: View {
      @Environment(ComposerController.self) private var controller
      private let content: () -> Content

      public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
      }

      public var body: some View {
        let _ = RenderCounts.placeholderBodies += 1
        if controller.isEmpty { content() }
      }
    }

    /// The Footer slot, for a character count, hints, or typing
    /// indicators. Its content gets the state, so it updates with every
    /// keystroke.
    public struct Footer<Content: View>: View {
      @Environment(ComposerController.self) private var controller
      private let content: (EditorState) -> Content

      public init(@ViewBuilder content: @escaping (EditorState) -> Content) {
        self.content = content
      }

      public var body: some View {
        content(controller.state)
      }
    }
  }
#endif
