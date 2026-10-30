// Read-only content: `Composer.Content` renders a sent message, as a `Text`
// by default and with the native `ComposerContentView` (TextKit) when hover
// or context menus need it.
#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
  import SwiftUI
  #if canImport(UIKit)
    import ComposerUIKit
    import UIKit
  #else
    import AppKit
    import ComposerAppKit
  #endif

  /// How `Composer.Content` renders.
  public enum ComposerContentRenderer: Sendable, Hashable {
    /// `Text`, unless hover or context menu handlers are attached, which
    /// need TextKit.
    case automatic
    /// `Text(AttributedString)`: the cheapest, for long lists.
    case text
    /// The native `ComposerContentView`.
    case textKit
  }

  /// An item of a token's or link's context menu.
  public struct ComposerMenuItem: Identifiable {
    public let id = UUID()
    public var title: String
    public var systemImage: String?
    public var isDestructive: Bool
    public var action: @MainActor () -> Void

    public init(
      _ title: String, systemImage: String? = nil, isDestructive: Bool = false,
      action: @escaping @MainActor () -> Void
    ) {
      self.title = title
      self.systemImage = systemImage
      self.isDestructive = isDestructive
      self.action = action
    }
  }

  extension EnvironmentValues {
    @Entry var composerContentRenderer = ComposerContentRenderer.automatic
    @Entry var composerTapNode: (@MainActor (AtomicNode) -> Void)? = nil
    @Entry var composerHoverNode: (@MainActor (HoverTarget?) -> Void)? = nil
    @Entry var composerNodeMenu: (@MainActor (HoverTarget) -> [ComposerMenuItem])? = nil
  }

  extension View {
    /// Forces a renderer for the `Composer.Content` inside.
    public func contentRenderer(_ renderer: ComposerContentRenderer) -> some View {
      environment(\.composerContentRenderer, renderer)
    }

    /// Called when a token is tapped in the `Composer.Content` inside.
    /// Links still open with `openURL`.
    public func onTapNode(_ action: @escaping @MainActor (AtomicNode) -> Void) -> some View {
      environment(\.composerTapNode, action)
    }

    /// Called with the hovered token or link, and its anchor in the content
    /// view, after the hover delay, and with `nil` when the hover ends.
    /// Switches `Composer.Content` to TextKit.
    public func onHoverNode(_ action: @escaping @MainActor (HoverTarget?) -> Void) -> some View {
      environment(\.composerHoverNode, action)
    }

    /// A context menu for tokens and links (secondary click, or long-press
    /// on iOS). Return no items for no menu. Switches `Composer.Content` to
    /// TextKit.
    public func contextMenuNode(
      _ items: @escaping @MainActor (HoverTarget) -> [ComposerMenuItem]
    ) -> some View {
      environment(\.composerNodeMenu, items)
    }
  }

  extension Composer {
    /// A sent message, read-only, in the input's text styles. Token styles
    /// follow `.composerTextStyle(for:)`; `.onTapNode` sees taps on tokens.
    public struct Content: View {
      @Environment(\.composerContentRenderer) private var renderer
      @Environment(\.composerTapNode) private var tapNode
      @Environment(\.composerHoverNode) private var hoverNode
      @Environment(\.composerNodeMenu) private var nodeMenu
      @Environment(\.composerTokenStyles) private var tokenStyles
      @Environment(\.openURL) private var openURL
      private let document: Document
      private let schema: Schema

      /// - Parameter schema: the node types the document uses, for their
      ///   fallback text and token styles: an input's `controller.schema`,
      ///   or `Schema(plugins:)`.
      public init(_ document: Document, schema: Schema = Schema()) {
        self.document = document
        self.schema = schema
      }

      var usesTextKit: Bool {
        switch renderer {
        case .text: false
        case .textKit: true
        case .automatic: hoverNode != nil || nodeMenu != nil
        }
      }

      public var body: some View {
        if usesTextKit {
          ContentView(
            document: document, schema: schema, tokenStyles: tokenStyles, tapNode: tapNode,
            hoverNode: hoverNode, nodeMenu: nodeMenu, openURL: openURL)
        } else {
          Text(Self.styled(ContentRenderer(schema: schema).attributedString(document), tokenStyles))
            .environment(
              \.openURL,
              OpenURLAction { url in
                guard let node = AtomicNode(url: url) else { return .systemAction }
                tapNode?(node)
                return tapNode == nil ? .discarded : .handled
              })
        }
      }

      /// Core's rendering, with SwiftUI's attributes for what `Text` can't
      /// infer: token colors, decoration, and code blocks.
      static func styled(_ string: AttributedString, _ overrides: TokenStyles) -> AttributedString {
        var styled = string
        for run in string.runs {
          if var style = run[ComposerAttributes.TokenStyleAttribute.self] {
            if let node = run[ComposerAttributes.NodeAttribute.self],
              let override = overrides.overrides[node.type]
            {
              style = override(style)
            }
            if let foreground = style.foreground {
              styled[run.range].foregroundColor = Color(foreground)
            }
            if let background = style.background {
              styled[run.range].backgroundColor = Color(background).opacity(
                style.backgroundOpacity)
            }
            if style.isBold { styled[run.range].inlinePresentationIntent = .stronglyEmphasized }
          } else if run[ComposerAttributes.DecorationAttribute.self] == true {
            styled[run.range].foregroundColor = .secondary
          } else if run[ComposerAttributes.CodeBlockAttribute.self] == true {
            styled[run.range].backgroundColor = Color.secondary.opacity(0.12)
          }
        }
        return styled
      }
    }
  }

  extension Color {
    init(_ color: TokenStyle.Color) {
      switch color {
      case .accent: self = .accentColor
      case .primary: self = .primary
      case .secondary: self = .secondary
      case .rgb(let red, let green, let blue): self = Color(red: red, green: green, blue: blue)
      }
    }
  }

  /// The size content takes: the proposed width, and the height its text
  /// needs at that width.
  @MainActor private func contentSize(
    _ proposal: ProposedViewSize, view: ComposerContentView
  ) -> CGSize {
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? view.frame.width
    if view.frame.width != width { view.frame.size.width = width }
    return CGSize(width: width, height: view.fittingHeight)
  }

  @MainActor private func configure(
    _ view: ComposerContentView, document: Document, tokenStyles: TokenStyles,
    tapNode: (@MainActor (AtomicNode) -> Void)?, hoverNode: (@MainActor (HoverTarget?) -> Void)?,
    nodeMenu: (@MainActor (HoverTarget) -> [ComposerMenuItem])?, openURL: OpenURLAction,
    coordinator: ContentCoordinator
  ) {
    view.document = document
    if tokenStyles.version != coordinator.tokenStyles {
      coordinator.tokenStyles = tokenStyles.version
      view.tokenStyles = tokenStyles.overrides
    }
    view.onTapNode = tapNode.map { tap in { node in tap(node) } }
    view.onOpenLink = { url in
      openURL(url)
      return true
    }
    coordinator.hoverNode = hoverNode
    coordinator.observe(view.hover)
    if let nodeMenu {
      view.contextMenuProvider = { target in
        let items = nodeMenu(target)
        return items.isEmpty ? nil : nativeMenu(items)
      }
    } else {
      view.contextMenuProvider = nil
    }
  }

  /// Follows a content view's hover for `onHoverNode`.
  @MainActor final class ContentCoordinator {
    var tokenStyles: [NodeType: Int] = [:]
    var hoverNode: (@MainActor (HoverTarget?) -> Void)?
    private var observed: HoverTracker?

    func observe(_ tracker: HoverTracker) {
      guard observed !== tracker else { return }
      observed = tracker
      track()
    }

    private func track() {
      guard let tracker = observed else { return }
      let target = withObservationTracking {
        tracker.target
      } onChange: { [weak self] in
        Task { @MainActor in self?.track() }
      }
      hoverNode?(target)
    }
  }

  #if canImport(UIKit)
    @MainActor private func nativeMenu(_ items: [ComposerMenuItem]) -> UIMenu {
      UIMenu(
        children: items.map { item in
          UIAction(
            title: item.title, image: item.systemImage.flatMap { UIImage(systemName: $0) },
            attributes: item.isDestructive ? .destructive : []
          ) { _ in item.action() }
        })
    }

    private struct ContentView: UIViewRepresentable {
      let document: Document
      let schema: Schema
      let tokenStyles: TokenStyles
      let tapNode: (@MainActor (AtomicNode) -> Void)?
      let hoverNode: (@MainActor (HoverTarget?) -> Void)?
      let nodeMenu: (@MainActor (HoverTarget) -> [ComposerMenuItem])?
      let openURL: OpenURLAction

      func makeCoordinator() -> ContentCoordinator { ContentCoordinator() }

      func makeUIView(context: Context) -> ComposerContentView {
        let view = ComposerContentView(document: document, schema: schema)
        view.backgroundColor = .clear
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
      }

      func updateUIView(_ view: ComposerContentView, context: Context) {
        configure(
          view, document: document, tokenStyles: tokenStyles, tapNode: tapNode,
          hoverNode: hoverNode, nodeMenu: nodeMenu, openURL: openURL,
          coordinator: context.coordinator)
      }

      func sizeThatFits(
        _ proposal: ProposedViewSize, uiView view: ComposerContentView, context: Context
      ) -> CGSize? {
        contentSize(proposal, view: view)
      }
    }
  #else
    @MainActor private func nativeMenu(_ items: [ComposerMenuItem]) -> NSMenu {
      let menu = NSMenu()
      for item in items {
        let entry = MenuAction(item)
        menu.addItem(entry)
      }
      return menu
    }

    /// A menu item that runs a closure.
    @MainActor private final class MenuAction: NSMenuItem {
      private let run: @MainActor () -> Void

      init(_ item: ComposerMenuItem) {
        run = item.action
        super.init(title: item.title, action: #selector(runItem), keyEquivalent: "")
        target = self
        if let image = item.systemImage {
          self.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
        }
      }

      required init(coder: NSCoder) { fatalError("not used") }

      @objc private func runItem() { run() }
    }

    private struct ContentView: NSViewRepresentable {
      let document: Document
      let schema: Schema
      let tokenStyles: TokenStyles
      let tapNode: (@MainActor (AtomicNode) -> Void)?
      let hoverNode: (@MainActor (HoverTarget?) -> Void)?
      let nodeMenu: (@MainActor (HoverTarget) -> [ComposerMenuItem])?
      let openURL: OpenURLAction

      func makeCoordinator() -> ContentCoordinator { ContentCoordinator() }

      func makeNSView(context: Context) -> ComposerContentView {
        ComposerContentView(document: document, schema: schema)
      }

      func updateNSView(_ view: ComposerContentView, context: Context) {
        configure(
          view, document: document, tokenStyles: tokenStyles, tapNode: tapNode,
          hoverNode: hoverNode, nodeMenu: nodeMenu, openURL: openURL,
          coordinator: context.coordinator)
      }

      func sizeThatFits(
        _ proposal: ProposedViewSize, nsView view: ComposerContentView, context: Context
      ) -> CGSize? {
        contentSize(proposal, view: view)
      }
    }
  #endif
#endif
