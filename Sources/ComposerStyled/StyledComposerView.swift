// The reference design for UIKit and AppKit: `StyledComposerView`, the
// native counterpart of `StyledComposer`, built on the public native layer.
#if canImport(UIKit)
  import ComposerCore
  import ComposerUIKit
  import Observation
  import UIKit

  /// The reference composer as a `UIView`: the reply or edit banner, then
  /// the leading actions, the input in a rounded field, and the trailing
  /// actions. It follows the controller's context and actions.
  open class StyledComposerView: UIView {
    public let controller: ComposerController
    public let textView: ComposerTextView
    private let banner = UILabel()
    private let cancel = UIButton(type: .system)
    private let bannerRow = UIStackView()
    /// The suggestions list, above the banner, while a list is open.
    private let suggestionsList = UIStackView()
    private let suggestionsPanel = UIView()
    /// The attachments tray, above the input, while it has attachments.
    private let tray = UIStackView()
    private let trayScroll = UIScrollView()
    private var shownSession: SuggestionSession?
    private var shownAttachments: [Attachment]?
    private let leading = UIStackView()
    private let trailing = UIStackView()
    private var buttons: [ComposerAction.ID: UIButton] = [:]

    public init(controller: ComposerController, frame: CGRect = .zero) {
      self.controller = controller
      textView = ComposerTextView(controller: controller)
      super.init(frame: frame)
      build()
      observe()
    }

    public required init?(coder: NSCoder) {
      fatalError("StyledComposerView is created in code")
    }

    private func build() {
      textView.placeholder = String(localized: styledText("Message"))
      textView.backgroundColor = .systemBackground
      textView.layer.cornerRadius = 18
      textView.layer.borderWidth = 1
      textView.layer.borderColor = UIColor.separator.cgColor
      textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

      banner.font = .preferredFont(forTextStyle: .callout)
      banner.textColor = .secondaryLabel
      cancel.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
      cancel.tintColor = .secondaryLabel
      cancel.accessibilityLabel = String(localized: styledText("Cancel"))
      cancel.addAction(
        UIAction { [weak self] _ in self?.controller.setContext(nil) }, for: .primaryActionTriggered
      )
      bannerRow.axis = .horizontal
      bannerRow.spacing = 6
      bannerRow.addArrangedSubview(banner)
      bannerRow.addArrangedSubview(UIView())
      bannerRow.addArrangedSubview(cancel)

      for (stack, placement) in [
        (leading, ComposerAction.Placement.leading), (trailing, .trailing),
      ] {
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .bottom
        for action in controller.actions.filter({ $0.placement.current == placement }) {
          let button = makeButton(for: action)
          buttons[action.id] = button
          stack.addArrangedSubview(button)
        }
      }
      let row = UIStackView(arrangedSubviews: [leading, textView, trailing])
      row.axis = .horizontal
      row.spacing = 8
      row.alignment = .bottom
      suggestionsList.axis = .vertical
      suggestionsList.spacing = 2
      suggestionsList.translatesAutoresizingMaskIntoConstraints = false
      suggestionsPanel.backgroundColor = .secondarySystemBackground
      suggestionsPanel.layer.cornerRadius = 12
      suggestionsPanel.addSubview(suggestionsList)
      tray.axis = .horizontal
      tray.spacing = 8
      tray.translatesAutoresizingMaskIntoConstraints = false
      trayScroll.showsHorizontalScrollIndicator = false
      trayScroll.addSubview(tray)
      NSLayoutConstraint.activate([
        suggestionsList.leadingAnchor.constraint(
          equalTo: suggestionsPanel.leadingAnchor, constant: 4),
        suggestionsList.trailingAnchor.constraint(
          equalTo: suggestionsPanel.trailingAnchor, constant: -4),
        suggestionsList.topAnchor.constraint(equalTo: suggestionsPanel.topAnchor, constant: 4),
        suggestionsList.bottomAnchor.constraint(
          equalTo: suggestionsPanel.bottomAnchor, constant: -4),
        tray.leadingAnchor.constraint(equalTo: trayScroll.contentLayoutGuide.leadingAnchor),
        tray.trailingAnchor.constraint(equalTo: trayScroll.contentLayoutGuide.trailingAnchor),
        tray.topAnchor.constraint(equalTo: trayScroll.contentLayoutGuide.topAnchor),
        tray.bottomAnchor.constraint(equalTo: trayScroll.contentLayoutGuide.bottomAnchor),
        tray.heightAnchor.constraint(equalTo: trayScroll.frameLayoutGuide.heightAnchor),
        trayScroll.heightAnchor.constraint(equalToConstant: 32),
      ])
      let column = UIStackView(arrangedSubviews: [suggestionsPanel, bannerRow, trayScroll, row])
      column.axis = .vertical
      column.spacing = 6
      column.translatesAutoresizingMaskIntoConstraints = false
      addSubview(column)
      NSLayoutConstraint.activate([
        column.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
        column.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        column.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
        column.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
      ])
    }

    private func makeButton(for action: ComposerAction) -> UIButton {
      var configuration = UIButton.Configuration.filled()
      configuration.image = UIImage(systemName: action.systemImage ?? "circle")
      configuration.cornerStyle = .capsule
      configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
        pointSize: 14, weight: .semibold)
      let button = UIButton(configuration: configuration)
      button.accessibilityLabel = String(localized: action.label)
      button.addAction(
        UIAction { [weak self] _ in
          guard let self else { return }
          Task { try? await self.controller.perform(action.id) }
        }, for: .primaryActionTriggered)
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 34),
        button.heightAnchor.constraint(equalToConstant: 34),
      ])
      return button
    }

    /// Follows the context and the enabled and visible actions.
    private func observe() {
      withObservationTracking {
        refresh()
      } onChange: { [weak self] in
        Task { @MainActor in self?.observe() }
      }
    }

    private func refresh() {
      let session = controller.suggestionSession
      if session != shownSession {
        shownSession = session
        rebuildSuggestions()
      }
      let attachments = controller.attachments
      if attachments != shownAttachments {
        shownAttachments = attachments
        rebuildTray(attachments)
      }
      let context = controller.context
      bannerRow.isHidden = context == nil
      if let context {
        banner.text = String(
          localized: context.kind == .edit ? styledText("Editing message") : styledText("Replying"))
      }
      for (id, button) in buttons {
        button.isEnabled = controller.isEnabled(id)
        button.isHidden = !controller.visibleActions.contains(id)
        if let action = controller.action(id) {
          button.accessibilityLabel = String(localized: controller.label(of: action))
        }
      }
    }

    // MARK: Suggestions and tray

    private func rebuildSuggestions() {
      for view in suggestionsList.arrangedSubviews { view.removeFromSuperview() }
      let suggestions = controller.suggestions
      let items = suggestions.items
      suggestionsPanel.isHidden = items.isEmpty
      for (index, item) in items.enumerated() {
        let isHighlighted = index == suggestions.highlightedIndex
        var configuration = UIButton.Configuration.plain()
        configuration.title = item.label
        configuration.subtitle = item.subtitle
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = isHighlighted ? .white : .label
        configuration.background.backgroundColor = isHighlighted ? tintColor : .clear
        configuration.background.cornerRadius = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(
          top: 6, leading: 10, bottom: 6, trailing: 10)
        let row = UIButton(configuration: configuration)
        row.contentHorizontalAlignment = .leading
        if isHighlighted { row.accessibilityTraits.insert(.selected) }
        row.addAction(
          UIAction { [weak self] _ in self?.controller.suggestions.commit(index) },
          for: .primaryActionTriggered)
        suggestionsList.addArrangedSubview(row)
      }
    }

    private func rebuildTray(_ attachments: [Attachment]) {
      for view in tray.arrangedSubviews { view.removeFromSuperview() }
      trayScroll.isHidden = attachments.isEmpty
      for attachment in attachments { tray.addArrangedSubview(chip(for: attachment)) }
    }

    /// An attachment as a rounded chip: an icon, its name, its upload
    /// progress, and a remove button; red-bordered when its upload failed.
    private func chip(for attachment: Attachment) -> UIView {
      let chip = UIStackView()
      chip.axis = .horizontal
      chip.spacing = 4
      chip.alignment = .center
      chip.isLayoutMarginsRelativeArrangement = true
      chip.directionalLayoutMargins = NSDirectionalEdgeInsets(
        top: 4, leading: 8, bottom: 4, trailing: 6)
      chip.backgroundColor = .tertiarySystemFill
      chip.layer.cornerRadius = 10
      var isFailed = false
      if case .failed = attachment.status { isFailed = true }
      if isFailed {
        chip.layer.borderWidth = 1
        chip.layer.borderColor = UIColor.systemRed.cgColor
      }
      let icon = UIImageView(
        image: UIImage(systemName: isFailed ? "exclamationmark.triangle" : "doc"))
      icon.tintColor = isFailed ? .systemRed : .secondaryLabel
      let name = UILabel()
      name.text = attachment.name ?? "Attachment"
      name.font = .preferredFont(forTextStyle: .caption1)
      chip.addArrangedSubview(icon)
      chip.addArrangedSubview(name)
      let progress: Double? =
        switch attachment.status {
        case .pending: 0
        case .uploading(let progress): progress
        case .failed, .ready: nil
        }
      if let progress {
        let bar = UIProgressView(progressViewStyle: .bar)
        bar.progress = Float(progress)
        bar.widthAnchor.constraint(equalToConstant: 24).isActive = true
        chip.addArrangedSubview(bar)
      }
      let remove = UIButton(type: .system)
      remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
      remove.tintColor = .secondaryLabel
      remove.accessibilityLabel = String(localized: styledText("Remove"))
      let id = attachment.id
      remove.addAction(
        UIAction { [weak self] _ in self?.controller.removeAttachment(id) },
        for: .primaryActionTriggered)
      chip.addArrangedSubview(remove)
      return chip
    }
  }
