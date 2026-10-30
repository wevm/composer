// TextKit 2 code shared by the UIKit and AppKit engines: layout fragments,
// attribute mapping, and the changeset applier. Internal to the package, and
// empty on Linux.
#if canImport(UIKit)
  import UIKit

  public typealias PlatformFont = UIFont
  public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
  import AppKit

  public typealias PlatformFont = NSFont
  public typealias PlatformColor = NSColor
#endif

#if canImport(UIKit) || canImport(AppKit)
  /// The fonts, colors, and metrics a composer's text view renders with.
  public struct TextStyles {
    /// The body font. Bold and italic are derived from it.
    public var base: PlatformFont
    /// The font of inline code and code blocks.
    public var code: PlatformFont
    public var foreground: PlatformColor
    /// List markers and quote bars.
    public var secondary: PlatformColor
    public var link: PlatformColor
    /// Behind inline code and code blocks.
    public var codeBackground: PlatformColor
    /// Behind tokens (atomic nodes).
    public var tokenBackground: PlatformColor
    public var tokenForeground: PlatformColor
    /// How far each level of quote or list nesting indents.
    public var indent: CGFloat
    /// The space after each text block.
    public var blockSpacing: CGFloat

    public init(
      base: PlatformFont, code: PlatformFont, foreground: PlatformColor,
      secondary: PlatformColor, link: PlatformColor, codeBackground: PlatformColor,
      tokenBackground: PlatformColor, tokenForeground: PlatformColor, indent: CGFloat = 22,
      blockSpacing: CGFloat = 4
    ) {
      self.base = base
      self.code = code
      self.foreground = foreground
      self.secondary = secondary
      self.link = link
      self.codeBackground = codeBackground
      self.tokenBackground = tokenBackground
      self.tokenForeground = tokenForeground
      self.indent = indent
      self.blockSpacing = blockSpacing
    }

    /// The platform's body text styles.
    @MainActor public static var standard: TextStyles {
      #if canImport(UIKit)
        let base = UIFont.preferredFont(forTextStyle: .body)
        return TextStyles(
          base: base,
          code: .monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular),
          foreground: .label, secondary: .secondaryLabel, link: .link,
          codeBackground: .secondarySystemFill,
          tokenBackground: .tintColor.withAlphaComponent(0.14),
          tokenForeground: .tintColor)
      #else
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return TextStyles(
          base: base,
          code: .monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular),
          foreground: .textColor, secondary: .secondaryLabelColor, link: .linkColor,
          codeBackground: .quaternaryLabelColor.withAlphaComponent(0.08),
          tokenBackground: .controlAccentColor.withAlphaComponent(0.14),
          tokenForeground: .controlAccentColor)
      #endif
    }
  }
#endif

#if canImport(UIKit) || canImport(AppKit)
  import ComposerCore

  /// Text from storage as document text: attachment characters, which
  /// tokens with no label draw as, are dropped.
  package func documentText(_ storageText: String) -> String {
    guard storageText.contains("\u{FFFC}") else { return storageText }
    return storageText.replacingOccurrences(of: "\u{FFFC}", with: "")
  }
#endif

#if canImport(UIKit) || canImport(AppKit)
  /// The selection a text view's selected range stands for, in document
  /// positions. Text views don't say which end of a selection moved: a
  /// change made from the keyboard that keeps one end of the previous
  /// selection keeps that end as the anchor, so ⇧← makes a backward
  /// selection. Other selections run forward.
  ///
  /// A token is one unit drawn as several characters, so a caret the text
  /// view puts inside one moves to an edge: from the keyboard, the edge in
  /// the direction it was moving; otherwise, the nearer one.
  package func inferredSelection(
    _ range: NSRange, previous: Selection, fromKeyboard: Bool, map: StorageMap
  ) -> Selection {
    if range.length == 0 {
      let rounding: StorageMap.Rounding
      if fromKeyboard, let token = map.token(containing: range.location) {
        rounding = previous.head.offset <= token ? .up : .down
      } else {
        rounding = .nearest
      }
      return .caret(map.document(range.location, rounding: rounding))
    }
    let document = map.document(range)
    let lower = document.lowerBound
    let upper = document.upperBound
    if fromKeyboard, lower != upper, upper == previous.anchor, lower != previous.anchor {
      return Selection(anchor: upper, head: lower)
    }
    return Selection(lower..<upper)
  }
#endif
