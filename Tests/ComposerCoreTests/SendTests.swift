import ComposerCore
import ComposerTesting
import Testing

/// Opens once; waiters before then wait.
actor Gate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

actor Outbox {
  private(set) var sent: [ComposerMessage] = []
  func append(_ message: ComposerMessage) { sent.append(message) }
  var markdown: [String] { sent.map(\.markdown) }
}

struct Failure: Error {}

struct Reply: ComposerContext {
  var id: String
  var kind: ComposerContextKind
}

@MainActor @Suite struct SendTests {
  func controller(
    _ markdown: String = "hi", returnSends: Bool = true, _ extra: [any ComposerPlugin] = [],
    onSend: @escaping @Sendable (ComposerMessage) async throws -> Void = { _ in }
  ) -> ComposerController {
    let document = markdown.isEmpty ? Document.empty : MarkdownCodec().parse(markdown)
    return ComposerController(
      EditorState(document: document),
      plugins: [PluginGroup.markdown, SendAction(returnSends: returnSends, onSend: onSend)] + extra)
  }

  @Test func sendClearsAtOnceAndSendsTheMessage() async {
    let outbox = Outbox()
    let controller = controller("**hi** there") { await outbox.append($0) }
    let undo = UndoStack()
    controller.undoManager = undo
    controller.insertText("!")
    #expect(undo.canUndo)
    #expect(await controller.send().isSent)
    #expect(await outbox.markdown == ["**hi** there!"])
    #expect(controller.document.isEmpty)
    #expect(controller.selection == .caret(0))
    #expect(!undo.canUndo, "the sent draft's history is dropped")
    #expect(!controller.isEnabled(SendAction.id))
  }

  @Test func aFailedSendRestoresTheDraft() async {
    let entered = Gate()
    let release = Gate()
    let controller = controller(
      "draft", [AttachmentsPlugin { _, _ in }]
    ) { _ in
      await entered.open()
      await release.wait()
      throw Failure()
    }
    controller.addAttachments([Attachment(id: .init("a"), payload: 1, status: .ready)])
    controller.setContext(Reply(id: "m1", kind: .reply))
    let sending = Task { await controller.send() }
    await entered.wait()
    // Cleared while in flight.
    #expect(controller.document.isEmpty)
    #expect(controller.attachments.isEmpty)
    #expect(controller.context == nil)
    #expect(controller.isSending)
    await release.open()
    #expect(await sending.value.isFailed)
    #expect(controller.markdown == "draft")
    #expect(controller.attachments.map(\.id) == [.init("a")])
    #expect(controller.context?.id == "m1")
    #expect(!controller.isSending)
  }

  @Test func aFailedSendDoesNotOverwriteANewDraft() async {
    let entered = Gate()
    let release = Gate()
    let controller = controller("first") { _ in
      await entered.open()
      await release.wait()
      throw Failure()
    }
    let sending = Task { await controller.send() }
    await entered.wait()
    controller.insertText("second")
    await release.open()
    #expect(await sending.value.isFailed)
    #expect(controller.markdown == "second")
  }

  @Test func afterSuccessKeepsTheDraftAndBlocksSendingUntilItSucceeds() async {
    let entered = Gate()
    let release = Gate()
    let outbox = Outbox()
    let controller = ComposerController(
      EditorState(document: MarkdownCodec().parse("wait")),
      plugins: [
        SendAction { message in
          await entered.open()
          await release.wait()
          await outbox.append(message)
        }.clearing(.afterSuccess)
      ])
    let sending = Task { await controller.send() }
    await entered.wait()
    #expect(controller.markdown == "wait")
    #expect(!controller.isEnabled(SendAction.id), "no double send")
    #expect(await controller.send().isUnavailable)
    await release.open()
    #expect(await sending.value.isSent)
    #expect(controller.document.isEmpty)
    #expect(await outbox.markdown == ["wait"])
    // A failure leaves the draft, which was never cleared.
    let failing = ComposerController(
      EditorState(document: MarkdownCodec().parse("keep")),
      plugins: [SendAction { _ in throw Failure() }.clearing(.afterSuccess)])
    #expect(await failing.send().isFailed)
    #expect(failing.markdown == "keep")
  }

