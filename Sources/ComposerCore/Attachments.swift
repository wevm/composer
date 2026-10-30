import Foundation

/// A file in the attachments tray. The app owns the payload and the upload:
/// it adds attachments, updates their status as they upload, and gets them
/// back in the sent message.
public struct Attachment: Sendable, Identifiable, Equatable {
  public struct ID: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// A new unique id.
    public init() { rawValue = UUID().uuidString }
    public var description: String { rawValue }
  }

  public enum Status: Sendable {
    case pending
    case uploading(progress: Double)
    case failed(any Error)
    case ready
  }

  public var id: ID
  /// The app's data for the attachment: a file URL, image data, an upload
  /// handle. Treated as fixed for an id: equality ignores it.
  public var payload: any Sendable
  /// A name to show and for VoiceOver, such as the file name.
  public var name: String?
  public var status: Status

  public init(
    id: ID = ID(), payload: any Sendable, name: String? = nil, status: Status = .pending
  ) {
    self.id = id
    self.payload = payload
    self.name = name
    self.status = status
  }

  /// Whether the attachment is still on its way: pending or uploading.
  public var isInFlight: Bool {
    switch status {
    case .pending, .uploading: true
    case .failed, .ready: false
    }
  }

  public static func == (lhs: Attachment, rhs: Attachment) -> Bool {
    guard lhs.id == rhs.id, lhs.name == rhs.name else { return false }
    switch (lhs.status, rhs.status) {
    case (.pending, .pending), (.ready, .ready): return true
    case (.uploading(let a), .uploading(let b)): return a == b
    // Errors aren't comparable; one failure is the same as another.
    case (.failed, .failed): return true
    default: return false
    }
  }
}

extension EditorState {
  static let attachmentsKey = PluginKey<[Attachment]>("composer.attachments", default: [])

  /// The attachments tray, in the order added.
  public var attachments: [Attachment] {
    get { self[Self.attachmentsKey] }
    set { self[Self.attachmentsKey] = newValue }
  }
}

extension ComposerController {
  /// Adds attachments to the tray and tells the plugin's `onAdd` about each,
  /// so the app can start uploading.
  public func addAttachments(_ attachments: [Attachment]) {
    guard !attachments.isEmpty else { return }
    update { $0.attachments.append(contentsOf: attachments) }
    for attachment in attachments { attachmentAdded?(attachment, self) }
  }

  /// Updates an attachment's status, as its upload progresses.
  public func setStatus(_ status: Attachment.Status, of id: Attachment.ID) {
    update(undo: .none) { state in
      guard let index = state.attachments.firstIndex(where: { $0.id == id }) else { return }
      state.attachments[index].status = status
    }
  }

  public func removeAttachment(_ id: Attachment.ID) {
    update { $0.attachments.removeAll { $0.id == id } }
  }
}

/// The attachments tray. `onAdd` is called for every attachment added, from
/// any source (the picker, paste, drop), so the app can upload it and report
/// progress with `setStatus(_:of:)`. Sending is blocked while an attachment
/// is pending or uploading, or has failed (see `SendAction`).
public struct AttachmentsPlugin: ComposerPlugin {
  let onAdd: @MainActor @Sendable (Attachment, ComposerController) -> Void

  public init(onAdd: @escaping @MainActor @Sendable (Attachment, ComposerController) -> Void) {
    self.onAdd = onAdd
  }

  public func register(in registry: inout PluginRegistry) {
    registry.attachmentAdded = onAdd
  }
}

/// The attachment picker: a leading action that runs `pick`, which shows
/// the app's picker and adds what was picked with `addAttachments(_:)`.
public struct AttachmentPicker: ComposerPlugin {
  public static let id: ComposerAction.ID = "attach"

  let label: LocalizedText
  let systemImage: String
  let placement: ComposerAction.Placement.PerPlatform
  let pick: @MainActor @Sendable (ComposerController) async throws -> Void

  public init(
    label: LocalizedText? = nil, systemImage: String = "paperclip",
    placement: ComposerAction.Placement.PerPlatform = .leading,
    pick: @escaping @MainActor @Sendable (ComposerController) async throws -> Void
  ) {
    self.label = label ?? CoreStrings.attach
    self.systemImage = systemImage
    self.placement = placement
    self.pick = pick
  }

  public func register(in registry: inout PluginRegistry) {
    registry.addAction(
      ComposerAction(
        id: Self.id, label: label, systemImage: systemImage, placement: placement, perform: pick))
  }
}
