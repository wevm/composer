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

  extension NSRange {
    /// The storage range of a document range: offsets are the same.
    package init(_ range: DocumentRange) {
      self.init(location: range.lowerBound.offset, length: range.length)
    }
  }

  extension Range where Bound == Position {
    /// The document range of a storage range.
    package init(nsRange range: NSRange) {
      self = Position(range.location)..<Position(range.location + range.length)
    }
  }

  /// Text from storage as document text: line separators become newlines,
  /// and attachment characters are dropped (tokens don't paste as text).
  package func documentText(_ storageText: String) -> String {
    guard storageText.contains("\u{2028}") || storageText.contains("\u{FFFC}") else {
      return storageText
    }
    return storageText.replacingOccurrences(of: "\u{2028}", with: "\n")
      .replacingOccurrences(of: "\u{FFFC}", with: "")
  }
#endif
