// Attribute mapping: a document's linear form as an attributed string, one
// character per unit, so a document position is a text storage offset.
//
// - Text blocks are separated by "\n", a paragraph break.
// - A newline inside a paragraph or code block is U+2028 (line separator), so
//   every text block is one TextKit paragraph.
// - An atomic or unknown inline node is one attachment character (U+FFFC).
// - Every character of a block, and the separator after it, carries the
//   block's paragraph style and `BlockDecoration`, which the layout fragments
//   draw (list markers, quote bars, code backgrounds).
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

    package init(containers: [TextBlock.Container], isCode: Bool) {
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
    }

    /// Whether a plain layout fragment would draw the block the same.
    package var isPlain: Bool { quoteLevels.isEmpty && marker == nil && !isCode }

    package var markerText: String? {
      switch marker {
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
          && isCode == other.isCode)
    }

    override package var hash: Int {
      var hasher = Hasher()
      hasher.combine(depth)
      hasher.combine(quoteLevels)
      hasher.combine(marker)
      hasher.combine(isCode)
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
        nonisolated(unsafe) let text = text
        nonisolated(unsafe) let background = background
        image = NSImage(size: size, flipped: true) { rect in
          background.setFill()
          NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
          text.draw(at: textOrigin)
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
        let attributes = self.attributes(
          for: BlockDecoration(containers: containers, isCode: isCode))
        let lower = max(start, range.lowerBound)
        let upper = min(end, range.upperBound)
        if lower < upper {
          append(block.content, in: lower - start..<upper - start, attributes, to: result)
        }
        // The separator after the block, which belongs to its paragraph.
        if end < documentLength, range.contains(end) {
          result.append(NSAttributedString(string: "\n", attributes: attributes))
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
      style.paragraphSpacing = styles.blockSpacing
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
          NSAttributedString(string: Self.slice(text, local), attributes: attributes))
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
              ? Self.storageText(text) : Self.slice(text, lower - offset..<upper - offset)
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

    /// Text as it is stored: newlines become line separators.
    package static func storageText(_ text: String) -> String {
      text.contains("\n") ? text.replacingOccurrences(of: "\n", with: "\u{2028}") : text
    }

    /// UTF-16 units `local` of `text`, as stored.
    private static func slice(_ text: String, _ local: Range<Int>) -> String {
      storageText(
        (text as NSString).substring(with: NSRange(location: local.lowerBound, length: local.count))
      )
    }
  }
#endif
