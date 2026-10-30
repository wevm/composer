// The style protocols, after `ButtonStyle`: each has a `Configuration` that
// carries the state a style renders (highlighted, enabled, progress), an
// environment value, and a modifier that sets it. The views that apply them
// arrive with their slots' data: actions and attachments in milestone 8,
// suggestions in milestone 7.
#if canImport(SwiftUI)
  import SwiftUI

  // MARK: Actions

  /// The appearance of a composer action, such as send or attach.
  public protocol ComposerActionStyle {
    associatedtype Body: View
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ComposerActionStyleConfiguration
  }

  public struct ComposerActionStyleConfiguration {
    /// The action's label, as the consumer or plugin provides it.
    public struct Label: View {
      let content: AnyView
      public var body: some View { content }
    }

    public let label: Label
    public let isEnabled: Bool
    /// Whether the action is being pressed.
    public let isPressed: Bool

    public init(label: some View, isEnabled: Bool, isPressed: Bool) {
      self.label = Label(content: AnyView(label))
      self.isEnabled = isEnabled
      self.isPressed = isPressed
    }
  }

  /// The default: the label as it is, dimmed while disabled.
  public struct DefaultComposerActionStyle: ComposerActionStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .opacity(configuration.isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
  }

  extension ComposerActionStyle where Self == DefaultComposerActionStyle {
    public static var automatic: Self { Self() }
  }

  // MARK: Suggestions

  /// The appearance of a row in the suggestions list.
  public protocol SuggestionItemStyle {
    associatedtype Body: View
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = SuggestionItemStyleConfiguration
  }

  public struct SuggestionItemStyleConfiguration {
    public struct Label: View {
      let content: AnyView
      public var body: some View { content }
    }

    public let label: Label
    /// Whether the row is the one Return would pick.
    public let isHighlighted: Bool

    public init(label: some View, isHighlighted: Bool) {
      self.label = Label(content: AnyView(label))
      self.isHighlighted = isHighlighted
    }
  }

  /// The default: the label, on the tint while highlighted.
  public struct DefaultSuggestionItemStyle: SuggestionItemStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          configuration.isHighlighted ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
          in: .rect(cornerRadius: 6))
    }
  }

  extension SuggestionItemStyle where Self == DefaultSuggestionItemStyle {
    public static var automatic: Self { Self() }
  }

  // MARK: Attachments

  /// The appearance of an attachment in the tray.
  public protocol AttachmentStyle {
    associatedtype Body: View
    @MainActor @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = AttachmentStyleConfiguration
  }

  public struct AttachmentStyleConfiguration {
    public struct Label: View {
      let content: AnyView
      public var body: some View { content }
    }

    public let label: Label
    /// Upload progress from 0 to 1, or `nil` once uploaded.
    public let progress: Double?
    public let isFailed: Bool

    public init(label: some View, progress: Double?, isFailed: Bool) {
      self.label = Label(content: AnyView(label))
      self.progress = progress
      self.isFailed = isFailed
    }
  }

  /// The default: the label, with a progress bar while uploading.
  public struct DefaultAttachmentStyle: AttachmentStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .overlay(alignment: .bottom) {
          if let progress = configuration.progress {
            ProgressView(value: progress).padding(4)
          }
        }
        .opacity(configuration.isFailed ? 0.5 : 1)
    }
  }

  extension AttachmentStyle where Self == DefaultAttachmentStyle {
    public static var automatic: Self { Self() }
  }

  // MARK: Environment

  extension EnvironmentValues {
    @Entry package var composerActionStyle: any ComposerActionStyle = DefaultComposerActionStyle()
    @Entry package var suggestionItemStyle: any SuggestionItemStyle = DefaultSuggestionItemStyle()
    @Entry package var attachmentStyle: any AttachmentStyle = DefaultAttachmentStyle()
  }

  extension View {
    public func composerActionStyle(_ style: some ComposerActionStyle) -> some View {
      environment(\.composerActionStyle, style)
    }

    public func suggestionItemStyle(_ style: some SuggestionItemStyle) -> some View {
      environment(\.suggestionItemStyle, style)
    }

    public func attachmentStyle(_ style: some AttachmentStyle) -> some View {
      environment(\.attachmentStyle, style)
    }
  }

  extension Composer {
    /// Renders a configuration with the environment's action style, for
    /// views that show actions.
    public struct StyledAction: View {
      @Environment(\.composerActionStyle) private var style
      private let configuration: ComposerActionStyleConfiguration

      public init(_ configuration: ComposerActionStyleConfiguration) {
        self.configuration = configuration
      }

      public var body: some View {
        AnyView(style.makeBody(configuration: configuration))
      }
    }

    /// Renders a configuration with the environment's suggestion item
    /// style.
    public struct StyledSuggestionItem: View {
      @Environment(\.suggestionItemStyle) private var style
      private let configuration: SuggestionItemStyleConfiguration

      public init(_ configuration: SuggestionItemStyleConfiguration) {
        self.configuration = configuration
      }

      public var body: some View {
        AnyView(style.makeBody(configuration: configuration))
      }
    }

    /// Renders a configuration with the environment's attachment style.
    public struct StyledAttachment: View {
      @Environment(\.attachmentStyle) private var style
      private let configuration: AttachmentStyleConfiguration

      public init(_ configuration: AttachmentStyleConfiguration) {
        self.configuration = configuration
      }

      public var body: some View {
        AnyView(style.makeBody(configuration: configuration))
      }
    }
  }
#endif
