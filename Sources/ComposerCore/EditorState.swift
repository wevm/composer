/// The editor's state: the document, the selection, the IME composition, and
/// typed plugin state.
///
/// A copy-on-write struct: copies share storage until one is mutated, so
/// snapshots for undo, tests, and conformance comparisons are cheap. Equality
/// compares every field, so two engines can be compared value for value.
public struct EditorState: Sendable, Equatable {
  private var storage: Storage

  public init(
    document: Document = .empty, selection: Selection? = nil, markedText: MarkedText? = nil
  ) {
    storage = Storage(
      document: document,
      selection: selection ?? .caret(document.length),
      markedText: markedText)
  }

  /// The document. Prefer the editing methods (`replace`, `insert`, …): they
  /// report exactly what they touch. Assigning or mutating the document
  /// directly is reported as the smallest replacement that turns the old
  /// linear form into the new one.
  public var document: Document {
    get { storage.document }
    _modify {
      makeUnique()
      if storage.tracking == nil {
        yield &storage.document
      } else {
        let old = storage.document
        yield &storage.document
        if storage.document != old, let edit = old.difference(to: storage.document) {
          record(edit.range, length: edit.length, mapSelection: false)
        }
      }
    }
  }

  public var selection: Selection {
    get { storage.selection }
    set {
      makeUnique()
      storage.selection = newValue
    }
  }

  /// The IME composition in progress, if any. Transforms are paused while it
  /// exists and run on everything edited during it once it is cleared.
  public var markedText: MarkedText? {
    get { storage.markedText }
    set {
      makeUnique()
      storage.markedText = newValue
    }
  }

  /// The marks the next typed text takes instead of the text before the
  /// caret's, or `nil` to take those. Toggling a mark with no selection sets
  /// them (⌘B, then typing, types bold), and so does a markdown conversion,
  /// so that the converted mark ends at the closing delimiter. Typing uses
  /// them up, and an update that moves the selection outside a composition
  /// clears them, unless it sets them.
  public var storedMarks: Marks? {
    get { storage.storedMarks }
    set {
      makeUnique()
      storage.storedMarks = newValue
    }
  }

  /// The marks text typed at `position` takes: the stored marks, or else
  /// those of the text before it.
  public func typingMarks(at position: Position) -> Marks {
    storedMarks ?? document.marks(at: position)
  }

  /// Typed plugin state. Reading a key that was never set returns its
  /// default, and setting a key to its default removes it, so equality does
  /// not depend on whether a default was ever written.
  public subscript<State>(key: PluginKey<State>) -> State {
    get { storage.pluginState[key.name] as? State ?? key.defaultValue }
    set {
      makeUnique()
      if newValue == key.defaultValue {
        storage.pluginState[key.name] = nil
      } else {
        storage.pluginState[key.name] = newValue
      }
    }
  }

  public static func == (lhs: EditorState, rhs: EditorState) -> Bool {
    if lhs.storage === rhs.storage { return true }
    let (l, r) = (lhs.storage, rhs.storage)
    guard l.selection == r.selection, l.markedText == r.markedText,
      l.storedMarks == r.storedMarks,
      l.pluginState.count == r.pluginState.count, l.document == r.document
    else { return false }
    for (name, value) in l.pluginState {
      guard let other = r.pluginState[name], isEqual(value, other) else { return false }
    }
    return true
  }

  private mutating func makeUnique() {
    if !isKnownUniquelyReferenced(&storage) { storage = storage.copy() }
  }

  // MARK: Tracking (used by updates)

  /// Mutates the document without reporting a change; the caller records it.
  mutating func withDocument<R>(_ body: (inout Document) -> R) -> R {
    makeUnique()
    return body(&storage.document)
  }

  /// Reports that `edited` (in current coordinates) was replaced by `length`
  /// units: adds it to the changeset and the dirty ranges, and maps the
  /// selection and marked text through it.
  mutating func record(_ edited: Range<Int>, length: Int, mapSelection: Bool = true) {
    makeUnique()
    if mapSelection {
      storage.selection.anchor = storage.selection.anchor.mapped(through: edited, length: length)
      storage.selection.head = storage.selection.head.mapped(through: edited, length: length)
      if let marked = storage.markedText {
        storage.markedText?.range =
          marked.range.lowerBound.mapped(
            through: edited, length: length)..<marked.range.upperBound.mapped(
            through: edited, length: length)
      }
    }
    guard storage.tracking != nil else { return }
    storage.tracking!.edits.appendCoalescing(
      Changeset.Edit(range: .init(offsets: edited), replacementLength: length))
    storage.tracking!.dirty.apply(edited, length: length, markDirty: true)
    storage.tracking!.pass.apply(edited, length: length, markDirty: false)
  }

  /// Whether the plugin state under `name` is the same as `other`'s.
  func pluginState(named name: String, equals other: EditorState) -> Bool {
    switch (storage.pluginState[name], other.storage.pluginState[name]) {
    case (nil, nil): true
    case (let a?, let b?): isEqual(a, b)
    default: false
    }
  }

  mutating func removePluginState(named name: String) {
    guard storage.pluginState[name] != nil else { return }
    makeUnique()
    storage.pluginState[name] = nil
  }

  /// Takes `other`'s plugin state, for restoring a snapshot.
  mutating func copyPluginState(from other: EditorState) {
    makeUnique()
    storage.pluginState = other.storage.pluginState
  }

  var tracking: Tracking? {
    get { storage.tracking }
    set {
      makeUnique()
      storage.tracking = newValue
    }
  }

  struct Tracking: Sendable {
    var edits: [Changeset.Edit] = []
    /// Ranges edited since the current transform pass began.
    var dirty = DirtyRanges()
    /// The ranges the current transform pass is visiting, kept in current
    /// coordinates as transforms edit.
    var pass = DirtyRanges()
    /// Whether the update typed one character, from the keyboard or an
    /// input method's commit: input rules convert what is typed, never a
    /// paste.
    var isTyping = false
    /// Text a hard length limit removed (see `MaxLength`).
    var truncated = ""
  }

  // Safe to share across threads: storage is only mutated when uniquely
  // referenced.
  private final class Storage: @unchecked Sendable {
    var document: Document
    var selection: Selection
    var markedText: MarkedText?
    var storedMarks: Marks?
    var pluginState: [String: any Equatable & Sendable]
    /// Bookkeeping for an update in progress; not part of equality.
    var tracking: Tracking?

    init(
      document: Document, selection: Selection, markedText: MarkedText?,
      storedMarks: Marks? = nil, pluginState: [String: any Equatable & Sendable] = [:],
      tracking: Tracking? = nil
    ) {
      self.document = document
      self.selection = selection
      self.markedText = markedText
      self.storedMarks = storedMarks
      self.pluginState = pluginState
      self.tracking = tracking
    }

    func copy() -> Storage {
      Storage(
        document: document, selection: selection, markedText: markedText,
        storedMarks: storedMarks, pluginState: pluginState, tracking: tracking)
    }
  }
}

private func isEqual(_ lhs: any Equatable & Sendable, _ rhs: any Equatable & Sendable) -> Bool {
  func open<T: Equatable>(_ lhs: T) -> Bool { (rhs as? T) == lhs }
  return open(lhs)
}
