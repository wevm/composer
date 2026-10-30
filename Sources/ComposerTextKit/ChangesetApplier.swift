#if canImport(UIKit) || canImport(AppKit)
  import ComposerCore
  #if canImport(UIKit)
    import UIKit
  #else
    import AppKit
  #endif

  /// Applies changesets to a text storage that mirrors a document (see
  /// `AttributeMapper`), touching only the edited span.
  package enum ChangesetApplier {
    private static let separator = CharacterSet(charactersIn: "\n")

    /// Replaces the storage's contents with the whole document.
    package static func load(
      _ document: Document, into storage: NSTextStorage, mapper: AttributeMapper
    ) {
      storage.beginEditing()
      storage.setAttributedString(mapper.attributedString(for: document))
      storage.endEditing()
    }

    /// Applies an update's edits, as one replacement of the span they cover.
    /// When the edit adds or removes a newline (a block separator or a line
    /// break) or spans blocks, the span grows to whole blocks, because which
    /// lines are first and last in a block, and which blocks follow in a list,
    /// change their attributes.
    package static func apply(
      _ changeset: Changeset, document: Document, to storage: NSTextStorage,
      mapper: AttributeMapper
    ) {
      guard let edit = changeset.combinedEdit else { return }
      var old = edit.range.lowerBound.offset..<edit.range.upperBound.offset
      var new = old.lowerBound..<old.lowerBound + edit.replacementLength
      let length = document.length
      guard old.upperBound <= storage.length, new.upperBound <= length else {
        // The storage is out of step with the document; resynchronize.
        load(document, into: storage, mapper: mapper)
        return
      }
      let string = storage.string as NSString
      let removesNewline =
        string.rangeOfCharacter(
          from: separator, options: .literal,
          range: NSRange(location: old.lowerBound, length: old.count)
        ).location != NSNotFound
      let first = document.textBlock(containing: Position(new.lowerBound))
      let crossesBlocks = first.map { $0.range.upperBound.offset < new.upperBound } ?? true
      var replacement = mapper.attributedString(for: document, in: new, documentLength: length)
      let addsNewline =
        (replacement.string as NSString).rangeOfCharacter(from: separator).location != NSNotFound
      if removesNewline || addsNewline || crossesBlocks {
        let lower = first?.range.lowerBound.offset ?? 0
        // Blocks after the edit inside containers restyle too: inserting or
        // removing a list item renumbers the items after it.
        var upper = new.upperBound
        var extending = true
        document.forEachTextBlock(in: Position(new.upperBound)..<Position(length)) {
          block, containers in
          guard extending else { return }
          if block.range.lowerBound.offset > new.upperBound, containers.isEmpty {
            extending = false
            return
          }
          upper = block.range.upperBound.offset
          extending = !containers.isEmpty
        }
        // The separator after the last block takes its paragraph style too.
        if upper < length { upper += 1 }
        let grow = upper - new.upperBound
        new = lower..<upper
        old = lower..<min(old.upperBound + grow, storage.length)
        replacement = mapper.attributedString(for: document, in: new, documentLength: length)
      }
      storage.beginEditing()
      storage.replaceCharacters(
        in: NSRange(location: old.lowerBound, length: old.count), with: replacement)
      storage.endEditing()
    }

    /// How the storage differs from a fresh rendering of the document, or
    /// `nil` if it doesn't. Attachments compare by their labels.
    package static func mismatch(
      of storage: NSAttributedString, with document: Document, mapper: AttributeMapper
    ) -> String? {
      let expected = mapper.attributedString(for: document)
      if storage.string != expected.string {
        return
          "text \(storage.string.debugDescription), expected \(expected.string.debugDescription)"
      }
      let actual = comparable(storage)
      let wanted = comparable(expected)
      var location = 0
      while location < wanted.length {
        var actualRun = NSRange()
        var wantedRun = NSRange()
        let have = actual.attributes(at: location, effectiveRange: &actualRun)
        let want = wanted.attributes(at: location, effectiveRange: &wantedRun)
        if !(have as NSDictionary).isEqual(want as NSDictionary) {
          return "attributes at \(location): \(have), expected \(want)"
        }
        location = min(NSMaxRange(actualRun), NSMaxRange(wantedRun))
      }
      return nil
    }

    /// A copy with attachments replaced by their labels, which compare by
    /// value.
    private static func comparable(_ string: NSAttributedString) -> NSAttributedString {
      let copy = NSMutableAttributedString(attributedString: string)
      let whole = NSRange(location: 0, length: copy.length)
      copy.enumerateAttribute(.attachment, in: whole) { value, range, _ in
        guard let value else { return }
        copy.removeAttribute(.attachment, range: range)
        let label = (value as? TokenAttachment)?.label ?? "\(type(of: value))"
        copy.addAttribute(NSAttributedString.Key("attachmentLabel"), value: label, range: range)
      }
      return copy
    }
  }
#endif
