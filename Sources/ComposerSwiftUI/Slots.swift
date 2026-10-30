// The Header, Attachments, and action slots. Each observes only its own
// data on the controller: the context, the tray, or which actions are
// enabled and visible.
#if canImport(SwiftUI)
  import SwiftUI

  extension RenderCounts {
    /// `Composer.Header`, `Composer.Attachments`, and `Composer.Actions`
    /// body evaluations.
    package static var headerBodies = 0
    package static var attachmentsBodies = 0
    package static var actionsBodies = 0
    package static var actionBodies = 0
  }

  extension Composer {
    /// The Header slot, for the reply or edit banner: its content shows
    /// while a context is set, and gets it.
    public struct Header<Content: View>: View {
      @Environment(ComposerController.self) private var controller
      private let content: (any ComposerContext) -> Content

      public init(@ViewBuilder content: @escaping (any ComposerContext) -> Content) {
        self.content = content
      }

      public var body: some View {
        let _ = RenderCounts.headerBodies += 1
        if let context = controller.context { content(context) }
      }
    }

    /// The Attachments slot: the tray, above the input, while it has
    /// attachments. Each attachment renders with `item`, by default in the
    /// environment's `AttachmentStyle` with a remove button.
    public struct Attachments<Item: View>: View {
      @Environment(ComposerController.self) private var controller
      private let item: (Attachment) -> Item

      public init(@ViewBuilder item: @escaping (Attachment) -> Item) {
        self.item = item
      }

      public var body: some View {
        let _ = RenderCounts.attachmentsBodies += 1
        if !controller.attachments.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(controller.attachments) { attachment in item(attachment) }
            }
          }
          .scrollIndicators(.hidden)
        }
      }
    }

    /// The actions at a placement (LeadingActions or TrailingActions), in
    /// the environment's `ComposerActionStyle`. A button is disabled while
    /// its action isn't enabled, and shows its editing label while an edit
    /// context is set.
    public struct Actions: View {
      @Environment(ComposerController.self) private var controller
      private let placement: ComposerAction.Placement

      public init(_ placement: ComposerAction.Placement) {
        self.placement = placement
      }

      public var body: some View {
        let _ = RenderCounts.actionsBodies += 1
        ForEach(controller.actions(placement)) { action in
          Composer.Action(action.id)
        }
      }
    }

    /// One action, placed by id.
    public struct Action: View {
      @Environment(ComposerController.self) private var controller
      private let id: ComposerAction.ID

      public init(_ id: ComposerAction.ID) {
        self.id = id
      }

      public var body: some View {
        let _ = RenderCounts.actionBodies += 1
        if let action = controller.action(id) {
          let isEnabled = controller.isEnabled(id)
          let label = controller.label(of: action)
          Button {
            Task { try? await controller.perform(id) }
          } label: {
            if let image = action.systemImage {
              Label(title: { Text(label) }, icon: { Image(systemName: image) })
            } else {
              Text(label)
            }
          }
          .buttonStyle(ActionButtonStyle(isEnabled: isEnabled))
          .disabled(!isEnabled)
          .accessibilityLabel(Text(label))
        }
      }
    }
  }

  extension Composer.Attachments where Item == Composer.AttachmentItem {
    /// Attachments in the environment's `AttachmentStyle`.
    public init() {
      self.init { Composer.AttachmentItem($0) }
    }
  }

  extension Composer {
    /// An attachment in the environment's `AttachmentStyle`: its name, with
    /// a button that removes it.
    public struct AttachmentItem: View {
      @Environment(ComposerController.self) private var controller
      private let attachment: Attachment

      public init(_ attachment: Attachment) {
        self.attachment = attachment
      }

      public var body: some View {
        let progress: Double? =
          switch attachment.status {
          case .pending: 0
          case .uploading(let progress): progress
          case .failed, .ready: nil
          }
        var isFailed = false
        if case .failed = attachment.status { isFailed = true }
        return Composer.StyledAttachment(
          .init(
            label: HStack(spacing: 4) {
              Image(systemName: isFailed ? "exclamationmark.triangle" : "doc")
              Text(attachment.name ?? "Attachment").lineLimit(1)
              Button {
                controller.removeAttachment(attachment.id)
              } label: {
                Image(systemName: "xmark.circle.fill")
              }
              .buttonStyle(.plain)
              .accessibilityLabel(Text("Remove"))
            }
            .padding(6),
            progress: progress, isFailed: isFailed))
      }
    }
  }

  /// Bridges a button's pressed state into `ComposerActionStyle`.
  struct ActionButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
      Composer.StyledAction(
        .init(label: configuration.label, isEnabled: isEnabled, isPressed: configuration.isPressed)
      )
    }
  }
#endif
