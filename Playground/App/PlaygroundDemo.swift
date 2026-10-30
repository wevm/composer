import ComposerCore
import SwiftUI

#if os(macOS)
  import AppKit
  import ComposerAppKit
#else
  import ComposerUIKit
  import UIKit
#endif

/// The demo: a composer on the platform's `ComposerTextView`, with markdown
/// converting as you type and a live readout of the document.
struct PlaygroundDemo: View {
  enum Readout: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case json = "JSON"
    var id: Self { self }
  }

  @State private var controller = ComposerController(plugins: [LiveMarkdown()])
  @State private var readout = Readout.markdown

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Composer Playground").font(.title2.bold())
        Spacer()
        Button("Sample") { controller.setDocument(MarkdownCodec().parse(Self.sample)) }
        Button("Clear") { controller.clear() }
      }
      .buttonStyle(.bordered)
      Text(
        "Type markdown: **bold**, _italic_, ~~strike~~, and `code` convert after a space; "
          + "start a line with - , 1. , or > for lists and quotes, and [ ] in a list for a task."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      ComposerEditor(controller: controller)
        .frame(minHeight: 160)
        .padding(6)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
      HStack {
        Picker("Readout", selection: $readout) {
          ForEach(Readout.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer()
        Text(selectionSummary).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      }
      ScrollView {
        Text(readoutText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
      }
      .frame(minHeight: 140)
      .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
    .padding(16)
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 520)
    #endif
  }

  private var readoutText: String {
    let document = controller.state.document
    switch readout {
    case .markdown:
      return MarkdownCodec(schema: controller.schema).serialize(document)
    case .json:
      guard let data = try? JSONCodec(schema: controller.schema).encode(document),
        let object = try? JSONSerialization.jsonObject(with: data),
        let pretty = try? JSONSerialization.data(
          withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      else { return "" }
      return String(decoding: pretty, as: UTF8.self)
    }
  }

  private var selectionSummary: String {
    let state = controller.state
    var summary = "selection \(state.selection) · \(state.document.length) units"
    if let marked = state.markedText {
      summary += " · composing \(marked.range.lowerBound)..<\(marked.range.upperBound)"
    }
    return summary
  }

  static let sample = """
    Composer renders **bold**, _italic_, ~~strikethrough~~, `inline code`, and \
    [links](https://wevm.dev).

    > A quote, which can hold
    > more than one line.

    1. Ordered lists
    2. with nesting:
       - bullets inside
       - [x] and tasks
       - [ ] up to three levels

    ```swift
    let composer = ComposerController()
    ```
    """
}

#if os(macOS)
  /// A thin bridge to `ComposerTextView` until `ComposerSwiftUI` lands: a
  /// scroll view holding the text view, focused when it appears.
  struct ComposerEditor: NSViewRepresentable {
    let controller: ComposerController

    func makeNSView(context: Context) -> NSScrollView {
      let scrollView = NSScrollView()
      scrollView.hasVerticalScroller = true
      scrollView.drawsBackground = false
      scrollView.borderType = .noBorder
      let textView = ComposerTextView(
        controller: controller, frame: NSRect(x: 0, y: 0, width: 480, height: 160))
      textView.minSize = .zero
      textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.setAccessibilityIdentifier("composer")
      scrollView.documentView = textView
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
  }
#else
  /// A thin bridge to `ComposerTextView` until `ComposerSwiftUI` lands, with
  /// a toolbar in the keyboard accessory slot.
  struct ComposerEditor: UIViewRepresentable {
    let controller: ComposerController

    func makeUIView(context: Context) -> ComposerTextView {
      let textView = ComposerTextView(controller: controller)
      textView.accessibilityIdentifier = "composer"
      let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
      toolbar.items = [
        UIBarButtonItem(
          title: "Undo", image: UIImage(systemName: "arrow.uturn.backward"),
          primaryAction: UIAction { [weak textView] _ in textView?.undoManager?.undo() }),
        UIBarButtonItem(
          title: "Redo", image: UIImage(systemName: "arrow.uturn.forward"),
          primaryAction: UIAction { [weak textView] _ in textView?.undoManager?.redo() }),
        .flexibleSpace(),
        UIBarButtonItem(
          systemItem: .done,
          primaryAction: UIAction { [weak textView] _ in textView?.resignFirstResponder() }),
      ]
      textView.keyboardAccessoryView = toolbar
      return textView
    }

    func updateUIView(_ textView: ComposerTextView, context: Context) {}
  }
#endif
