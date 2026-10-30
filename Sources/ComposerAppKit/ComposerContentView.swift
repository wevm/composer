// Read-only content on macOS: a sent message, drawn as the input draws it.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import ComposerCore

  /// A sent message, read-only: the same TextKit rendering and text styles
  /// as the input, with the text selectable. Clicking a token calls
  /// `onTapNode`, and clicking a link calls `onOpenLink` (which opens it in
  /// the browser unless it returns `true`). Hovering a token or link
  /// publishes it on `hover`, and `contextMenuProvider` gives right-clicks
  /// on them a menu.
  open class ComposerContentView: ComposerTextView {
    public var onTapNode: ((AtomicNode) -> Void)?
    public var onOpenLink: ((URL) -> Bool)?
    private let tracker = HoverTracker()

    /// The content view's own hover: the token or link to show a card for.
    open override var hover: HoverTracker { tracker }

    /// - Parameter schema: the node types the document uses, for their
    ///   fallback text and token styles: an input's `controller.schema`, or
    ///   `Schema(plugins:)`.
    public init(
      document: Document, schema: Schema = Schema(),
      frame: NSRect = NSRect(x: 0, y: 0, width: 320, height: 40)
    ) {
      super.init(
        controller: ComposerController(
          EditorState(document: document, selection: .caret(0)), plugins: [SchemaPlugin(schema)]),
        frame: frame)
      isEditable = false
      isSelectable = true
      lineLimits = 1...10_000
    }

    public required init?(coder: NSCoder) {
      fatalError("ComposerContentView is created in code")
    }

    public var document: Document {
      get { controller.document }
      set {
        guard newValue != controller.document else { return }
        controller.restore(EditorState(document: newValue, selection: .caret(0)))
      }
    }

    open override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      if event.clickCount == 1, let target = hoverTarget(at: point) {
        switch target.kind {
        case .node(let node):
          if let onTapNode {
            hover.dismiss()
            onTapNode(node)
            return
          }
        case .link(let destination):
          if let url = URL(string: destination) {
            hover.dismiss()
            if onOpenLink?(url) != true { NSWorkspace.shared.open(url) }
            return
          }
        }
      }
      super.mouseDown(with: event)
    }
  }
#endif
