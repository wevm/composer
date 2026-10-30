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

  @State private var model = DemoModel()
  @State private var readout = Readout.markdown
  @State private var isExpanded = false
  @FocusState private var isFocused: Bool

  private var controller: ComposerController { model.controller }

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
        "Type markdown: **bold**, _italic_, ~~strike~~, `code`, and [links](url) convert as "
          + "you close them, and ⌫ right after undoes it. Start a line with - , 1. , > , or [ ] "
          + "in a list; ⇥ and ⇧⇥ nest lists; ``` and ↩ start a code block. Try @to, #tags, "
          + "/shrug, /quote, and :smile:. ↩ sends on macOS (⌘↩ anywhere); ↑ in an empty "
          + "composer edits your last message."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      TranscriptView(model: model)
      Composer.Root(controller) {
        Composer.Suggestions()
          .padding(4)
          .background(.background, in: .rect(cornerRadius: 8))
        Composer.Header { context in
          HStack {
            Text(context.kind == .edit ? "Editing your message" : "Replying to \(context.id)")
              .font(.callout.bold())
            Spacer()
            Button("Cancel", systemImage: "xmark.circle.fill") { controller.setContext(nil) }
              .labelStyle(.iconOnly)
              .buttonStyle(.plain)
          }
          .foregroundStyle(.secondary)
        }
        Composer.Attachments()
        HStack(alignment: .bottom, spacing: 8) {
          Composer.Actions(.leading)
            .labelStyle(.iconOnly)
            .font(.title2)
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
          Composer.Actions(.trailing)
            .labelStyle(.iconOnly)
            .font(.title2)
        }
        .buttonStyle(.plain)
        Composer.Footer { state in
          Text(summary(of: state))
            .font(.callout.monospacedDigit())
            .foregroundStyle(state[MaxLength.statusKey]?.isOver == true ? .red : .secondary)
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
    if let status = state[MaxLength.statusKey] {
      summary += " · \(status.count)/\(status.limit)"
    }
    if let marked = state.markedText {
      summary += " · composing \(marked.range.lowerBound)..<\(marked.range.upperBound)"
    }
    return summary
  }

  static let people = [
    Suggestion(id: "u1", label: "tom", subtitle: "Tom Hill"),
    Suggestion(id: "u2", label: "tony", subtitle: "Tony Park"),
    Suggestion(id: "u3", label: "ann", subtitle: "Ann Lee"),
    Suggestion(id: "u4", label: "zoe", subtitle: "Zoë Adams"),
  ]

  static let emoji = [
    Emoji("😄", shortcodes: ["smile"]), Emoji("😏", shortcodes: ["smirk"]),
    Emoji("👍", shortcodes: ["thumbsup", "+1"]), Emoji("🎉", shortcodes: ["tada"]),
    Emoji("❤️", shortcodes: ["heart"]), Emoji("🚀", shortcodes: ["rocket"]),
  ]

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

/// The demo's state: the composer and the messages it sent.
@MainActor @Observable final class DemoModel {
  struct Message: Identifiable {
    let id: String
    var document: Document
    var markdown: String
    var attachments: [String]
  }

  struct Context: ComposerContext {
    var id: String
    var kind: ComposerContextKind
  }

  var messages: [Message] = []
  @ObservationIgnored private(set) var controller: ComposerController!
  @ObservationIgnored private var nextID = 1

  init() {
    controller = ComposerController {
      PluginGroup.chatDefaults
      MentionsPlugin(source: .static(PlaygroundDemo.people))
      HashtagsPlugin()
      SlashCommandsPlugin([
        SlashCommand("shrug", summary: "¯\\_(ツ)_/¯") { _, _ in .replace("¯\\_(ツ)_/¯") }
      ])
      EmojiShortcodesPlugin(emoji: PlaygroundDemo.emoji)
      SendAction { [weak self] message in
        // A pretend network round trip.
        try await Task.sleep(for: .milliseconds(150))
        await self?.receive(message)
      }
      .placement(.trailing)
      ReplyAndEdit { [weak self] controller in
        guard let last = self?.messages.last else { return false }
        controller.setContext(Context(id: last.id, kind: .edit), document: last.document)
        return true
      }
      AttachmentsPlugin { attachment, controller in
        // A pretend upload.
        Task {
          for step in 1...4 {
            try? await Task.sleep(for: .milliseconds(250))
            controller.setStatus(.uploading(progress: Double(step) / 4), of: attachment.id)
          }
          controller.setStatus(.ready, of: attachment.id)
        }
      }
      AttachmentPicker { controller in
        controller.addAttachments([Attachment(payload: "photo", name: "photo.png")])
      }
      MaxLength(500)
    }
  }

  func reply(to message: Message) {
    controller.setContext(Context(id: message.id, kind: .reply))
  }

  private func receive(_ message: ComposerMessage) {
    let sent = Message(
      id: message.context?.kind == .edit ? message.context!.id : "m\(nextID)",
      document: message.document, markdown: message.markdown,
      attachments: message.attachments.map { $0.name ?? "attachment" })
    if let index = messages.firstIndex(where: { $0.id == sent.id }) {
      messages[index] = sent
    } else {
      messages.append(sent)
      nextID += 1
    }
  }
}

/// The messages sent so far, newest last.
struct TranscriptView: View {
  let model: DemoModel

  var body: some View {
    if !model.messages.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(model.messages) { message in
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(message.markdown)
                if !message.attachments.isEmpty {
                  Label(message.attachments.joined(separator: ", "), systemImage: "paperclip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Reply") { model.reply(to: message) }
                .font(.caption)
            }
            .padding(8)
            .background(.tint.opacity(0.1), in: .rect(cornerRadius: 8))
          }
        }
      }
      .frame(maxHeight: 180)
    }
  }
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
