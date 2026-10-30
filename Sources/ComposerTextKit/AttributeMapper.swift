// Attribute mapping: a document's linear form as an attributed string, one
// character per unit of text, so with no tokens a document position is a
// text storage offset.
//
// - Text blocks are separated by "\n", and a newline inside a paragraph or
//   code block is "\n" too, so every line is a TextKit paragraph. (One TextKit
//   paragraph per block would be simpler, but TextKit 2 lays out a paragraph
//   whole: a 20k-character pasted block took seconds.)
// - An atomic or unknown inline node is one document unit drawn as its label,
//   styled as a token (see `StorageMap` for the offsets this shifts).
// - Every character of a line, and the newline after it, carries the line's
//   paragraph style and `BlockDecoration`, which says which block and line it
//   is in. Only a block's last line has the space after the block, and the
//   layout fragments draw the decoration (list markers on a block's first
//   line, quote bars, code backgrounds).
#if canImport(UIKit) || canImport(AppKit)
  import ComposerCore
  #if canImport(UIKit)
    import UIKit
  #else
    import AppKit
  #endif

  extension NSAttributedString.Key {
    /// A text block's `BlockDecoration`.
    package static let composerBlock = NSAttributedString.Key("dev.wevm.composer.block")
    /// A link's destination. Links are styled rather than set as `.link`, so
    /// clicking one while editing places the caret instead of opening it.
    package static let composerLink = NSAttributedString.Key("dev.wevm.composer.link")
    /// A token's `TokenInfo`, on each character of its label.
    package static let composerToken = NSAttributedString.Key("dev.wevm.composer.token")
  }

  /// A token, on its label's characters: what it reads as, for VoiceOver
  /// and tests. Compared by value.
  package final class TokenInfo: NSObject, @unchecked Sendable {
    package let label: String
    package let spokenLabel: String

    package init(label: String, spokenLabel: String) {
      self.label = label
      self.spokenLabel = spokenLabel
    }

    override package func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? TokenInfo else { return false }
      return label == other.label && spokenLabel == other.spokenLabel
    }

    override package var hash: Int { label.hashValue ^ spokenLabel.hashValue }
  }

  /// What a text block's layout fragment draws around its text.
  package final class BlockDecoration: NSObject, @unchecked Sendable {
    package enum Marker: Hashable, Sendable {
      /// A bullet; `depth` counts the bullet lists around it.
      case bullet(depth: Int)
      case ordered(Int)
      case task(checked: Bool)
    }

    /// How many containers indent the block.
    package let depth: Int
    /// The indent levels that draw a quote bar.
    package let quoteLevels: [Int]
    /// The list marker, drawn in the gutter of level `markerLevel`.
    package let marker: Marker?
    package let markerLevel: Int
    package let isCode: Bool
    /// Whether this is the block's first line, or its last.
    package let isFirstLine: Bool
    package let isLastLine: Bool

    package init(
      containers: [TextBlock.Container], isCode: Bool, isFirstLine: Bool = true,
      isLastLine: Bool = true
    ) {
      var quoteLevels: [Int] = []
      var marker: Marker?
      var bulletDepth = 0
      for (level, container) in containers.enumerated() {
        switch container {
        case .quote:
          quoteLevels.append(level)
        case .listItem(let kind, let index, let checked, let isFirstBlock):
          if level == containers.count - 1, isFirstBlock {
            if let checked {
              marker = .task(checked: checked)
            } else if case .ordered(let start) = kind {
              marker = .ordered(start + index)
            } else {
              marker = .bullet(depth: bulletDepth)
            }
          }
          if kind == .bullet { bulletDepth += 1 }
        }
      }
      self.depth = containers.count
      self.quoteLevels = quoteLevels
      self.marker = marker
      self.markerLevel = max(containers.count - 1, 0)
      self.isCode = isCode
      self.isFirstLine = isFirstLine
      self.isLastLine = isLastLine
    }

    private init(_ other: BlockDecoration, isFirstLine: Bool, isLastLine: Bool) {
      depth = other.depth
      quoteLevels = other.quoteLevels
      marker = other.marker
      markerLevel = other.markerLevel
      isCode = other.isCode
      self.isFirstLine = isFirstLine
      self.isLastLine = isLastLine
    }

    /// The decoration of another line of the same block.
    package func line(first: Bool, last: Bool) -> BlockDecoration {
      first == isFirstLine && last == isLastLine
        ? self : BlockDecoration(self, isFirstLine: first, isLastLine: last)
    }

    /// Whether a plain layout fragment would draw the block the same.
    package var isPlain: Bool { quoteLevels.isEmpty && markerText == nil && !isCode }

    /// The list marker, on the block's first line.
    package var markerText: String? {
      guard isFirstLine else { return nil }
      return switch marker {
      case nil: nil
      case .bullet(let depth): ["•", "◦", "▪"][depth % 3]
      case .ordered(let number): "\(number)."
      case .task(let checked): checked ? "☑" : "☐"
      }
    }

    override package func isEqual(_ object: Any?) -> Bool {
      guard let other = object as? BlockDecoration else { return false }
      return self === other
        || (depth == other.depth && quoteLevels == other.quoteLevels && marker == other.marker
          && isCode == other.isCode && isFirstLine == other.isFirstLine
          && isLastLine == other.isLastLine)
    }

    override package var hash: Int {
      var hasher = Hasher()
      hasher.combine(depth)
      hasher.combine(quoteLevels)
      hasher.combine(marker)
      hasher.combine(isCode)
      hasher.combine(isFirstLine)
      hasher.combine(isLastLine)
      return hasher.finalize()
    }
  }

  /// Renders documents, or spans of them, into attributed strings. Main
  /// actor, like the text views it serves, so views can share derived fonts.
  @MainActor
  package final class AttributeMapper {
    package let styles: TextStyles
    package let schema: Schema
    package let tokenStyles: [NodeType: TokenStyleOverride]
    private var fonts: [Int: PlatformFont] = [:]
    private var blockAttributes: [BlockDecoration: [NSAttributedString.Key: Any]] = [:]

    package init(
      styles: TextStyles, schema: Schema = Schema(),
      tokenStyles: [NodeType: TokenStyleOverride] = [:]
    ) {
      self.styles = styles
      self.schema = schema
      self.tokenStyles = tokenStyles
    }

    /// The text a token renders as: its label, never empty.
    package func tokenText(_ inline: Inline) -> String {
      let text: String
      switch inline {
      case .node(let node): text = schema.fallbackText(node)
      case .unknown(let node): text = node.text
      case .text: return ""
      }
      return text.isEmpty ? "\u{FFFC}" : text
    }

    /// The map between a document's positions and its rendering's offsets.
    package func storageMap(for document: Document) -> StorageMap {
      StorageMap(document: document) { self.tokenText($0).utf16.count }
    }

    /// The map after an update, from the map before it.
    package func storageMap(
      _ map: StorageMap, after edit: Changeset.Edit, in document: Document
    ) -> StorageMap {
      map.updated(edit, in: document) { self.tokenText($0).utf16.count }
    }

    /// The whole document.
    package func attributedString(for document: Document) -> NSAttributedString {
      attributedString(for: document, in: 0..<document.length, documentLength: document.length)
    }

    /// The units in `range` of the document's linear form.
    package func attributedString(
      for document: Document, in range: Range<Int>, documentLength: Int
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      result.beginEditing()
      document.forEachTextBlock(in: Position(range.lowerBound)..<Position(range.upperBound)) {
        block, containers in
        let start = block.range.lowerBound.offset
        let end = block.range.upperBound.offset
        var isCode = false
        if case .code = block.content { isCode = true }
        let breaks = Self.lineBreaks(in: block.content)
        let decoration = BlockDecoration(
          containers: containers, isCode: isCode, isLastLine: breaks.isEmpty)
        let sliceStart = result.length
        let lower = max(start, range.lowerBound)
        let upper = min(end, range.upperBound)
        let attributes = self.attributes(for: decoration)
        if lower < upper {
          append(block.content, in: lower - start..<upper - start, attributes, to: result)
        }
        // The separator after the block, which belongs to its last line.
        if end < documentLength, range.contains(end) {
          result.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        guard !breaks.isEmpty else { return }
        // Lines after the first: each runs to its newline, the last to the
        // block's end and separator. The slice is walked by its own newlines,
        // because tokens make storage offsets differ from document positions.
        let sliceEnd = result.length
        var line = breaks.prefix { start + $0 < lower }.count
        let string = result.mutableString
        var from = sliceStart
        while from < sliceEnd {
          let newline = string.range(
            of: "\n", options: .literal, range: NSRange(location: from, length: sliceEnd - from))
          let to = newline.location == NSNotFound ? sliceEnd : NSMaxRange(newline)
          if line > 0 {
            let style = self.attributes(
              for: decoration.line(first: false, last: line == breaks.count))
            result.addAttributes(
              [.paragraphStyle: style[.paragraphStyle]!, .composerBlock: style[.composerBlock]!],
              range: NSRange(location: from, length: to - from))
          }
          line += 1
          from = to
        }
      }
      result.endEditing()
      return result
    }

    /// The paragraph attributes of a block: the base font and color, the
    /// paragraph style, and the decoration.
    private func attributes(for decoration: BlockDecoration) -> [NSAttributedString.Key: Any] {
      if let cached = blockAttributes[decoration] { return cached }
      let style = NSMutableParagraphStyle()
      let indent = CGFloat(decoration.depth) * styles.indent + (decoration.isCode ? 8 : 0)
      style.firstLineHeadIndent = indent
      style.headIndent = indent
      if decoration.isCode { style.tailIndent = -8 }
      style.paragraphSpacing = decoration.isLastLine ? styles.blockSpacing : 0
      let attributes: [NSAttributedString.Key: Any] = [
        .font: decoration.isCode ? styles.code : styles.base,
        .foregroundColor: styles.foreground,
        .paragraphStyle: style.copy(),
        .composerBlock: decoration,
      ]
      blockAttributes[decoration] = attributes
      return attributes
    }

    private func append(
      _ content: TextBlock.Content, in local: Range<Int>,
      _ attributes: [NSAttributedString.Key: Any], to result: NSMutableAttributedString
    ) {
      switch content {
      case .code(_, let text):
        result.append(
          NSAttributedString(
            string: local == 0..<text.utf16.count ? text : Self.slice(text, local),
            attributes: attributes))
      case .paragraph(let inlines):
        var offset = 0
        for inline in inlines {
          let length = inline.length
          defer { offset += length }
          let lower = max(offset, local.lowerBound)
          let upper = min(offset + length, local.upperBound)
          guard lower < upper else {
            if offset >= local.upperBound { return }
            continue
          }
          switch inline {
          case .text(let text, let marks):
            let piece =
              lower == offset && upper == offset + length
              ? text : Self.slice(text, lower - offset..<upper - offset)
            result.append(
              NSAttributedString(string: piece, attributes: self.attributes(attributes, marks)))
          case .node(let node):
            appendToken(
              inline,
              style: tokenStyles[node.type].map { $0(schema.tokenStyle(node)) }
                ?? schema.tokenStyle(node),
              accessibilityLabel: schema.accessibilityLabel(node), attributes, to: result)
          case .unknown(let node):
            appendToken(
              inline, style: .standard, accessibilityLabel: node.text, attributes, to: result)
          }
        }
      }
    }

    private func appendToken(
      _ inline: Inline, style: TokenStyle, accessibilityLabel: String,
      _ attributes: [NSAttributedString.Key: Any], to result: NSMutableAttributedString
    ) {
      let label = tokenText(inline)
      var attributes = attributes
      if let foreground = style.foreground { attributes[.foregroundColor] = color(foreground) }
      if let background = style.background {
        attributes[.backgroundColor] = color(background).withAlphaComponent(
          style.backgroundOpacity)
      }
      if style.isBold { attributes[.font] = font(bold: true, italic: false, code: false) }
      attributes[.composerToken] = TokenInfo(label: label, spokenLabel: accessibilityLabel)
      result.append(NSAttributedString(string: label, attributes: attributes))
    }

    private func color(_ color: TokenStyle.Color) -> PlatformColor {
      switch color {
      case .accent: styles.tokenForeground
      case .primary: styles.foreground
      case .secondary: styles.secondary
      case .rgb(let red, let green, let blue):
        PlatformColor(red: red, green: green, blue: blue, alpha: 1)
      }
    }

    private func attributes(
      _ block: [NSAttributedString.Key: Any], _ marks: Marks
    ) -> [NSAttributedString.Key: Any] {
      guard !marks.isEmpty else { return block }
      var attributes = block
      let isCodeBlock = (block[.composerBlock] as? BlockDecoration)?.isCode ?? false
      attributes[.font] = font(
        bold: marks.bold, italic: marks.italic, code: marks.code || isCodeBlock)
      if marks.code, !isCodeBlock { attributes[.backgroundColor] = styles.codeBackground }
      if marks.strikethrough {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let link = marks.link {
        attributes[.foregroundColor] = styles.link
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        attributes[.composerLink] = link
      }
      return attributes
    }

    private func font(bold: Bool, italic: Bool, code: Bool) -> PlatformFont {
      let key = (bold ? 1 : 0) | (italic ? 2 : 0) | (code ? 4 : 0)
      if let font = fonts[key] { return font }
      // Deriving a font is slow enough to show in mount time, so views with
      // the same styles share derived fonts.
      let shared = SharedFontKey(base: styles.base, code: styles.code, traits: key)
      if let font = Self.sharedFonts[shared] {
        fonts[key] = font
        return font
      }
      let base = code ? styles.code : styles.base
      var font = base
      if bold || italic {
        var traits = base.fontDescriptor.symbolicTraits
        #if canImport(UIKit)
          if bold { traits.insert(.traitBold) }
          if italic { traits.insert(.traitItalic) }
          if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: base.pointSize)
          }
        #else
          if bold { traits.insert(.bold) }
          if italic { traits.insert(.italic) }
          font =
            NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize)
            ?? base
        #endif
      }
      fonts[key] = font
      Self.sharedFonts[shared] = font
      return font
    }

    private struct SharedFontKey: Hashable {
      var base: PlatformFont
      var code: PlatformFont
      var traits: Int
    }

    private static var sharedFonts: [SharedFontKey: PlatformFont] = [:]

    /// The offsets of the newlines in a text block, which end its lines.
    private static func lineBreaks(in content: TextBlock.Content) -> [Int] {
      var breaks: [Int] = []
      func scan(_ text: String, from offset: Int) {
        var index = offset
        for unit in text.utf16 {
          if unit == 0x0A { breaks.append(index) }
          index += 1
        }
      }
      switch content {
      case .code(_, let text):
        scan(text, from: 0)
      case .paragraph(let inlines):
        var offset = 0
        for inline in inlines {
          if case .text(let text, _) = inline { scan(text, from: offset) }
          offset += inline.length
        }
      }
      return breaks
    }

    /// UTF-16 units `local` of `text`.
    private static func slice(_ text: String, _ local: Range<Int>) -> String {
      (text as NSString).substring(with: NSRange(location: local.lowerBound, length: local.count))
    }
  }
#endif
