// Attribute mapping: a document's linear form as an attributed string, one
// character per unit, so a document position is a text storage offset.
//
// - Text blocks are separated by "\n", and a newline inside a paragraph or
//   code block is "\n" too, so every line is a TextKit paragraph. (One TextKit
//   paragraph per block would be simpler, but TextKit 2 lays out a paragraph
//   whole: a 20k-character pasted block took seconds.)
// - An atomic or unknown inline node is one attachment character (U+FFFC).
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

  /// A token: an atomic or unknown node, drawn as its label on a rounded
  /// background. One attachment character, so it is one document unit.
  package final class TokenAttachment: NSTextAttachment {
    package let label: String

    package init(label: String, styles: TextStyles) {
      self.label = label
      super.init(data: nil, ofType: nil)
      let font = styles.base
      let text = NSAttributedString(
        string: label, attributes: [.font: font, .foregroundColor: styles.tokenForeground])
      let textSize = text.size()
      let padding: CGFloat = 4
      let size = CGSize(
        width: ceil(textSize.width) + padding * 2, height: ceil(font.ascender - font.descender))
      let textOrigin = CGPoint(x: padding, y: (size.height - textSize.height) / 2)
      let background = styles.tokenBackground
      #if canImport(UIKit)
        image = UIGraphicsImageRenderer(size: size).image { _ in
          background.setFill()
          UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4).fill()
          text.draw(at: textOrigin)
        }
      #else
        nonisolated(unsafe) let drawnText = text
        image = NSImage(size: size, flipped: true) { rect in
          background.setFill()
          NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
          drawnText.draw(at: textOrigin)
          return true
        }
      #endif
      bounds = CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) {
      fatalError("TokenAttachment isn't archived")
    }
  }

  /// Renders documents, or spans of them, into attributed strings.
  package final class AttributeMapper {
    package let styles: TextStyles
    package let schema: Schema
    private var fonts: [Int: PlatformFont] = [:]
    private var blockAttributes: [BlockDecoration: [NSAttributedString.Key: Any]] = [:]

    package init(styles: TextStyles, schema: Schema = Schema()) {
      self.styles = styles
      self.schema = schema
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
        // block's end and separator.
        let sliceEnd = result.length
        for (index, lineBreak) in breaks.enumerated() {
          let lineStart = start + lineBreak + 1
          let lineEnd = index + 1 < breaks.count ? start + breaks[index + 1] + 1 : end + 1
          let from = max(lineStart, lower) - lower + sliceStart
          let to = min(lineEnd - lower + sliceStart, sliceEnd)
          guard from < to else { continue }
          let line = self.attributes(
            for: decoration.line(first: false, last: index == breaks.count - 1))
          result.addAttributes(
            [.paragraphStyle: line[.paragraphStyle]!, .composerBlock: line[.composerBlock]!],
            range: NSRange(location: from, length: to - from))
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
            appendToken(schema.fallbackText(node), attributes, to: result)
          case .unknown(let node):
            appendToken(node.text, attributes, to: result)
          }
        }
      }
    }

    private func appendToken(
      _ label: String, _ attributes: [NSAttributedString.Key: Any],
      to result: NSMutableAttributedString
    ) {
      var attributes = attributes
      attributes[.attachment] = TokenAttachment(label: label, styles: styles)
      result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
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
      return font
    }

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
