// The UIKit engine: `ComposerTextView`, a TextKit 2 `UITextView` that
// implements `TextEngine`. Empty off UIKit.
#if canImport(UIKit)
  import ComposerCore
  @_exported import ComposerTextKit
  import UIKit

  /// A composer's text view on iOS: TextKit 2, driven by a
  /// `ComposerController`.
  ///
  /// As on macOS, the view never edits its own text. The keyboard's input
  /// (`insertText`, `deleteBackward`, marked text, and replacements such as
  /// autocorrection) goes to the controller, and the view applies each
  /// update's changeset to its text storage. Hardware keys go through
  /// `UIKeyCommand`s built from the controller's keymap, with discoverability
  /// titles for the iPad shortcut overlay.
  ///
  /// The view is its own `UITextViewDelegate`, so it sees every selection
  /// change and every edit UIKit proposes.
  open class ComposerTextView: UITextView, TextEngine, UITextViewDelegate {
    public let controller: ComposerController

    /// The fonts, colors, and metrics the text renders with.
    public var textStyles: TextStyles {
      didSet { reloadStyles() }
    }

    /// Restyles tokens of a node type, over their plugin's style.
    public var tokenStyles: [NodeType: TokenStyleOverride] = [:] {
      didSet { reloadStyles() }
    }

    /// The undo manager updates register with. By default, the view's own.
    public var composerUndoManager: UndoManager? {
      didSet { controller.undoManager = undoManager }
    }

    /// The keyboard accessory slot: a view shown above the software
    /// keyboard while the composer is focused (`inputAccessoryView`).
    public var keyboardAccessoryView: UIView? {
      get { inputAccessoryView }
      set {
        inputAccessoryView = newValue
        if isFirstResponder { reloadInputViews() }
      }
    }

    /// Shown while the document is empty.
    public var placeholder: String? {
      get { placeholderLabel.text }
      set {
        placeholderLabel.text = newValue
        syncPlaceholder()
      }
    }

    /// The lines the view's intrinsic height grows between: it fits its
    /// text from the lower bound to the upper, and scrolls beyond.
    public var lineLimits: ClosedRange<Int> = 1...8 {
      didSet { textDidChangeHeight() }
    }

    /// The height that fits the text within `lineLimits`, at the view's
    /// width, including the text container's insets. The view's intrinsic
    /// height.
    public var fittingHeight: CGFloat {
      if let fitting, fitting.width == bounds.width { return fitting.height }
      let height =
        textLayoutManager.map {
          TextSizing.fittingHeight(
            of: $0, lineLimits: lineLimits, font: textStyles.base,
            verticalInsets: textContainerInset.top + textContainerInset.bottom)
        } ?? 0
      fitting = (bounds.width, height)
      return height
    }

    open override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight)
    }

    /// The last fitting height and the width it was measured at. `nil` until
    /// something asks, so a view sized another way never measures.
    private var fitting: (width: CGFloat, height: CGFloat)?
    private let placeholderLabel = UILabel()
    private var taskTap: UITapGestureRecognizer?
    private let taskTapDelegate = TaskTapDelegate()
    private var mapper: AttributeMapper
    /// Document positions to storage offsets: tokens draw as several
    /// characters.
    package private(set) var storageMap = StorageMap(document: Document()) { _ in 1 }
    private var fragmentProvider: LayoutFragmentProvider
    private let contentStorage: NSTextContentStorage
    private let ownUndoManager = UndoManager()
    /// Set while the view applies a changeset (and during setup), when its
    /// own selection and text changes aren't input.
    private var isApplying = true
    /// Set while the input system is calling in, when it already knows
    /// about the change it asked for.
    private var isHandlingInput = false
    /// Set while a hardware key is handled, when a selection change that
    /// keeps one end is an extension from that end.
    private var isHandlingKey = false
    private var renderedMarkedText: MarkedText?

    public init(
      controller: ComposerController, frame: CGRect = CGRect(x: 0, y: 0, width: 320, height: 44)
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
        size: CGSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.textContainer = container
      self.contentStorage = contentStorage
      super.init(frame: frame, textContainer: container)
      layoutManager.delegate = fragmentProvider
      configure()
      controller.engine = self
      controller.undoManager = undoManager
      let taskTap = UITapGestureRecognizer(target: self, action: #selector(tapTaskBox(_:)))
      taskTap.delegate = taskTapDelegate
      addGestureRecognizer(taskTap)
      self.taskTap = taskTap
      addGestureRecognizer(hoverRecognizer)
      reload()
      isApplying = false
    }

    public required init?(coder: NSCoder) {
      fatalError("ComposerTextView is created in code")
    }

    private func configure() {
      delegate = self
      allowsEditingTextAttributes = false
      smartQuotesType = .no
      smartDashesType = .no
      smartInsertDeleteType = .no
      dataDetectorTypes = []
      backgroundColor = .clear
      textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
      typingAttributes = [.font: textStyles.base, .foregroundColor: textStyles.foreground]
      placeholderLabel.isHidden = true
      placeholderLabel.numberOfLines = 0
      placeholderLabel.isAccessibilityElement = false
      stylePlaceholder()
    }

    private func stylePlaceholder() {
      placeholderLabel.font = textStyles.base
      placeholderLabel.textColor = .placeholderText
    }

    /// Renders the whole document again, with the controller's selection.
    private func reload() {
      let wasApplying = isApplying
      isApplying = true
      defer { isApplying = wasApplying }
      ChangesetApplier.load(controller.document, into: textStorage, mapper: mapper)
      storageMap = mapper.storageMap(for: controller.document)
      renderedMarkedText = nil
      syncMarkedText(controller.state.markedText)
      selectedRange = storageMap.storage(controller.selection.range)
      textDidChangeHeight()
      syncPlaceholder()
    }

    private func syncPlaceholder() {
      let hidden = placeholderLabel.text == nil || !controller.isEmpty
      guard placeholderLabel.isHidden != hidden else { return }
      placeholderLabel.isHidden = hidden
      if !hidden {
        if placeholderLabel.superview == nil { addSubview(placeholderLabel) }
        setNeedsLayout()
      }
    }

    /// Measures the fitting height again, if it was measured, and
    /// invalidates the intrinsic size if it changed.
    private func textDidChangeHeight() {
      guard let previous = fitting else { return }
      fitting = nil
      if fittingHeight != previous.height { invalidateIntrinsicContentSize() }
    }

    open override func layoutSubviews() {
      super.layoutSubviews()
      if !placeholderLabel.isHidden {
        let padding = textContainer.lineFragmentPadding
        let inset = textContainerInset
        let width = bounds.width - inset.left - inset.right - padding * 2
        let size = placeholderLabel.sizeThatFits(
          CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(
          x: inset.left + padding, y: inset.top, width: width, height: size.height)
      }
      if let fitting, fitting.width != bounds.width { textDidChangeHeight() }
      // While the text fits, it doesn't scroll: a caret scrolled into view
      // before the view grew to fit it would otherwise leave the first line
      // hidden.
      if contentSize.height <= bounds.height - adjustedContentInset.top
        - adjustedContentInset.bottom, contentOffset.y != -adjustedContentInset.top
      {
        contentOffset.y = -adjustedContentInset.top
      }
    }

    private func reloadStyles() {
      mapper = AttributeMapper(
        styles: textStyles, schema: controller.schema, tokenStyles: tokenStyles)
      fragmentProvider = LayoutFragmentProvider(styles: textStyles)
      textLayoutManager?.delegate = fragmentProvider
      typingAttributes = [.font: textStyles.base, .foregroundColor: textStyles.foreground]
      stylePlaceholder()
      reload()
    }

    // MARK: TextEngine

    public func apply(_ changeset: Changeset, from state: EditorState) {
      isApplying = true
      defer { isApplying = false }
      // Changes the input system didn't ask for must be announced to it, so
      // the keyboard's autocorrection and composition stay in step.
      let notifies = !isHandlingInput
      if notifies {
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
      }
      let old = storageMap
      if let edit = changeset.combinedEdit {
        storageMap = mapper.storageMap(storageMap, after: edit, in: state.document)
      }
      ChangesetApplier.apply(
        changeset, document: state.document, to: textStorage, mapper: mapper, old: old,
        new: storageMap)
      syncMarkedText(state.markedText)
      let range = storageMap.storage(state.selection.range)
      if selectedRange != range { selectedRange = range }
      if notifies {
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
      }
      if !changeset.edits.isEmpty {
        syncPlaceholder()
        textDidChangeHeight()
        scrollRangeToVisible(range)
      }
    }

    public var selectionRects: [CGRect] {
      rects(for: selectedRange)
    }

    public func rect(for range: DocumentRange) -> CGRect {
      rects(for: storageMap.storage(range)).reduce(CGRect.null) { $0.union($1) }
    }

    private func rects(for range: NSRange) -> [CGRect] {
      guard let textLayoutManager else { return [] }
      let inset = textContainerInset
      return textLayoutManager.segmentRects(for: range).map {
        $0.offsetBy(dx: inset.left, dy: inset.top)
      }
    }

    /// Highlights and underlines the marked text, as rendering attributes:
    /// UIKit draws nothing for marked text it doesn't own.
    private func syncMarkedText(_ marked: MarkedText?) {
      guard marked != renderedMarkedText, let textLayoutManager,
        let contentManager = textLayoutManager.textContentManager
      else { return }
      renderedMarkedText = marked
      for attribute in [NSAttributedString.Key.underlineStyle, .backgroundColor] {
        textLayoutManager.removeRenderingAttribute(attribute, for: contentManager.documentRange)
      }
      if let marked, let range = contentManager.textRange(for: storageMap.storage(marked.range)) {
        textLayoutManager.addRenderingAttribute(
          .underlineStyle, value: NSUnderlineStyle.single.rawValue, for: range)
        textLayoutManager.addRenderingAttribute(
          .backgroundColor, value: tintColor.withAlphaComponent(0.18), for: range)
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

    private func input(_ body: () -> Void) {
      let wasHandlingInput = isHandlingInput
      isHandlingInput = true
      defer { isHandlingInput = wasHandlingInput }
      body()
    }

    /// Typed text. Return and Tab from the keyboard arrive here as "\n" and
    /// "\t", and run as those keys: the keymap, then the default action.
    open override func insertText(_ text: String) {
      input {
        switch text {
        case "\n": controller.handleKeyPress(.return)
        case "\t": controller.handleKeyPress(.tab)
        default: controller.insertText(text)
        }
      }
    }

    open override func deleteBackward() {
      input { controller.handleKeyPress(.delete) }
    }

    open override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
      let text = markedText ?? ""
      let length = text.utf16.count
      let selected =
        selectedRange.location == NSNotFound
        ? length..<length : selectedRange.location..<selectedRange.location + selectedRange.length
      input { controller.setMarkedText(text, selectedRange: selected) }
    }

    open override func setAttributedMarkedText(
      _ markedText: NSAttributedString?, selectedRange: NSRange
    ) {
      setMarkedText(markedText?.string, selectedRange: selectedRange)
    }

    open override func unmarkText() {
      guard !isApplying else { return }
      input { controller.unmarkText() }
    }

    open override var markedTextRange: UITextRange? {
      guard let marked = controller.state.markedText else { return nil }
      return textRange(for: storageMap.storage(marked.range))
    }

    /// Replacements from the input system: autocorrection, the candidate
    /// bar, and dictation.
    open override func replace(_ range: UITextRange, withText text: String) {
      let range = nsRange(for: range)
      input {
        controller.insertText(documentText(text), replacing: storageMap.document(range))
      }
    }

    /// Every other edit UIKit proposes (drops, Writing Tools, services)
    /// becomes input instead.
    open func textView(
      _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      if isApplying { return true }
      controller.insertText(documentText(text), replacing: storageMap.document(range))
      return false
    }

    open func textViewDidChangeSelection(_ textView: UITextView) {
      syncSelection()
    }

    open override var selectedTextRange: UITextRange? {
      get { super.selectedTextRange }
      set {
        super.selectedTextRange = newValue
        syncSelection()
      }
    }

    private func syncSelection() {
      guard !isApplying else { return }
      let current = controller.selection
      let selection = inferredSelection(
        selectedRange, previous: current, fromKeyboard: isHandlingKey, map: storageMap)
      guard selection != current else { return }
      controller.selection = selection
    }

    // MARK: Hover and context menus

    /// The menu for a long-press or secondary click on a token or link, if
    /// any.
    public var contextMenuProvider: ((HoverTarget) -> UIMenu?)? {
      didSet {
        if contextMenuProvider != nil, menuInteraction == nil {
          menuDelegate.view = self
          let interaction = UIContextMenuInteraction(delegate: menuDelegate)
          addInteraction(interaction)
          menuInteraction = interaction
        }
      }
    }
    private var menuInteraction: UIContextMenuInteraction?
    private let menuDelegate = MenuDelegate()

    /// Menus for tokens and links, from `contextMenuProvider`.
    private final class MenuDelegate: NSObject, UIContextMenuInteractionDelegate {
      weak var view: ComposerTextView?

      func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
      ) -> UIContextMenuConfiguration? {
        guard let view, let provider = view.contextMenuProvider,
          let target = view.hoverTarget(at: location), let menu = provider(target)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
      }
    }
    private lazy var hoverRecognizer = UIHoverGestureRecognizer(
      target: self, action: #selector(hovered(_:)))

    /// Where pointer moves go: the controller's tracker.
    open var hover: HoverTracker { controller.hover }

    /// The token or link drawn at a point in the view, with its rect.
    public func hoverTarget(at point: CGPoint) -> HoverTarget? {
      guard let textLayoutManager else { return nil }
      let inset = textContainerInset
      guard
        let offset = textLayoutManager.characterOffset(
          at: CGPoint(x: point.x - inset.left, y: point.y - inset.top)),
        let (kind, range) = controller.document.hoverKind(
          at: storageMap.document(offset, rounding: .down))
      else { return nil }
      return HoverTarget(kind: kind, range: range, anchor: rect(for: range))
    }

    /// iPad pointer moves feed the controller's hover.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
      switch recognizer.state {
      case .began, .changed: hover.pointer(over: hoverTarget(at: recognizer.location(in: self)))
      default: hover.pointer(over: nil)
      }
    }

    // MARK: Taps

    /// The task box at a point in the view, if any.
    private func taskBox(at point: CGPoint) -> Int? {
      let inset = textContainerInset
      return textLayoutManager?.taskBox(
        at: CGPoint(x: point.x - inset.left, y: point.y - inset.top))
    }

    open override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      if recognizer === taskTap { return taskBox(at: recognizer.location(in: self)) != nil }
      return super.gestureRecognizerShouldBegin(recognizer)
    }

    /// Lets UIKit's own text taps run alongside the task-box tap, or a tap
    /// on an unfocused view never focuses it.
    private final class TaskTapDelegate: NSObject, UIGestureRecognizerDelegate {
      func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
      ) -> Bool { true }
    }

    /// A tap on a task's box checks or unchecks it.
    @objc private func tapTaskBox(_ recognizer: UITapGestureRecognizer) {
      guard let offset = taskBox(at: recognizer.location(in: self)) else { return }
      controller.run(Command<Position>.toggleTask, Position(storageMap.document(offset)))
    }

    // MARK: Keys

    /// Key commands for the keymap's bindings, plus ⇧↩ (a line break) and
    /// ⌦. Unmodified printable keys are left to typing.
    open override var keyCommands: [UIKeyCommand]? {
      var commands = super.keyCommands ?? []
      var seen = Set<String>()
      func add(_ key: Key, _ modifiers: KeyModifiers, title: String?) {
        guard let input = key.keyCommandInput,
          seen.insert("\(input)|\(modifiers.rawValue)").inserted
        else { return }
        let command = UIKeyCommand(
          title: title ?? "", action: #selector(handleKeyCommand(_:)), input: input,
          modifierFlags: UIKeyModifierFlags(modifiers))
        if let title { command.discoverabilityTitle = title }
        command.wantsPriorityOverSystemBehavior = true
        commands.append(command)
      }
      for binding in controller.keymap.bindings
      where !binding.modifiers.isEmpty || binding.key.rawValue.count > 1 {
        add(
          binding.key, binding.modifiers,
          title: binding.discoverabilityTitle.map { String(localized: $0) })
      }
      add(.return, .shift, title: nil)
      add(.forwardDelete, [], title: nil)
      return commands
    }

    /// A key command applies only while the controller would handle its
    /// key, so arrows and other keys fall through to UIKit otherwise.
    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      if action == #selector(paste(_:)) {
        let board = UIPasteboard.general
        return board.hasStrings || board.hasImages
          || board.contains(pasteboardTypes: [ClipboardContent.documentType])
      }
      guard action == #selector(handleKeyCommand(_:)) else {
        return super.canPerformAction(action, withSender: sender)
      }
      guard let command = sender as? UIKeyCommand, let pressed = Self.key(of: command) else {
        return false
      }
      let (key, modifiers) = pressed
      if key == .return, modifiers == .shift { return true }
      if key == .forwardDelete, modifiers.isEmpty { return true }
      return !controller.keymap.bindings(for: key, modifiers: modifiers, in: controller.state)
        .isEmpty
    }

    @objc open func handleKeyCommand(_ command: UIKeyCommand) {
      guard let pressed = Self.key(of: command) else { return }
      let (key, modifiers) = pressed
      handlingKey { controller.handleKeyPress(key, modifiers: modifiers) }
    }

    /// Hardware key presses: a selection change they cause is from the
    /// keyboard (see `inferredSelection`).
    open override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      handlingKey { super.pressesBegan(presses, with: event) }
    }

    /// Runs `body` as the handling of a hardware key.
    package func handlingKey(_ body: () -> Void) {
      let wasHandlingKey = isHandlingKey
      isHandlingKey = true
      defer { isHandlingKey = wasHandlingKey }
      body()
    }

    private static func key(of command: UIKeyCommand) -> (Key, KeyModifiers)? {
      guard let input = command.input, let key = Key(keyCommandInput: input) else { return nil }
      return (key, KeyModifiers(command.modifierFlags))
    }

    // MARK: Clipboard

    open override func paste(_ sender: Any?) { paste(from: .general) }

    /// Paste and Match Style: the text as it is, without mapping.
    open override func pasteAndMatchStyle(_ sender: Any?) {
      paste(from: .general, options: PasteOptions(matchesStyle: true))
    }

    private static let htmlType = "public.html"
    private static let rtfType = "public.rtf"
    private static let imageTypes = ["public.png", "public.jpeg", "public.heic", "public.tiff"]

    /// Pastes from a pasteboard: composer's own type first, so tokens
    /// survive; then, with `RichPaste`, HTML or RTF; then images; then plain
    /// text. Paste and Match Style takes only the plain text.
    public func paste(from pasteboard: UIPasteboard, options: PasteOptions = PasteOptions()) {
      if !options.matchesStyle {
        if let json = pasteboard.data(forPasteboardType: ClipboardContent.documentType),
          controller.pasteDocument(json, options: options)
        {
          return
        }
        if controller.acceptsRichPaste {
          if let data = pasteboard.data(forPasteboardType: Self.htmlType),
            let html = String(data: data, encoding: .utf8)
          {
            controller.paste(.html(html), options: options)
            return
          }
          if let rtf = pasteboard.data(forPasteboardType: Self.rtfType),
            let (document, images) = RichText.document(fromRTF: rtf)
          {
            if !document.blocks.isEmpty { controller.paste(.document(document), options: options) }
            if !images.isEmpty { controller.paste(.files(images), options: options) }
            return
          }
        }
        if !pasteboard.hasStrings {
          let images = Self.imageTypes.compactMap { type in
            pasteboard.data(forPasteboardType: type).map {
              PastedFile(data: $0, contentType: type)
            }
          }
          if !images.isEmpty {
            controller.paste(.files(images), options: options)
            return
          }
        }
      }
      guard let string = pasteboard.string else { return }
      controller.paste(.plainText(string), options: options)
    }

    /// Copies the selection as markdown (the plain text), RTF, and
    /// composer's own type, so tokens survive from composer to composer.
    open override func copy(_ sender: Any?) {
      guard let content = controller.clipboardContent() else { return }
      write(content, to: .general)
    }

    /// Writes clipboard content to a pasteboard.
    public func write(_ content: ClipboardContent, to pasteboard: UIPasteboard) {
      var item: [String: Any] = [
        "public.utf8-plain-text": content.markdown,
        ClipboardContent.documentType: content.json,
      ]
      if let rtf = RichText.rtf(content.document, mapper: mapper) { item[Self.rtfType] = rtf }
      pasteboard.setItems([item])
    }

    open override func cut(_ sender: Any?) {
      guard selectedRange.length > 0 else { return }
      copy(sender)
      controller.deleteBackward()
    }

    // MARK: Undo

    open override var undoManager: UndoManager? {
      composerUndoManager ?? ownUndoManager
    }

    // MARK: Testing

    /// How the text storage or selection differs from the controller's, or
    /// `nil` if they match. For the conformance suite.
    package func renderingMismatch() -> String? {
      if let mismatch = ChangesetApplier.mismatch(
        of: textStorage, with: controller.document, mapper: mapper)
      {
        return mismatch
      }
      if storageMap != mapper.storageMap(for: controller.document) { return "storage map is stale" }
      let expected = storageMap.storage(controller.selection.range)
      if selectedRange != expected {
        return "selection \(selectedRange), expected \(expected)"
      }
      if renderedMarkedText != controller.state.markedText {
        return "marked text underline is stale"
      }
      return nil
    }

    // MARK: Helpers

    private func textRange(for range: NSRange) -> UITextRange? {
      guard let start = position(from: beginningOfDocument, offset: range.location),
        let end = position(from: start, offset: range.length)
      else { return nil }
      return textRange(from: start, to: end)
    }

    private func nsRange(for range: UITextRange) -> NSRange {
      let location = offset(from: beginningOfDocument, to: range.start)
      return NSRange(location: location, length: offset(from: range.start, to: range.end))
    }
  }

  extension Key {
    /// The `UIKeyCommand` input for the key.
    public var keyCommandInput: String? {
      switch self {
      case .return: "\r"
      case .tab: "\t"
      case .escape: UIKeyCommand.inputEscape
      // ⌦ first: UIKit may spell it the same as ⌫.
      case .delete: UIKeyCommand.inputDelete == "\u{8}" ? nil : "\u{8}"
      case .forwardDelete: UIKeyCommand.inputDelete
      case .upArrow: UIKeyCommand.inputUpArrow
      case .downArrow: UIKeyCommand.inputDownArrow
      case .leftArrow: UIKeyCommand.inputLeftArrow
      case .rightArrow: UIKeyCommand.inputRightArrow
      case .home: UIKeyCommand.inputHome
      case .end: UIKeyCommand.inputEnd
      case .pageUp: UIKeyCommand.inputPageUp
      case .pageDown: UIKeyCommand.inputPageDown
      default: rawValue.count == 1 ? rawValue : nil
      }
    }

    /// The key of a `UIKeyCommand` input. (A list, not a dictionary: some
    /// of UIKit's input constants share a value.)
    public init?(keyCommandInput input: String) {
      let special: [(String, Key)] = [
        ("\r", .return), ("\t", .tab), (UIKeyCommand.inputEscape, .escape),
        (UIKeyCommand.inputDelete, .forwardDelete), ("\u{8}", .delete),
        (UIKeyCommand.inputUpArrow, .upArrow),
        (UIKeyCommand.inputDownArrow, .downArrow), (UIKeyCommand.inputLeftArrow, .leftArrow),
        (UIKeyCommand.inputRightArrow, .rightArrow), (UIKeyCommand.inputHome, .home),
        (UIKeyCommand.inputEnd, .end), (UIKeyCommand.inputPageUp, .pageUp),
        (UIKeyCommand.inputPageDown, .pageDown),
      ]
      if let key = special.first(where: { $0.0 == input })?.1 {
        self = key
      } else if input.count == 1 {
        self = Key(input)
      } else {
        return nil
      }
    }
  }

  extension KeyModifiers {
    public init(_ flags: UIKeyModifierFlags) {
      self = []
      if flags.contains(.command) { insert(.command) }
      if flags.contains(.shift) { insert(.shift) }
      if flags.contains(.alternate) { insert(.option) }
      if flags.contains(.control) { insert(.control) }
    }
  }

  extension UIKeyModifierFlags {
    public init(_ modifiers: KeyModifiers) {
      self = []
      if modifiers.contains(.command) { insert(.command) }
      if modifiers.contains(.shift) { insert(.shift) }
      if modifiers.contains(.option) { insert(.alternate) }
      if modifiers.contains(.control) { insert(.control) }
    }
  }

  // MARK: - Read-only content

  // In this file rather than its own: subclassing across files tripped
  // the linker over `tokenStyles`.
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
