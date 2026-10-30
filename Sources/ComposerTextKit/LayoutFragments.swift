#if canImport(UIKit) || canImport(AppKit)
  import ComposerCore
  #if canImport(UIKit)
    import UIKit

    private typealias BezierPath = UIBezierPath
  #else
    import AppKit

    private typealias BezierPath = NSBezierPath
  #endif

  /// Gives decorated blocks (lists, quotes, code) a fragment that draws their
  /// decoration. Set it as the text layout manager's delegate.
  package final class LayoutFragmentProvider: NSObject, NSTextLayoutManagerDelegate,
    @unchecked Sendable
  {
    package let styles: TextStyles

    package init(styles: TextStyles) { self.styles = styles }

    package func textLayoutManager(
      _ textLayoutManager: NSTextLayoutManager,
      textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
      if let paragraph = textElement as? NSTextParagraph,
        paragraph.attributedString.length > 0,
        let decoration = paragraph.attributedString.attribute(
          .composerBlock, at: 0, effectiveRange: nil) as? BlockDecoration,
        !decoration.isPlain
      {
        return DecoratedLayoutFragment(
          textElement: textElement, range: textElement.elementRange, decoration: decoration,
          styles: styles)
      }
      return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
  }

  /// Draws a block's list marker, quote bars, or code background around its
  /// text.
  final class DecoratedLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    let decoration: BlockDecoration
    let styles: TextStyles

    init(
      textElement: NSTextElement, range: NSTextRange?, decoration: BlockDecoration,
      styles: TextStyles
    ) {
      self.decoration = decoration
      self.styles = styles
      super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) {
      fatalError("DecoratedLayoutFragment isn't archived")
    }

    /// The paragraph's head indent, where its text starts.
    private var headIndent: CGFloat {
      CGFloat(decoration.depth) * styles.indent + (decoration.isCode ? 8 : 0)
    }

    /// The text container's left edge and width, in the fragment's
    /// coordinates. TextKit may or may not start the fragment's frame at the
    /// head indent, so this goes from where the first line's text starts.
    private var container: (left: CGFloat, width: CGFloat) {
      let textStart = textLineFragments.first?.typographicBounds.minX ?? 0
      let width = textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX
      return (textStart - headIndent, width)
    }

    /// Decorations sit in the indent, left of the text, and code backgrounds
    /// span the container's width.
    override var renderingSurfaceBounds: CGRect {
      let (left, width) = container
      return super.renderingSurfaceBounds.union(
        CGRect(x: left, y: 0, width: max(width, 1), height: layoutFragmentFrame.height))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
      withGraphicsContext(context) { drawDecoration(at: point) }
      super.draw(at: point, in: context)
    }

    private func drawDecoration(at point: CGPoint) {
      let frame = layoutFragmentFrame
      let indent = styles.indent
      let (containerLeft, containerWidth) = container
      let left = point.x + containerLeft
      if decoration.isCode {
        // Lines of a code block join into one background: a single line is
        // rounded, and the lines of a longer block meet edge to edge.
        let x = left + CGFloat(decoration.depth) * indent
        let height = frame.height - (decoration.isLastLine ? styles.blockSpacing : 0)
        let rect = CGRect(x: x, y: point.y, width: left + containerWidth - x, height: height)
        styles.codeBackground.setFill()
        let single = decoration.isFirstLine && decoration.isLastLine
        bezierPath(roundedRect: rect, radius: single ? 5 : 0).fill()
      }
      styles.secondary.setFill()
      for level in decoration.quoteLevels {
        let x = left + CGFloat(level) * indent + 4
        // Quote bars run through the block spacing so lines and blocks join.
        bezierPath(
          roundedRect: CGRect(x: x, y: point.y, width: 3, height: frame.height), radius: 0
        ).fill()
      }
      if let marker = decoration.markerText, let line = textLineFragments.first {
        let text = NSAttributedString(
          string: marker,
          attributes: [.font: styles.base, .foregroundColor: styles.secondary])
        let size = text.size()
        let gutterEnd = left + CGFloat(decoration.markerLevel + 1) * indent - 6
        let lineBounds = line.typographicBounds
        text.draw(
          at: CGPoint(
            x: gutterEnd - size.width,
            y: point.y + lineBounds.minY + (lineBounds.height - size.height) / 2))
      }
    }

    private func bezierPath(roundedRect rect: CGRect, radius: CGFloat) -> BezierPath {
      #if canImport(UIKit)
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
      #else
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
      #endif
    }

    private func withGraphicsContext(_ context: CGContext, _ body: () -> Void) {
      #if canImport(UIKit)
        UIGraphicsPushContext(context)
        body()
        UIGraphicsPopContext()
      #else
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
      #endif
    }
  }

  extension NSTextContentManager {
    /// The text range of a storage range.
    package func textRange(for range: NSRange) -> NSTextRange? {
      guard
        let start = location(documentRange.location, offsetBy: range.location),
        let end = location(start, offsetBy: range.length)
      else { return nil }
      return NSTextRange(location: start, end: end)
    }
  }

  extension NSTextLayoutManager {
    /// The rects of a range's selection segments, in text container
    /// coordinates. A collapsed range gives the caret's rect.
    package func segmentRects(for range: NSRange) -> [CGRect] {
      guard let contentManager = textContentManager,
        let textRange = contentManager.textRange(for: range)
      else { return [] }
      ensureLayout(for: textRange)
      var rects: [CGRect] = []
      enumerateTextSegments(in: textRange, type: .selection, options: []) { _, rect, _, _ in
        rects.append(rect)
        return true
      }
      return rects
    }
  }
#endif
