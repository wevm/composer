import ComposerSwiftUI
import SwiftUI

/// The demo: a composer from `ComposerSwiftUI`'s primitives, with markdown
/// converting as you type and a live readout of the document.
struct PlaygroundDemo: View {
  enum Readout: String, CaseIterable, Identifiable {
    case markdown = "Markdown"
    case json = "JSON"
    var id: Self { self }
  }

  @State private var controller = ComposerController(plugins: [LiveMarkdown()])
  @State private var readout = Readout.markdown
  @State private var isExpanded = false
  @FocusState private var isFocused: Bool

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
        "Type markdown: **bold**, _italic_, ~~strike~~, and `code` convert as you close them; "
          + "start a line with - , 1. , or > for lists and quotes, and [ ] in a list for a task."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Composer.Root(controller) {
        Composer.Input("Message", isExpanded: $isExpanded)
          .focused($isFocused)
          .accessibilityIdentifier("composer")
          #if os(iOS)
            .composerKeyboardAccessory { accessory }
          #endif
          .padding(6)
          .background(.background, in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
          .frame(maxHeight: isExpanded ? .infinity : nil)
        Composer.Footer { state in
          Text(summary(of: state))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      HStack {
        Picker("Readout", selection: $readout) {
          ForEach(Readout.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        Spacer()
        Toggle("Expanded", isOn: $isExpanded).fixedSize()
      }
      if !isExpanded {
        ReadoutView(controller: controller, readout: readout)
      }
    }
    .padding(16)
    .onAppear { isFocused = true }
    #if os(macOS)
      .frame(minWidth: 560, minHeight: 520)
    #endif
  }

  #if os(iOS)
    /// The keyboard accessory slot: undo, redo, and done.
    private var accessory: some View {
      HStack(spacing: 20) {
        Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
        Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
        Spacer()
        Button("Done") { isFocused = false }.bold()
      }
      .labelStyle(.iconOnly)
      .padding(.horizontal, 16)
      .frame(height: 44)
      .background(.bar)
    }

    private var undoManager: UndoManager? { controller.undoManager as? UndoManager }
  #endif

  private func summary(of state: EditorState) -> String {
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

/// The live readout of the document. It reads the state, so it updates with
/// every keystroke, apart from the rest of the demo.
struct ReadoutView: View {
  let controller: ComposerController
  let readout: PlaygroundDemo.Readout

  var body: some View {
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
}
