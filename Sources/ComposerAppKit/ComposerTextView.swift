// The AppKit engine: `ComposerTextView`, a TextKit 2 `NSTextView` that
// implements `TextEngine`. Empty off AppKit.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import ComposerCore
  @_exported import ComposerTextKit

  /// A composer's text view on macOS: TextKit 2, driven by a
  /// `ComposerController`.
  ///
  /// The view never edits its own text. Typing, IME marked text, deletion,
  /// paste, drops, and corrections go to the controller as input, and the
  /// view applies each update's changeset to its text storage, so the
  /// document stays the source of truth and every engine edits the same way.
  /// Undo goes through the view's `UndoManager`, and keys go through the
  /// controller's keymap before AppKit's key bindings.
  open class ComposerTextView: NSTextView, TextEngine {
    public let controller: ComposerController

    /// The fonts, colors, and metrics the text renders with.
    public var textStyles: TextStyles {
      didSet { reloadStyles() }
    }

    /// Restyles tokens of a node type, over their plugin's style.
    public var tokenStyles: [NodeType: TokenStyleOverride] = [:] {
      didSet { reloadStyles() }
    }

    /// The undo manager updates register with. By default, the window's.
    public var composerUndoManager: UndoManager? {
      didSet { controller.undoManager = undoManager }
    }

    /// Shown while the document is empty.
    public var placeholder: String? {
      didSet { syncPlaceholder(force: true) }
    }

    /// The lines the view's intrinsic height grows between: it fits its
    /// text from the lower bound to the upper. In a scroll view, the scroll
    /// view's intrinsic height follows it, and the text scrolls beyond.
    public var lineLimits: ClosedRange<Int> = 1...12 {
      didSet { textDidChangeHeight() }
    }

    /// The height that fits the text within `lineLimits`, at the view's
    /// width, including the text container's insets.
    public var fittingHeight: CGFloat {
      if let fitting, fitting.width == frame.width { return fitting.height }
      let height =
        textLayoutManager.map {
          TextSizing.fittingHeight(
            of: $0, lineLimits: lineLimits, font: textStyles.base,
            verticalInsets: textContainerInset.height * 2)
        } ?? 0
      fitting = (frame.width, height)
      return height
    }

    open override var intrinsicContentSize: NSSize {
      NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight)
    }

    /// The last fitting height and the width it was measured at. `nil` until
    /// something asks, so a view sized another way never measures.
    private var fitting: (width: CGFloat, height: CGFloat)?
    private let placeholderLabel: NSTextField = {
      let label = NSTextField(wrappingLabelWithString: "")
      label.textColor = .placeholderTextColor
      label.isHidden = true
      label.setAccessibilityElement(false)
      return label
    }()
    private var mapper: AttributeMapper
    /// Document positions to storage offsets: tokens draw as several
    /// characters.
    package private(set) var storageMap = StorageMap(document: Document()) { _ in 1 }
    private var fragmentProvider: LayoutFragmentProvider
    private let contentStorage: NSTextContentStorage
    /// Set while the view applies a changeset (and during setup), when its
    /// own selection and text changes aren't input.
    private var isApplying = true
    /// Set while a key event is handled, when a selection change that keeps
    /// one end is an extension from that end.
    private var isHandlingKey = false
    /// The modifiers of the key event being handled.
    private var keyModifiers: KeyModifiers = []
    private var renderedMarkedText: MarkedText?

    public init(
      controller: ComposerController, frame: NSRect = NSRect(x: 0, y: 0, width: 320, height: 40)
    ) {
      let styles = TextStyles.standard
      self.controller = controller
      self.textStyles = styles
      self.mapper = AttributeMapper(styles: styles, schema: controller.schema)
      self.fragmentProvider = LayoutFragmentProvider(styles: styles)
      let contentStorage = NSTextContentStorage()
      let layoutManager = NSTextLayoutManager()
      contentStorage.addTextLayoutManager(layoutManager)
      let container = NSTextContainer(
        size: NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.textContainer = container
      self.contentStorage = contentStorage
      super.init(frame: frame, textContainer: container)
      layoutManager.delegate = fragmentProvider
      configure()
      controller.engine = self
      reload()
      isApplying = false
    }

    public required init?(coder: NSCoder) {
      fatalError("ComposerTextView is created in code")
    }

    private func configure() {
      isRichText = true
      importsGraphics = false
      allowsUndo = false
      allowsImageEditing = false
      smartInsertDeleteEnabled = false
      isAutomaticQuoteSubstitutionEnabled = false
      isAutomaticDashSubstitutionEnabled = false
      isAutomaticTextReplacementEnabled = false
      isAutomaticLinkDetectionEnabled = false
      isAutomaticDataDetectionEnabled = false
      drawsBackground = false
      isVerticallyResizable = true
      isHorizontallyResizable = false
      autoresizingMask = [.width]
      textContainerInset = NSSize(width: 2, height: 6)
      typingAttributes = [.font: textStyles.base, .foregroundColor: textStyles.foreground]
    }

    /// Renders the whole document again, with the controller's selection.
    private func reload() {
      guard let textStorage else { return }
      let wasApplying = isApplying
      isApplying = true
      defer { isApplying = wasApplying }
      ChangesetApplier.load(controller.document, into: textStorage, mapper: mapper)
      storageMap = mapper.storageMap(for: controller.document)
      renderedMarkedText = nil
      syncMarkedText(controller.state.markedText)
      setSelectedRange(storageMap.storage(controller.selection.range))
      textDidChangeHeight()
      syncPlaceholder(force: true)
    }

    private func syncPlaceholder(force: Bool = false) {
      let hidden = placeholder == nil || !controller.isEmpty
      guard force || placeholderLabel.isHidden != hidden else { return }
      placeholderLabel.stringValue = placeholder ?? ""
      placeholderLabel.font = textStyles.base
      placeholderLabel.isHidden = hidden
      if !hidden {
        if placeholderLabel.superview == nil { addSubview(placeholderLabel) }
        layOutPlaceholder()
      }
    }

    private func layOutPlaceholder() {
      guard !placeholderLabel.isHidden, let textContainer else { return }
      let origin = textContainerOrigin
      let padding = textContainer.lineFragmentPadding
      let width = max(bounds.width - origin.x * 2 - padding * 2, 0)
      let height =
        placeholderLabel.cell?.cellSize(
          forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        ).height ?? 0
      placeholderLabel.frame = NSRect(
        x: origin.x + padding, y: origin.y, width: width, height: height)
    }

    /// Measures the fitting height again, if it was measured, and
    /// invalidates the intrinsic size, and the enclosing scroll view's, if
    /// it changed.
    private func textDidChangeHeight() {
      guard let previous = fitting else { return }
      fitting = nil
      if fittingHeight != previous.height {
        invalidateIntrinsicContentSize()
        enclosingScrollView?.invalidateIntrinsicContentSize()
      }
    }

    open override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      layOutPlaceholder()
      if let fitting, fitting.width != newSize.width { textDidChangeHeight() }
    }

    private func reloadStyles() {
      mapper = AttributeMapper(
        styles: textStyles, schema: controller.schema, tokenStyles: tokenStyles)
      fragmentProvider = LayoutFragmentProvider(styles: textStyles)
      textLayoutManager?.delegate = fragmentProvider
      typingAttributes = [.font: textStyles.base, .foregroundColor: textStyles.foreground]
      reload()
    }

    // MARK: TextEngine

    public func apply(_ changeset: Changeset, from state: EditorState) {
      guard let textStorage else { return }
      isApplying = true
      defer { isApplying = false }
      let old = storageMap
      if !changeset.edits.isEmpty { storageMap = mapper.storageMap(for: state.document) }
      ChangesetApplier.apply(
        changeset, document: state.document, to: textStorage, mapper: mapper, old: old,
        new: storageMap)
      syncMarkedText(state.markedText)
      let range = storageMap.storage(state.selection.range)
      if selectedRange() != range { setSelectedRange(range) }
      if !changeset.edits.isEmpty {
        syncPlaceholder()
        textDidChangeHeight()
        scrollRangeToVisible(range)
      }
      inputContext?.invalidateCharacterCoordinates()
    }

    public var selectionRects: [CGRect] {
      rects(for: selectedRange())
    }

    public func rect(for range: DocumentRange) -> CGRect {
      rects(for: storageMap.storage(range)).reduce(CGRect.null) { $0.union($1) }
    }

    private func rects(for range: NSRange) -> [CGRect] {
      guard let textLayoutManager else { return [] }
      let origin = textContainerOrigin
      return textLayoutManager.segmentRects(for: range).map {
        $0.offsetBy(dx: origin.x, dy: origin.y)
      }
    }

    /// Underlines the marked text. The underline is a rendering attribute,
    /// not part of the text storage, which mirrors the document.
    private func syncMarkedText(_ marked: MarkedText?) {
      guard marked != renderedMarkedText, let textLayoutManager,
        let contentManager = textLayoutManager.textContentManager
      else { return }
      renderedMarkedText = marked
      textLayoutManager.removeRenderingAttribute(
        .underlineStyle, for: contentManager.documentRange)
      if let marked, let range = contentManager.textRange(for: storageMap.storage(marked.range)) {
        textLayoutManager.addRenderingAttribute(
          .underlineStyle, value: NSUnderlineStyle.single.rawValue, for: range)
      }
    }

    // MARK: Focus

    open override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became, !controller.isFocused { controller.isFocused = true }
      return became
    }

    open override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned, controller.isFocused { controller.isFocused = false }
      return resigned
    }

    // MARK: Text input

    open override func insertText(_ string: Any, replacementRange: NSRange) {
      controller.insertText(
        Self.plainText(string), replacing: documentRange(replacementRange))
    }

    open override func setMarkedText(
      _ string: Any, selectedRange: NSRange, replacementRange: NSRange
    ) {
      let text = Self.plainText(string)
      let length = text.utf16.count
      let selected =
        selectedRange.location == NSNotFound
        ? length..<length : selectedRange.location..<NSMaxRange(selectedRange)
      controller.setMarkedText(
        text, selectedRange: selected, replacing: documentRange(replacementRange))
    }

    open override func unmarkText() {
      guard !isApplying else { return }
      controller.unmarkText()
    }

    open override func hasMarkedText() -> Bool {
      controller.state.markedText != nil
    }

    open override func markedRange() -> NSRange {
      guard let marked = controller.state.markedText else {
        return NSRange(location: NSNotFound, length: 0)
      }
      return storageMap.storage(marked.range)
    }

    /// Every other change AppKit would make to the text (drops, spelling
    /// corrections, word and line deletion, services) becomes input instead.
    open override func shouldChangeText(
      inRanges affectedRanges: [NSValue], replacementStrings: [String]?
    ) -> Bool {
      if isApplying { return true }
      guard let replacementStrings, replacementStrings.count == affectedRanges.count else {
        return false  // Attribute changes: the document owns the attributes.
      }
      for (range, string) in zip(affectedRanges, replacementStrings).reversed() {
        controller.insertText(
          documentText(string), replacing: storageMap.document(range.rangeValue))
      }
      return false
    }

    open override func setSelectedRanges(
      _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
      super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
      // AppKit may have adjusted the ranges (to whole characters, say).
      guard !isApplying else { return }
      let current = controller.selection
      let selection = inferredSelection(
        selectedRange(), previous: current, fromKeyboard: isHandlingKey, map: storageMap)
      guard selection != current else { return }
      let wasMarked = hasMarkedText()
      controller.selection = selection
      if wasMarked, !hasMarkedText() { inputContext?.discardMarkedText() }
    }

    // MARK: Mouse

    /// A click on a task's box checks or unchecks it.
    open override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let origin = textContainerOrigin
      if let textLayoutManager,
        let offset = textLayoutManager.taskBox(
          at: CGPoint(x: point.x - origin.x, y: point.y - origin.y)),
        controller.run(Command<Position>.toggleTask, Position(storageMap.document(offset)))
      {
        return
      }
      super.mouseDown(with: event)
    }

    // MARK: Keys

    private static let editingKeys: Set<Key> = [.return, .tab, .delete, .forwardDelete]
    private static let navigationKeys: Set<Key> = [
      .escape, .upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end, .pageUp, .pageDown,
    ]

    /// Keys go to the controller first: its keymap, then the default action
    /// for ↩, ⇥, ⌫, and ⌦. Unhandled ↩ and ⇥ combinations do nothing.
    /// Everything else (caret movement, word deletion, the input method) is
    /// AppKit's. While marked text exists, every key goes to the input
    /// method.
    open override func keyDown(with event: NSEvent) {
      isHandlingKey = true
      keyModifiers = KeyModifiers(event.modifierFlags)
      defer {
        isHandlingKey = false
        keyModifiers = []
      }
      if !hasMarkedText(), let key = Key(event: event) {
        let modifiers = keyModifiers
        if Self.editingKeys.contains(key) {
          if controller.handleKeyPress(key, modifiers: modifiers) { return }
          if key == .return || key == .tab { return }
        } else if Self.navigationKeys.contains(key),
          controller.handleKey(key, modifiers: modifiers)
        {
          return
        }
      }
      super.keyDown(with: event)
    }

    /// ⌘ and ⌃ combinations try the keymap before menus.
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
      if window?.firstResponder === self, !hasMarkedText(), let key = Key(event: event) {
        let modifiers = KeyModifiers(event.modifierFlags)
        if !modifiers.isDisjoint(with: [.command, .control]),
          controller.handleKey(key, modifiers: modifiers)
        {
          return true
        }
      }
      return super.performKeyEquivalent(with: event)
    }

    /// Editing commands from key bindings and input methods go to the
    /// controller, as the keys they stand for. AppKit binds ⇧↩ to
    /// `insertNewline:` too, so ↩ keeps the key event's ⇧.
    open override func doCommand(by selector: Selector) {
      switch selector {
      case #selector(insertNewline(_:)):
        controller.handleKeyPress(.return, modifiers: keyModifiers.intersection(.shift))
      case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
        controller.handleKeyPress(.return, modifiers: .shift)
      case #selector(insertTab(_:)), #selector(insertTabIgnoringFieldEditor(_:)):
        controller.handleKeyPress(.tab)
      case #selector(insertBacktab(_:)):
        controller.handleKeyPress(.tab, modifiers: .shift)
      case #selector(deleteBackward(_:)),
        #selector(deleteBackwardByDecomposingPreviousCharacter(_:)):
        controller.handleKeyPress(.delete)
      case #selector(deleteForward(_:)):
        controller.handleKeyPress(.forwardDelete)
      case #selector(cancelOperation(_:)), #selector(complete(_:)):
        // Not completion: the composer's suggestions are plugins.
        controller.handleKeyPress(.escape)
      default:
        super.doCommand(by: selector)
      }
    }

    // MARK: Clipboard

    open override func paste(_ sender: Any?) { paste(from: .general) }
    open override func pasteAsPlainText(_ sender: Any?) { paste(from: .general) }
    open override func pasteAsRichText(_ sender: Any?) { paste(from: .general) }

    /// Pastes a pasteboard's plain text.
    public func paste(from pasteboard: NSPasteboard) {
      guard let string = pasteboard.string(forType: .string) else { return }
      controller.paste(.plainText(string))
    }

    /// Copies the selection as plain text, with tokens as their labels. The
    /// markdown, RTF, and document representations come with the clipboard
    /// work.
    open override func copy(_ sender: Any?) {
      let range = selectedRange()
      guard range.length > 0, let textStorage else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        clipboardText(of: textStorage.attributedSubstring(from: range)), forType: .string)
    }

    open override func cut(_ sender: Any?) {
      guard selectedRange().length > 0 else { return }
      copy(sender)
      controller.deleteBackward()
    }

    // MARK: Undo

    open override var undoManager: UndoManager? {
      composerUndoManager ?? super.undoManager
    }

    open override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      controller.undoManager = undoManager
    }

    // MARK: Testing

    /// How the text storage or selection differs from the controller's, or
    /// `nil` if they match. For the conformance suite.
    package func renderingMismatch() -> String? {
      guard let textStorage else { return "no text storage" }
      if let mismatch = ChangesetApplier.mismatch(
        of: textStorage, with: controller.document, mapper: mapper)
      {
        return mismatch
      }
      if storageMap != mapper.storageMap(for: controller.document) { return "storage map is stale" }
      let expected = storageMap.storage(controller.selection.range)
      if selectedRange() != expected {
        return "selection \(selectedRange()), expected \(expected)"
      }
      if markedRange() != NSRange(location: NSNotFound, length: 0),
        renderedMarkedText != controller.state.markedText
      {
        return "marked text underline is stale"
      }
      return nil
    }

    // MARK: Helpers

    private static func plainText(_ string: Any) -> String {
      if let string = string as? String { return string }
      if let string = string as? NSAttributedString { return string.string }
      return ""
    }

    private func documentRange(_ range: NSRange) -> DocumentRange? {
      range.location == NSNotFound ? nil : storageMap.document(range)
    }
  }

  extension Key {
    /// The key of a key event.
    public init?(event: NSEvent) {
      switch event.keyCode {
      case 36, 76: self = .return
      case 48: self = .tab
      case 51: self = .delete
      case 117: self = .forwardDelete
      case 53: self = .escape
      case 123: self = .leftArrow
      case 124: self = .rightArrow
      case 125: self = .downArrow
      case 126: self = .upArrow
      case 115: self = .home
      case 119: self = .end
      case 116: self = .pageUp
      case 121: self = .pageDown
      default:
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1 else {
          return nil
        }
        self = Key(characters)
      }
    }
  }

  extension KeyModifiers {
    public init(_ flags: NSEvent.ModifierFlags) {
      self = []
      if flags.contains(.command) { insert(.command) }
      if flags.contains(.shift) { insert(.shift) }
      if flags.contains(.option) { insert(.option) }
      if flags.contains(.control) { insert(.control) }
    }
  }
#endif