#elseif canImport(AppKit)
  import AppKit
  import ComposerAppKit
  import ComposerCore
  import Observation

  /// The reference composer as an `NSView`: the reply or edit banner, then
  /// the leading actions, the input in a rounded field, and the trailing
  /// actions. It follows the controller's context and actions.
  open class StyledComposerView: NSView {
    public let controller: ComposerController
    public let textView: ComposerTextView
    private let scrollView = FittingScrollView()
    private let banner = NSTextField(labelWithString: "")
    private let bannerRow = NSStackView()
    /// The suggestions list, above the banner, while a list is open.
    private let suggestionsList = NSStackView()
    /// The attachments tray, above the input, while it has attachments.
    private let tray = NSStackView()
    private var shownSession: SuggestionSession?
    private var shownAttachments: [Attachment]?
    private var buttons: [ComposerAction.ID: NSButton] = [:]

    public init(
      controller: ComposerController, frame: NSRect = NSRect(x: 0, y: 0, width: 360, height: 60)
    ) {
      self.controller = controller
      textView = ComposerTextView(controller: controller)
      super.init(frame: frame)
      build()
      observe()
    }

    public required init?(coder: NSCoder) {
      fatalError("StyledComposerView is created in code")
    }

    private func build() {
      textView.placeholder = String(localized: styledText("Message"))
      textView.minSize = .zero
      textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.autoresizingMask = [.width]
      scrollView.documentView = textView
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      let field = NSView()
      field.wantsLayer = true
      field.layer?.cornerRadius = 16
      field.layer?.borderWidth = 1
      field.layer?.borderColor = NSColor.separatorColor.cgColor
      field.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      field.addSubview(scrollView)
      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 8),
        scrollView.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -8),
        scrollView.topAnchor.constraint(equalTo: field.topAnchor, constant: 2),
        scrollView.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -2),
      ])

      banner.font = .preferredFont(forTextStyle: .callout)
      banner.textColor = .secondaryLabelColor
      let cancel = NSButton(
        image: NSImage(
          systemSymbolName: "xmark.circle.fill",
          accessibilityDescription: String(localized: styledText("Cancel")))!,
        target: self, action: #selector(clearContext))
      cancel.isBordered = false
      bannerRow.orientation = .horizontal
      bannerRow.addArrangedSubview(banner)
      bannerRow.addArrangedSubview(NSView())
      bannerRow.addArrangedSubview(cancel)

      let row = NSStackView()
      row.orientation = .horizontal
      row.alignment = .bottom
      row.spacing = 8
      for action in controller.actions where action.placement.current == .leading {
        row.addArrangedSubview(makeButton(for: action))
      }
      row.addArrangedSubview(field)
      for action in controller.actions where action.placement.current == .trailing {
        row.addArrangedSubview(makeButton(for: action))
      }
      suggestionsList.orientation = .vertical
      suggestionsList.alignment = .leading
      suggestionsList.spacing = 2
      suggestionsList.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
      suggestionsList.wantsLayer = true
      suggestionsList.layer?.cornerRadius = 10
      suggestionsList.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
      suggestionsList.layer?.borderWidth = 1
      suggestionsList.layer?.borderColor = NSColor.separatorColor.cgColor
      tray.orientation = .horizontal
      tray.spacing = 8
      let column = NSStackView(views: [suggestionsList, bannerRow, tray, row])
      column.orientation = .vertical
      column.alignment = .leading
      column.spacing = 6
      column.translatesAutoresizingMaskIntoConstraints = false
      addSubview(column)
      NSLayoutConstraint.activate([
        column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        row.widthAnchor.constraint(equalTo: column.widthAnchor),
        bannerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
        suggestionsList.widthAnchor.constraint(equalTo: column.widthAnchor),
      ])
    }

    private func makeButton(for action: ComposerAction) -> NSButton {
      let button = ActionButton(
        image: NSImage(
          systemSymbolName: action.systemImage ?? "circle",
          accessibilityDescription: String(localized: action.label))!,
        target: nil, action: nil)
      button.actionID = action.id
      button.target = self
      button.action = #selector(runAction(_:))
      button.bezelStyle = .circular
      button.contentTintColor = .controlAccentColor
      buttons[action.id] = button
      return button
    }

    @objc private func runAction(_ sender: ActionButton) {
      guard let id = sender.actionID else { return }
      Task { try? await controller.perform(id) }
    }

    @objc private func clearContext() {
      controller.setContext(nil)
    }

    /// Follows the context and the enabled and visible actions.
    private func observe() {
      withObservationTracking {
        refresh()
      } onChange: { [weak self] in
        Task { @MainActor in self?.observe() }
      }
    }

    private func refresh() {
      let session = controller.suggestionSession
      if session != shownSession {
        shownSession = session
        rebuildSuggestions()
      }
      let attachments = controller.attachments
      if attachments != shownAttachments {
        shownAttachments = attachments
        rebuildTray(attachments)
      }
      let context = controller.context
      bannerRow.isHidden = context == nil
      if let context {
        banner.stringValue = String(
          localized: context.kind == .edit ? styledText("Editing message") : styledText("Replying"))
      }
      for (id, button) in buttons {
        button.isEnabled = controller.isEnabled(id)
        button.isHidden = !controller.visibleActions.contains(id)
        if let action = controller.action(id) {
          button.setAccessibilityLabel(String(localized: controller.label(of: action)))
        }
      }
    }

    /// A button that knows its action.
    final class ActionButton: NSButton {
      var actionID: ComposerAction.ID?
    }

    // MARK: Suggestions and tray

    private func rebuildSuggestions() {
      for view in suggestionsList.arrangedSubviews { view.removeFromSuperview() }
      let suggestions = controller.suggestions
      let items = suggestions.items
      suggestionsList.isHidden = items.isEmpty
      for (index, item) in items.enumerated() {
        let isHighlighted = index == suggestions.highlightedIndex
        let title = NSMutableAttributedString(
          string: item.label,
          attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isHighlighted ? NSColor.white : NSColor.labelColor,
          ])
        if let subtitle = item.subtitle {
          title.append(
            NSAttributedString(
              string: "  " + subtitle,
              attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: isHighlighted
                  ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
              ]))
        }
        let row = IndexButton(title: "", target: self, action: #selector(commitSuggestion(_:)))
        row.index = index
        row.attributedTitle = title
        row.isBordered = false
        row.alignment = .left
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor =
          isHighlighted ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        suggestionsList.addArrangedSubview(row)
        NSLayoutConstraint.activate([
          row.heightAnchor.constraint(equalToConstant: 24),
          row.widthAnchor.constraint(equalTo: suggestionsList.widthAnchor, constant: -8),
        ])
      }
    }

    @objc private func commitSuggestion(_ sender: IndexButton) {
      controller.suggestions.commit(sender.index)
    }

    private func rebuildTray(_ attachments: [Attachment]) {
      for view in tray.arrangedSubviews { view.removeFromSuperview() }
      tray.isHidden = attachments.isEmpty
      for attachment in attachments { tray.addArrangedSubview(chip(for: attachment)) }
    }

    /// An attachment as a rounded chip: an icon, its name, its upload
    /// progress, and a remove button; red-bordered when its upload failed.
    private func chip(for attachment: Attachment) -> NSView {
      var isFailed = false
      if case .failed = attachment.status { isFailed = true }
      let icon = NSImageView(
        image: NSImage(
          systemSymbolName: isFailed ? "exclamationmark.triangle" : "doc",
          accessibilityDescription: nil)!)
      icon.contentTintColor = isFailed ? .systemRed : .secondaryLabelColor
      let name = NSTextField(labelWithString: attachment.name ?? "Attachment")
      name.font = .systemFont(ofSize: 11)
      let chip = NSStackView(views: [icon, name])
      chip.orientation = .horizontal
      chip.spacing = 4
      chip.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 6)
      chip.wantsLayer = true
      chip.layer?.cornerRadius = 10
      chip.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
      if isFailed {
        chip.layer?.borderWidth = 1
        chip.layer?.borderColor = NSColor.systemRed.cgColor
      }
      let progress: Double? =
        switch attachment.status {
        case .pending: 0
        case .uploading(let progress): progress
        case .failed, .ready: nil
        }
      if let progress {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = progress
        bar.widthAnchor.constraint(equalToConstant: 24).isActive = true
        chip.addArrangedSubview(bar)
      }
      let remove = AttachmentButton(
        image: NSImage(
          systemSymbolName: "xmark.circle.fill",
          accessibilityDescription: String(localized: styledText("Remove")))!,
        target: self, action: #selector(removeAttachment(_:)))
      remove.attachmentID = attachment.id
      remove.isBordered = false
      remove.contentTintColor = .secondaryLabelColor
      chip.addArrangedSubview(remove)
      return chip
    }

    @objc private func removeAttachment(_ sender: AttachmentButton) {
      guard let id = sender.attachmentID else { return }
      controller.removeAttachment(id)
    }

    /// A suggestion row that knows its index.
    final class IndexButton: NSButton {
      var index = 0
    }

    /// A remove button that knows its attachment.
    final class AttachmentButton: NSButton {
      var attachmentID: Attachment.ID?
    }

    /// A scroll view whose intrinsic height is its text view's fitting
    /// height, which the text view invalidates as its text grows.
    final class FittingScrollView: NSScrollView {
      override var intrinsicContentSize: NSSize {
        NSSize(
          width: NSView.noIntrinsicMetric,
          height: (documentView as? ComposerTextView)?.fittingHeight ?? NSView.noIntrinsicMetric)
      }
    }
  }
#endif
