// The reference design, for SwiftUI and native, and the String Catalog with
// its labels. Built only from the public styles and slots, which proves they
// are enough. Empty off Apple platforms.
#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
  import ComposerSwiftUI
  import SwiftUI

  /// A string from ComposerStyled's catalog.
  func styledText(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
  }

  /// The reference composer: the reply or edit banner, the attachments
  /// tray, the suggestions list, the input in a rounded field between the
  /// leading and trailing actions, and a length counter near a limit.
  ///
  /// ```swift
  /// StyledComposer(controller)
  /// ```
  public struct StyledComposer: View {
    private let controller: ComposerController
    private let placeholder: LocalizedStringResource
    @Binding private var isExpanded: Bool

    public init(
      _ controller: ComposerController, placeholder: LocalizedStringResource? = nil,
      isExpanded: Binding<Bool> = .constant(false)
    ) {
      self.controller = controller
      self.placeholder = placeholder ?? styledText("Message")
      self._isExpanded = isExpanded
    }

    public var body: some View {
      Composer.Root(controller) {
        VStack(alignment: .leading, spacing: 6) {
          Composer.Suggestions()
            .padding(4)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
          Composer.Header { context in StyledContextBanner(context: context) }
          Composer.Attachments()
          HStack(alignment: .bottom, spacing: 8) {
            Composer.Actions(.leading)
            Composer.Input(placeholder, isExpanded: $isExpanded)
              .padding(.horizontal, 10)
              .padding(.vertical, 4)
              .background(.background, in: .rect(cornerRadius: 18))
              .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.separator))
            Composer.Actions(.trailing)
          }
          Composer.Footer { state in StyledLengthCounter(status: state[MaxLength.statusKey]) }
        }
        .composerActionStyle(.styled)
        .attachmentStyle(.styled)
        .suggestionItemStyle(.styled)
      }
    }
  }

  /// The reply or edit banner, with a button that clears the context.
  public struct StyledContextBanner: View {
    @Environment(ComposerController.self) private var controller
    let context: any ComposerContext

    public init(context: any ComposerContext) {
      self.context = context
    }

    public var body: some View {
      HStack(spacing: 6) {
        Image(systemName: context.kind == .edit ? "pencil" : "arrowshape.turn.up.left")
        Text(context.kind == .edit ? styledText("Editing message") : styledText("Replying"))
          .bold()
        Spacer(minLength: 0)
        Button {
          controller.setContext(nil)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(styledText("Cancel")))
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
    }
  }

  /// The length counter: shown from 90% of a limit, red past it.
  public struct StyledLengthCounter: View {
    let status: LengthStatus?

    public init(status: LengthStatus?) {
      self.status = status
    }

    public var body: some View {
      if let status, status.count * 10 >= status.limit * 9 {
        HStack {
          Spacer()
          Text(
            status.isOver
              ? styledText("\(-status.remaining) characters over")
              : styledText("\(status.remaining) characters left")
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(status.isOver ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 10)
      }
    }
  }

  // MARK: Styles

  /// Actions as icons in circles: the send button filled with the tint
  /// while enabled.
  public struct StyledActionStyle: ComposerActionStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 32, height: 32)
        .foregroundStyle(
          configuration.isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)
        )
        .background(
          configuration.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
          in: .circle
        )
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(.circle)
    }
  }

  extension ComposerActionStyle where Self == StyledActionStyle {
    public static var styled: Self { Self() }
  }

  /// Attachments as rounded chips, with a ring while uploading and a red
  /// border when failed.
  public struct StyledAttachmentStyle: AttachmentStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .font(.caption)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(configuration.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.clear))
        }
        .overlay(alignment: .topTrailing) {
          if let progress = configuration.progress {
            Circle()
              .trim(from: 0, to: max(progress, 0.05))
              .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
              .rotationEffect(.degrees(-90))
              .frame(width: 12, height: 12)
              .padding(4)
          }
        }
    }
  }

  extension AttachmentStyle where Self == StyledAttachmentStyle {
    public static var styled: Self { Self() }
  }

  /// Suggestion rows with a rounded highlight.
  public struct StyledSuggestionItemStyle: SuggestionItemStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(
          configuration.isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)
        )
        .background(
          configuration.isHighlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
          in: .rect(cornerRadius: 8))
    }
  }

  extension SuggestionItemStyle where Self == StyledSuggestionItemStyle {
    public static var styled: Self { Self() }
  }

  // MARK: Content and hover

  /// A sent message in the reference design, with hover cards: a link's
  /// URL as a tooltip, and for a mention, an example user card. Pass
  /// `card` to render your own for other tokens.
  public struct StyledMessage<Card: View>: View {
    private let document: Document
    private let schema: Schema
    private let card: (AtomicNode) -> Card
    @State private var hovered: HoverTarget?

    public init(
      _ document: Document, schema: Schema = Schema(),
      @ViewBuilder card: @escaping (AtomicNode) -> Card
    ) {
      self.document = document
      self.schema = schema
      self.card = card
    }

    public var body: some View {
      Composer.Content(document, schema: schema)
        .onHoverNode { hovered = $0 }
        .overlay(alignment: .topLeading) {
          if let hovered {
            Group {
              switch hovered.kind {
              case .link(let url): StyledLinkTooltip(url: url)
              case .node(let node): card(node)
              }
            }
            .fixedSize()
            .offset(x: hovered.anchor.minX, y: hovered.anchor.maxY + 4)
            .transition(.opacity)
            .allowsHitTesting(false)
          }
        }
        .animation(.easeOut(duration: 0.12), value: hovered?.range)
    }
  }

  extension StyledMessage where Card == StyledUserCard {
    public init(_ document: Document, schema: Schema = Schema()) {
      self.init(document, schema: schema) { StyledUserCard(node: $0) }
    }
  }

  /// A link's destination, as a tooltip.
  public struct StyledLinkTooltip: View {
    let url: String

    public init(url: String) {
      self.url = url
    }

    public var body: some View {
      Text(url)
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
  }

  /// An example user card for a mention: its initial, label, and id.
  public struct StyledUserCard: View {
    let node: AtomicNode

    public init(node: AtomicNode) {
      self.node = node
    }

    public var body: some View {
      HStack(spacing: 10) {
        Text(String(node.label.prefix(1)).uppercased())
          .font(.headline)
          .foregroundStyle(.white)
          .frame(width: 36, height: 36)
          .background(.tint, in: .circle)
        VStack(alignment: .leading, spacing: 2) {
          Text(node.label).font(.headline)
          if let id = node.attributes["id"] {
            Text(id).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding(10)
      .background(.regularMaterial, in: .rect(cornerRadius: 12))
      .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
  }
#endif
