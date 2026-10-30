#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
  import SwiftUI
  #if canImport(UIKit)
    import ComposerUIKit
    import UIKit
  #else
    import AppKit
    import ComposerAppKit
  #endif

  extension Composer {
    /// The Input slot: the platform's `ComposerTextView`, for the
    /// controller in the environment.
    ///
    /// Its height fits the text, from `lines.lowerBound` lines to
    /// `lines.upperBound` (1–8 on iOS, 1–12 on macOS), and the text scrolls
    /// beyond. While `isExpanded` is `true`, it takes all the height it is
    /// offered instead, as a fullscreen editor does. It never reads the
    /// text, so typing doesn't invalidate it; the text view applies each
    /// change itself, and tells SwiftUI when its fitting height changes.
    ///
    /// `.focused($focus)` works on it as on a `TextField`.
    public struct Input: View {
      @Environment(ComposerController.self) private var controller
      #if canImport(UIKit)
        @Environment(\.composerKeyboardAccessory) private var keyboardAccessory
      #endif
      @Environment(\.composerTokenStyles) private var tokenStyles
      private let placeholder: LocalizedStringResource?
      private let lines: ClosedRange<Int>
      @Binding private var isExpanded: Bool

      public init(
        _ placeholder: LocalizedStringResource? = nil, lines: ClosedRange<Int>? = nil,
        isExpanded: Binding<Bool> = .constant(false)
      ) {
        self.placeholder = placeholder
        self.lines = lines ?? Self.defaultLines
        self._isExpanded = isExpanded
      }

      /// 1–8 lines on iOS, 1–12 on macOS.
      public static var defaultLines: ClosedRange<Int> {
        #if canImport(UIKit)
          1...8
        #else
          1...12
        #endif
      }

      public var body: some View {
        #if canImport(UIKit)
          InputView(
            controller: controller, placeholder: placeholder.map { String(localized: $0) },
            lines: lines, isExpanded: isExpanded, tokenStyles: tokenStyles,
            keyboardAccessory: keyboardAccessory
          )
          // A new controller is a new text view.
          .id(ObjectIdentifier(controller))
          // Flexible: an HStack measures its children's maximum width with
          // an infinite proposal, which the representable can't answer with
          // a width of its own (it answered its current one, so an empty
          // input stayed narrow). The frame takes the space and proposes it.
          .frame(maxWidth: .infinity)
        #else
          InputView(
            controller: controller, placeholder: placeholder.map { String(localized: $0) },
            lines: lines, isExpanded: isExpanded, tokenStyles: tokenStyles
          )
          .id(ObjectIdentifier(controller))
          .frame(maxWidth: .infinity)
        #endif
      }
    }
  }

  /// The size an input takes for a proposal: the proposed width, and the
  /// text view's fitting height, or all the proposed height while expanded.
  @MainActor private func inputSize(
    _ proposal: ProposedViewSize, isExpanded: Bool, width current: CGFloat,
    fittingHeight: @MainActor () -> CGFloat
  ) -> CGSize {
    RenderCounts.inputSizings += 1
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? current
    if isExpanded, let height = proposal.height, height.isFinite {
      return CGSize(width: width, height: height)
    }
    // Measured at the current width; if SwiftUI then gives the view a new
    // width, the view measures again and invalidates its intrinsic size.
    return CGSize(width: width, height: fittingHeight())
  }

  /// Token style overrides from `.composerTextStyle(for:)`. Closures don't
  /// compare, so each override carries a count of the times it was set,
  /// and the input restyles only when one changes.
  struct TokenStyles {
    var overrides: [NodeType: TokenStyleOverride] = [:]
    var version: [NodeType: Int] = [:]
  }

  extension EnvironmentValues {
    @Entry var composerTokenStyles = TokenStyles()
  }

  /// Counts `.composerTextStyle(for:)` calls, so each is a new version.
  @MainActor private var tokenStyleCount = 0

  extension View {
    /// Restyles tokens of a node type in the composers inside, over their
    /// plugin's style: `.composerTextStyle(for: .mention) { $0.bold() }`.
    public func composerTextStyle(
      for type: NodeType, _ style: @escaping TokenStyleOverride
    ) -> some View {
      modifier(TokenStyleModifier(type: type, style: style))
    }
  }

  private struct TokenStyleModifier: ViewModifier {
    let type: NodeType
    let style: TokenStyleOverride
    /// Fixed for the modifier's life, so re-rendering it doesn't restyle.
    @State private var version: Int = {
      tokenStyleCount += 1
      return tokenStyleCount
    }()

    func body(content: Content) -> some View {
      content.transformEnvironment(\.composerTokenStyles) { styles in
        styles.overrides[type] = style
        styles.version[type] = version
      }
    }
  }

  #if canImport(UIKit)
    extension EnvironmentValues {
      @Entry var composerKeyboardAccessory: AnyView? = nil
    }

    extension View {
      /// The KeyboardAccessory slot: content shown above the software
      /// keyboard while the composer's input is focused, as its
      /// `inputAccessoryView`.
      public func composerKeyboardAccessory<Content: View>(
        @ViewBuilder _ content: () -> Content
      ) -> some View {
        environment(\.composerKeyboardAccessory, AnyView(content()))
      }
    }

    private struct InputView: UIViewRepresentable {
      let controller: ComposerController
      let placeholder: String?
      let lines: ClosedRange<Int>
      let isExpanded: Bool
      let tokenStyles: TokenStyles
      let keyboardAccessory: AnyView?

      final class Coordinator {
        var accessory: UIHostingController<AnyView>?
        var tokenStyles: [NodeType: Int] = [:]
      }

      func makeCoordinator() -> Coordinator { Coordinator() }

      func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView(controller: controller)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
      }

      func updateUIView(_ view: ComposerTextView, context: Context) {
        RenderCounts.inputUpdates += 1
        if view.lineLimits != lines { view.lineLimits = lines }
        if view.placeholder != placeholder { view.placeholder = placeholder }
        if tokenStyles.version != context.coordinator.tokenStyles {
          context.coordinator.tokenStyles = tokenStyles.version
          view.tokenStyles = tokenStyles.overrides
        }
        updateKeyboardAccessory(of: view, context.coordinator)
      }

      private func updateKeyboardAccessory(of view: ComposerTextView, _ coordinator: Coordinator) {
        guard let keyboardAccessory else {
          if coordinator.accessory != nil {
            coordinator.accessory = nil
            view.keyboardAccessoryView = nil
          }
          return
        }
        // The accessory is hosted apart from this view's hierarchy, so it
        // gets the composer's environment explicitly.
        let content = AnyView(keyboardAccessory.environment(controller))
        if let host = coordinator.accessory {
          host.rootView = content
          return
        }
        let host = UIHostingController(rootView: content)
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        host.view.autoresizingMask = .flexibleHeight
        let size = host.sizeThatFits(
          in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        host.view.frame = CGRect(origin: .zero, size: size)
        coordinator.accessory = host
        view.keyboardAccessoryView = host.view
      }

      func sizeThatFits(
        _ proposal: ProposedViewSize, uiView view: ComposerTextView, context: Context
      ) -> CGSize? {
        inputSize(proposal, isExpanded: isExpanded, width: view.bounds.width) {
          view.fittingHeight
        }
      }
    }
  #else
    /// A scroll view whose intrinsic height is its text view's fitting
    /// height, which the text view invalidates as its text grows.
    final class InputScrollView: NSScrollView {
      var textView: ComposerTextView? { documentView as? ComposerTextView }

      override var intrinsicContentSize: NSSize {
        NSSize(
          width: NSView.noIntrinsicMetric,
          height: textView?.fittingHeight ?? NSView.noIntrinsicMetric)
      }
    }

    private struct InputView: NSViewRepresentable {
      let controller: ComposerController
      let placeholder: String?
      let lines: ClosedRange<Int>
      let isExpanded: Bool
      let tokenStyles: TokenStyles

      final class Coordinator {
        var tokenStyles: [NodeType: Int] = [:]
      }

      func makeCoordinator() -> Coordinator { Coordinator() }

      func makeNSView(context: Context) -> InputScrollView {
        let scrollView = InputScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 40))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        let textView = ComposerTextView(
          controller: controller,
          frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.minSize = .zero
        textView.maxSize = NSSize(
          width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
      }

      func updateNSView(_ scrollView: InputScrollView, context: Context) {
        RenderCounts.inputUpdates += 1
        guard let textView = scrollView.textView else { return }
        if textView.lineLimits != lines { textView.lineLimits = lines }
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        if tokenStyles.version != context.coordinator.tokenStyles {
          context.coordinator.tokenStyles = tokenStyles.version
          textView.tokenStyles = tokenStyles.overrides
        }
      }

      func sizeThatFits(
        _ proposal: ProposedViewSize, nsView scrollView: InputScrollView, context: Context
      ) -> CGSize? {
        inputSize(proposal, isExpanded: isExpanded, width: scrollView.frame.width) {
          scrollView.textView?.fittingHeight ?? 0
        }
      }
    }
  #endif
#endif
