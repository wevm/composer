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
      let column = UIStackView(arrangedSubviews: [bannerRow, row])
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
      let column = NSStackView(views: [bannerRow, row])
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
