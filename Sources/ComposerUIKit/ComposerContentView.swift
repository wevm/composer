// Read-only content on iOS: a sent message, drawn as the input draws it.
#if canImport(UIKit)
  import ComposerCore
  import UIKit

  /// A sent message, read-only: the same TextKit rendering and text styles
  /// as the input, with the text selectable. Tapping a token calls
  /// `onTapNode`, and tapping a link calls `onOpenLink` (which opens it unless
  /// it returns `true`). iPad pointer hover over a token or link publishes it
  /// on `hover`, and `contextMenuProvider` gives a long-press on one a menu.
  open class ComposerContentView: ComposerTextView {
    public var onTapNode: ((AtomicNode) -> Void)?
    public var onOpenLink: ((URL) -> Bool)?
    private let tracker = HoverTracker()
    private lazy var targetTap = UITapGestureRecognizer(
      target: self, action: #selector(tappedTarget(_:)))

    /// The content view's own hover: the token or link to show a card for.
    open override var hover: HoverTracker { tracker }

    /// - Parameter schema: the node types the document uses, for their
    ///   fallback text and token styles: an input's `controller.schema`, or
    ///   `Schema(plugins:)`.
    public init(
      document: Document, schema: Schema = Schema(),
      frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 44)
    ) {
      super.init(
        controller: ComposerController(
          EditorState(document: document, selection: .caret(0)), plugins: [SchemaPlugin(schema)]),
        frame: frame)
      isEditable = false
      isSelectable = true
      isScrollEnabled = false
      lineLimits = 1...10_000
      addGestureRecognizer(targetTap)
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

    open override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      if recognizer === targetTap {
        guard let target = hoverTarget(at: recognizer.location(in: self)) else { return false }
        if case .node = target.kind { return onTapNode != nil }
        return true
      }
      return super.gestureRecognizerShouldBegin(recognizer)
    }

    @objc private func tappedTarget(_ recognizer: UITapGestureRecognizer) {
      guard let target = hoverTarget(at: recognizer.location(in: self)) else { return }
      switch target.kind {
      case .node(let node):
        onTapNode?(node)
      case .link(let destination):
        guard let url = URL(string: destination) else { return }
        if onOpenLink?(url) != true { UIApplication.shared.open(url) }
      }
    }
  }
#endif