  @Test func willSendHooksRunInPriorityOrderAndCanChangeOrCancel() async {
    struct Hooks: ComposerPlugin {
      let cancel: Bool
      func register(in registry: inout PluginRegistry) {
        registry.addWillSend(priority: .low) { message in
          message.markdown += " low"
          return cancel ? .cancel : .proceed
        }
        registry.addWillSend(priority: .high) { message in
          message.markdown += " high"
          return .proceed
        }
        registry.addWillSend { message in
          message.markdown += " normal"
          return .proceed
        }
      }
    }
    let outbox = Outbox()
    let controller = controller("m", [Hooks(cancel: false)]) { await outbox.append($0) }
    #expect(await controller.send().isSent)
    #expect(await outbox.markdown == ["m high normal low"])

    let cancelled = self.controller("m", [Hooks(cancel: true)]) { await outbox.append($0) }
    #expect(await cancelled.send().isCancelled)
    #expect(cancelled.markdown == "m", "the draft stays")
    #expect(await outbox.markdown.count == 1)

    struct Throwing: ComposerPlugin {
      func register(in registry: inout PluginRegistry) {
        registry.addWillSend { _ in throw Failure() }
      }
    }
    let throwing = self.controller("m", [Throwing()]) { await outbox.append($0) }
    #expect(await throwing.send().isFailed)
    #expect(throwing.markdown == "m")
    #expect(await outbox.markdown.count == 1)
  }

  @Test func sendIsEnabledOnlyWithSomethingToSendAndNothingInFlight() {
    let controller = controller(
      "", [AttachmentsPlugin { _, _ in }, MaxLength(8, count: { $0.plainText.count })])
    #expect(!controller.isEnabled(SendAction.id), "empty")
    controller.insertText("  ")
    controller.insertLineBreak()
    #expect(!controller.isEnabled(SendAction.id), "whitespace only")
    controller.insert(mention("ann", id: "1"))
    #expect(controller.isEnabled(SendAction.id), "a token alone")
    controller.clear()
    let file = Attachment(id: .init("f"), payload: "f.png", status: .uploading(progress: 0.5))
    controller.addAttachments([file])
    #expect(!controller.isEnabled(SendAction.id), "uploading")
    controller.setStatus(.failed(Failure()), of: file.id)
    #expect(!controller.isEnabled(SendAction.id), "failed")
    controller.setStatus(.ready, of: file.id)
    #expect(controller.isEnabled(SendAction.id), "an attachment alone")
    controller.removeAttachment(file.id)
    controller.insertText("123456789")
    #expect(controller.state[MaxLength.statusKey]?.isOver == true)
    #expect(!controller.isEnabled(SendAction.id), "over a soft limit")
    controller.deleteBackward()
    #expect(controller.isEnabled(SendAction.id))
  }

  @Test func returnSendsOutsideCodeAndListsWhereItKeepsItsBlockRules() async {
    let outbox = Outbox()
    let controller = controller("- item") { await outbox.append($0) }
    controller.handleKeyPress(.return)
    #expect(controller.markdown == "- item\n-", "a new item, not a send")
    controller.handleKeyPress(.return)
    #expect(controller.markdown == "- item", "an empty item exits the list")
    controller.insertText("x")
    controller.handleKeyPress(.return, modifiers: .shift)
    #expect(controller.document.plainText == "item\nx\n", "⇧↩ is a line break")
    controller.setDocument(MarkdownCodec().parse("```\ncode\n```"))
    controller.handleKeyPress(.return)
    #expect(controller.markdown == "```\ncode\n\n```")
    controller.handleKeyPress(.return, modifiers: .command)
    await Task.yield()
    while controller.isSending { await Task.yield() }
    #expect(await outbox.markdown == ["```\ncode\n\n```"], "⌘↩ sends anywhere")

    controller.insertText("plain")
    controller.handleKeyPress(.return)
    while controller.isSending || !controller.document.isEmpty { await Task.yield() }
    #expect(await outbox.markdown.last == "plain")

    // Where ↩ doesn't send (iOS), it inserts a newline.
    let ios = self.controller("a", returnSends: false)
    ios.handleKeyPress(.return)
    #expect(ios.document.blocks.count == 2)
  }

