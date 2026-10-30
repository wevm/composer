// Snapshots of ComposerStyled, in SwiftUI and native, in the states its
// design shows. Apple-only. References are recorded on the CI runners (see
// swift-macos.yml, which uploads new ones as an artifact).
#if canImport(UIKit) || canImport(AppKit)
  import ComposerStyled
  import ComposerSwiftUI
  import SnapshotTesting
  import SwiftUI
  import Testing
  #if canImport(UIKit)
    import UIKit
  #else
    import AppKit
  #endif

  struct Context: ComposerContext {
    var id = "m1"
    var kind = ComposerContextKind.reply
  }

  @MainActor func styledController(_ markdown: String = "") -> ComposerController {
    let document = markdown.isEmpty ? Document.empty : MarkdownCodec().parse(markdown)
    return ComposerController(EditorState(document: document)) {
      PluginGroup.chatDefaults
      SendAction { _ in }.placement(.trailing)
      AttachmentsPlugin { _, _ in }
      AttachmentPicker { _ in }
      ReplyAndEdit()
      MaxLength(40)
    }
  }

  @MainActor @Suite(.serialized) struct StyledSnapshotTests {
    #if canImport(UIKit)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif

    func snapshot(
      _ view: some View, named name: String, height: CGFloat = 160,
      fileID: StaticString = #fileID, filePath: StaticString = #filePath,
      testName: String = #function, line: UInt = #line, column: UInt = #column
    ) {
      let content = view.padding(8).frame(width: 360, height: height, alignment: .bottom)
        .environment(\.colorScheme, .light)
      #if canImport(UIKit)
        let host = UIHostingController(rootView: content)
        host.view.frame = CGRect(x: 0, y: 0, width: 360, height: height)
        assertSnapshot(
          of: host,
          as: .image(
            precision: 0.98, perceptualPrecision: 0.98, size: CGSize(width: 360, height: height)),
          named: "\(platform)-\(name)", fileID: fileID, file: filePath, testName: testName,
          line: line, column: column)
      #else
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        assertSnapshot(
          of: host, as: .image(precision: 0.98, perceptualPrecision: 0.98),
          named: "\(platform)-\(name)", fileID: fileID,
          file: filePath, testName: testName, line: line, column: column)
      #endif
    }

    @Test func emptyComposer() {
      snapshot(StyledComposer(styledController()), named: "empty")
    }

    @Test func replyWithAttachmentAndFormattedText() {
      let controller = styledController("**Bold** and _italic_ and `code`")
      controller.setContext(Context())
      controller.addAttachments([
        Attachment(id: .init("a"), payload: 0, name: "photo.png", status: .ready),
        Attachment(
          id: .init("b"), payload: 0, name: "notes.pdf", status: .uploading(progress: 0.5)),
      ])
      snapshot(StyledComposer(controller), named: "reply", height: 200)
    }

    @Test func overTheLimit() {
      let controller = styledController(
        "This message is a little too long for the forty character limit")
      controller.setContext(Context(kind: .edit))
      snapshot(StyledComposer(controller), named: "over-limit", height: 200)
    }

    @Test func messageAndCards() {
      let mention = AtomicNode(type: .mention, label: "tom", attributes: ["id": "u1"])
      let schema = Schema(plugins: [MentionsPlugin(source: .static([]))])
      let document = Document(blocks: [
        .paragraph([
          .text("Hi "), .node(mention), .text(", see "),
          .text("this", marks: .link("https://wevm.dev")),
        ]),
        .list(.bullet, items: [ListItem(blocks: [.paragraph([.text("a list")])])]),
      ])
      snapshot(
        VStack(alignment: .leading, spacing: 12) {
          StyledMessage(document, schema: schema).contentRenderer(.text)
          StyledUserCard(node: mention)
          StyledLinkTooltip(url: "https://wevm.dev")
        }, named: "message", height: 200)
    }

    @Test func nativeComposerView() {
      let controller = styledController("Native")
      controller.setContext(Context())
      #if canImport(UIKit)
        let view = StyledComposerView(controller: controller)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 100)
        view.backgroundColor = .systemBackground
        view.overrideUserInterfaceStyle = .light
        view.layoutIfNeeded()
        assertSnapshot(
          of: view, as: .image(precision: 0.98, perceptualPrecision: 0.98),
          named: "\(platform)-native")
      #else
        let view = StyledComposerView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        assertSnapshot(
          of: view, as: .image(precision: 0.98, perceptualPrecision: 0.98),
          named: "\(platform)-native")
      #endif
      #expect(!view.textView.isHidden)
    }

    /// The native view with the suggestions list open and the tray holding a
    /// ready, an uploading, and a failed attachment.
    @Test func nativeSuggestionsAndTray() {
      struct Failure: Error {}
      let people = [
        Suggestion(id: "u1", label: "tom", subtitle: "Tom Hill"),
        Suggestion(id: "u2", label: "tony", subtitle: "Tony Park"),
      ]
      let controller = ComposerController {
        SendAction { _ in }.placement(.trailing)
        AttachmentsPlugin { _, _ in }
        AttachmentPicker { _ in }
        MentionsPlugin(source: .static(people))
      }
      controller.addAttachments([
        Attachment(id: .init("a"), payload: 0, name: "photo.png", status: .ready),
        Attachment(
          id: .init("b"), payload: 0, name: "notes.pdf", status: .uploading(progress: 0.5)),
        Attachment(id: .init("c"), payload: 0, name: "big.mov", status: .failed(Failure())),
      ])
      for character in "hi @to" { controller.insertText(String(character)) }
      #expect(controller.suggestions.items.count == 2)
      #if canImport(UIKit)
        let view = StyledComposerView(controller: controller)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        view.backgroundColor = .systemBackground
        view.overrideUserInterfaceStyle = .light
        view.layoutIfNeeded()
      #else
        let view = StyledComposerView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
      #endif
      assertSnapshot(
        of: view, as: .image(precision: 0.98, perceptualPrecision: 0.98),
        named: "\(platform)-native-suggestions-tray")
      // Committing from the list closes it and inserts the mention.
      controller.suggestions.commit(1)
      #expect(controller.suggestions.items.isEmpty)
      #expect(controller.markdown.contains(":mention[tony]"))
    }
  }
#endif
