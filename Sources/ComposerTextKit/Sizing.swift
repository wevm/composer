#if canImport(UIKit) || canImport(AppKit)
  #if canImport(UIKit)
    import UIKit
  #else
    import AppKit
  #endif

  /// Sizing a composer's text view to its text, between line limits.
  @MainActor
  package enum TextSizing {
    /// The height of one line of `font`.
    package static func lineHeight(of font: PlatformFont) -> CGFloat {
      #if canImport(UIKit)
        font.lineHeight
      #else
        ceil(font.ascender - font.descender + font.leading)
      #endif
    }

    /// The height a text view fits at: its text's height, clamped to
    /// `lineLimits` lines of `font`. `verticalInsets` is the space above and
    /// below the text. Layout runs no further than the upper limit, so a
    /// long document costs no more than a short one.
    package static func fittingHeight(
      of layoutManager: NSTextLayoutManager, lineLimits: ClosedRange<Int>, font: PlatformFont,
      verticalInsets: CGFloat
    ) -> CGFloat {
      let line = lineHeight(of: font)
      let lower = CGFloat(lineLimits.lowerBound) * line
      let upper = CGFloat(lineLimits.upperBound) * line
      let text = textHeight(of: layoutManager, upTo: upper)
      return (min(max(text, lower), upper) + verticalInsets).rounded(.up)
    }

    /// The height of the laid-out text, or of as much of it as reaches past
    /// `limit`.
    package static func textHeight(
      of layoutManager: NSTextLayoutManager, upTo limit: CGFloat
    ) -> CGFloat {
      guard let content = layoutManager.textContentManager else { return 0 }
      var height: CGFloat = 0
      var reachedEnd = true
      layoutManager.enumerateTextLayoutFragments(
        from: content.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        height = fragment.layoutFragmentFrame.maxY
        if height > limit {
          reachedEnd = false
          return false
        }
        return true
      }
      // The usage bounds include the line after a final newline, where the
      // caret sits.
      if reachedEnd { height = max(height, layoutManager.usageBoundsForTextContainer.maxY) }
      return height
    }
  }
#endif