  @Test func contextsShowAsSaveClearOnEscapeAndUpEditsTheLastMessage() {
    let edited = Document(blocks: [paragraph(text("old"))])
    let controller = ComposerController(plugins: [
      SendAction { _ in },
      ReplyAndEdit { controller in
        controller.setContext(Reply(id: "last", kind: .edit), document: edited)
        return true
      },
    ])
    let send = controller.action(SendAction.id)!
    #expect("\(controller.label(of: send))".contains("Send"))
    controller.handleKeyPress(.upArrow)
    #expect(controller.context?.kind == .edit)
    #expect(controller.document == edited)
    #expect(controller.selection == .caret(3))
    #expect("\(controller.label(of: send))".contains("Save"))
    // ↑ in a non-empty composer moves the caret instead (not handled here).
    #expect(!controller.handleKeyPress(.upArrow))
    #expect(controller.handleKeyPress(.escape))
    #expect(controller.context == nil)
    #expect(!controller.handleKeyPress(.escape), "nothing to clear")
  }

  @Test func actionsArePlacedPerPlatformAndPerformOnlyWhenEnabled() async throws {
    let controller = ComposerController(plugins: [
      SendAction { _ in }.placement(.init(macOS: .trailing, iOS: .trailing)),
      AttachmentPicker { controller in
        controller.addAttachments([Attachment(payload: 0, status: .ready)])
      },
    ])
    #expect(controller.actions(.leading).map(\.id) == [AttachmentPicker.id])
    #expect(controller.actions(.trailing).map(\.id) == [SendAction.id])
    #expect(try await !controller.perform(SendAction.id), "nothing to send")
    #expect(try await controller.perform(AttachmentPicker.id))
    #expect(controller.attachments.count == 1)
    #expect(controller.isEnabled(SendAction.id))
  }
}

@MainActor @Suite struct MaxLengthTests {
  @Test func aHardLimitStopsTypingAndTruncatesPastesOnCharacterBoundaries() {
    let truncated = Outbox()
    let controller = ComposerController(plugins: [
      MaxLength(6, mode: .hard).onDidTruncate { removed in
        Task { await truncated.append(ComposerMessage(document: .empty, markdown: removed)) }
      }
    ])
    type(controller, "abcde")
    controller.paste(.plainText("👍🏽👍🏽"))
    #expect(controller.document.plainText == "abcde👍🏽", "a whole emoji, not half")
    #expect(controller.state[MaxLength.statusKey]?.count == 6)
    controller.insertText("x")
    #expect(controller.document.plainText == "abcde👍🏽", "typing stops at the limit")
    // In the middle: what's after the caret stays, and the caret ends
    // after what was kept.
    controller.selection = .caret(2)
    controller.deleteBackward()
    controller.paste(.plainText("XYZ"))
    #expect(controller.document.plainText == "aXcde👍🏽")
    #expect(controller.selection == .caret(2))
  }

  @Test func theDefaultCountIsTheMarkdownLength() {
    let controller = ComposerController(
      EditorState(document: MarkdownCodec().parse("**ab**")), plugins: [MaxLength(8, mode: .hard)])
    #expect(controller.state[MaxLength.statusKey]?.count == 6, "there from the start")
    controller.selection = .caret(2)
    type(controller, "cde")
    #expect(controller.markdown == "**abcd**", "markdown is 8")
    let custom = ComposerController(plugins: [
      MaxLength(3, mode: .hard, count: { $0.plainText.count })
    ])
    custom.paste(.plainText("**abcdef**"))
    #expect(custom.document.plainText == "**a", "without markdown paste, the text")
  }

  @Test func aSoftLimitLetsTypingContinue() {
    let controller = ComposerController(plugins: [MaxLength(3)])
    type(controller, "abcde")
    let status = controller.state[MaxLength.statusKey]
    #expect(status == LengthStatus(count: 5, limit: 3, mode: .soft))
    #expect(status?.remaining == -2)
  }
}

extension SendOutcome {
  var isSent: Bool { if case .sent = self { true } else { false } }
  var isFailed: Bool { if case .failed = self { true } else { false } }
  var isCancelled: Bool { if case .cancelled = self { true } else { false } }
  var isUnavailable: Bool { if case .unavailable = self { true } else { false } }
}
