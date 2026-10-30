import Foundation

/// Rich paste: HTML on the pasteboard is mapped to the schema (see
/// DESIGN.md, Clipboard), and so is RTF, which the engines map from their
/// platform's attributed strings (`PasteSource.document`). Without this
/// plugin, engines paste only plain text and composer's own type.
public struct RichPaste: ComposerPlugin {
  public init() {}

  public func register(in registry: inout PluginRegistry) {
    registry.paste.acceptsRichText = true
    registry.addPasteMapper(HTMLPasteMapper())
  }
}

extension ComposerController {
  /// Whether engines should read HTML and RTF from the pasteboard
  /// (`RichPaste` is enabled).
  public var acceptsRichPaste: Bool { pasteConfiguration.acceptsRichText }
}

/// Maps HTML to a document fragment:
///
/// - `<b>`, `<strong>`, `<i>`, `<em>`, `<s>`, `<del>`, `<strike>`, `<code>`, and
///   `<a href>` become marks, as do `font-weight`, `font-style`, and
///   `text-decoration` in `style` attributes (a `<b style="font-weight:normal">`,
///   as Google Docs wraps everything in, isn't bold);
/// - `<p>`, `<div>`, `<br>`, `<pre>`, `<blockquote>`, `<ul>`, `<ol>`, and `<li>`
///   (with a checkbox `<input>`, a task item) become blocks, and headings bold
///   paragraphs;
/// - `<img>` becomes an attachment whose payload is the image's `URL`;
/// - everything else is dropped, keeping its text; whitespace collapses as a
///   browser would show it.
struct HTMLPasteMapper: PasteMapper {
  func map(_ source: PasteSource) -> PasteResult {
    guard case .html(let html) = source else { return .unhandled }
    let (document, attachments) = Self.map(html)
    if document.blocks.isEmpty {
      return attachments.isEmpty ? .unhandled : .attachments(attachments)
    }
    return attachments.isEmpty
      ? .document(document) : .content(document, attachments: attachments)
  }

  static func map(_ html: String) -> (document: Document, attachments: [Attachment]) {
    var builder = HTMLBuilder()
    var tokenizer = HTMLTokenizer(html)
    tokenizer.run { builder.handle($0) }
    return builder.finish()
  }
}

// MARK: Tokenizer

/// An HTML token, also made by engines from rich text so that RTF maps the
/// same way.
package enum HTMLToken {
  case text(String)
  case start(String, [String: String])
  case end(String)
}

/// A forgiving tokenizer: tags, attributes, character references, and the
/// raw text of `<script>`, `<style>`, and `<title>`, which is skipped.
struct HTMLTokenizer {
  private let scalars: [Unicode.Scalar]
  private var index = 0

  init(_ html: String) { scalars = Array(html.unicodeScalars) }

  mutating func run(_ emit: (HTMLToken) -> Void) {
    var text = String.UnicodeScalarView()
    func flush() {
      if !text.isEmpty { emit(.text(Self.decode(String(text)))) }
      text.removeAll()
    }
    while index < scalars.count {
      let scalar = scalars[index]
      guard scalar == "<", index + 1 < scalars.count else {
        text.append(scalar)
        index += 1
        continue
      }
      let next = scalars[index + 1]
      if next == "!" || next == "?" {
        flush()
        skipDeclaration()
      } else if next == "/" || next.properties.isAlphabetic {
        flush()
        guard let tag = readTag() else { continue }
        emit(tag)
        if case .start(let name, _) = tag, ["script", "style", "title"].contains(name) {
          skipRawText(until: name)
        }
      } else {
        text.append(scalar)
        index += 1
      }
    }
    flush()
  }

  private mutating func skipDeclaration() {
    if starts(with: "<!--") {
      index += 4
      while index < scalars.count, !starts(with: "-->") { index += 1 }
      index = min(index + 3, scalars.count)
    } else {
      while index < scalars.count, scalars[index] != ">" { index += 1 }
      index += 1
    }
  }

  private mutating func skipRawText(until name: String) {
    let closing = Array("</\(name)".unicodeScalars)
    while index + closing.count <= scalars.count {
      let candidate = scalars[index..<index + closing.count]
      if zip(closing, candidate).allSatisfy({ want, have in
        want == have || (have.isASCII && Unicode.Scalar(UInt8(have.value) | 0x20) == want)
      }) {
        return
      }
      index += 1
    }
    index = scalars.count
  }

  private func starts(with prefix: String) -> Bool {
    var position = index
    for scalar in prefix.unicodeScalars {
      guard position < scalars.count, scalars[position] == scalar else { return false }
      position += 1
    }
    return true
  }

  private mutating func readTag() -> HTMLToken? {
    index += 1  // <
    let isEnd = scalars[index] == "/"
    if isEnd { index += 1 }
    let name = readName().lowercased()
    var attributes: [String: String] = [:]
    while index < scalars.count, scalars[index] != ">" {
      let scalar = scalars[index]
      if scalar.properties.isWhitespace || scalar == "/" {
        index += 1
        continue
      }
      let key = readName().lowercased()
      if key.isEmpty {
        index += 1
        continue
      }
      skipWhitespace()
      var value = ""
      if index < scalars.count, scalars[index] == "=" {
        index += 1
        skipWhitespace()
        value = readValue()
      }
      attributes[key] = Self.decode(value)
    }
    index += 1  // >
    guard !name.isEmpty else { return nil }
    return isEnd ? .end(name) : .start(name, attributes)
  }

  private mutating func readName() -> String {
    var name = String.UnicodeScalarView()
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar.properties.isWhitespace || scalar == ">" || scalar == "/" || scalar == "=" {
        break
      }
      name.append(scalar)
      index += 1
    }
    return String(name)
  }

  private mutating func readValue() -> String {
    guard index < scalars.count else { return "" }
    var value = String.UnicodeScalarView()
    let quote = scalars[index]
    if quote == "\"" || quote == "'" {
      index += 1
      while index < scalars.count, scalars[index] != quote {
        value.append(scalars[index])
        index += 1
      }
      index += 1
    } else {
      while index < scalars.count, !scalars[index].properties.isWhitespace,
        scalars[index] != ">"
      {
        value.append(scalars[index])
        index += 1
      }
    }
    return String(value)
  }

  private mutating func skipWhitespace() {
    while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
  }

  private static let entities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
    "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
    "rdquo": "”", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
  ]

  /// Decodes character references: named ones, and `&#N;` and `&#xH;`.
  static func decode(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = ""
    var rest = Substring(text)
    while let ampersand = rest.firstIndex(of: "&") {
      result += rest[..<ampersand]
      let after = rest[rest.index(after: ampersand)...]
      guard let semicolon = after.prefix(10).firstIndex(of: ";") else {
        result += "&"
        rest = after
        continue
      }
      let name = after[..<semicolon]
      var decoded: String?
      if name.hasPrefix("#x") || name.hasPrefix("#X") {
        decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map {
          String($0)
        }
      } else if name.hasPrefix("#") {
        decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
      } else {
        decoded = entities[String(name)]
      }
      if let decoded {
        result += decoded
        rest = after[after.index(after: semicolon)...]
      } else {
        result += "&"
        rest = after
      }
    }
    return result + rest
  }
}

// MARK: Builder

package struct HTMLBuilder {
  enum Frame {
    case quote([Block])
    case list(ListKind, [ListItem])
    case item(checked: Bool?, [Block])
  }

  /// An inline tag's effect on the marks, undone at its end tag.
  struct InlineEffect {
    var name: String
    var marks: Marks
    /// Turns bold off, as `font-weight: normal` does.
    var clearsBold = false
  }

  var root: [Block] = []
  var frames: [Frame] = []
  var inlines: [Inline] = []
  var effects: [InlineEffect] = []
  var headings = 0
  /// Whether the text so far ends in a collapsed space.
  var afterSpace = false
  /// The code block being collected, inside `<pre>`.
  var pre: (language: String?, text: String)?
  var attachments: [Attachment] = []

  var marks: Marks {
    var marks = Marks()
    for effect in effects {
      if effect.clearsBold { marks.bold = false }
      marks = marks.union(effect.marks)
    }
    if headings > 0 { marks.bold = true }
    return marks
  }

  package init() {}

  package mutating func handle(_ token: HTMLToken) {
    switch token {
    case .text(let text): appendText(text)
    case .start(let name, let attributes): start(name, attributes)
    case .end(let name): end(name)
    }
  }

  package mutating func finish() -> (document: Document, attachments: [Attachment]) {
    if pre != nil { end("pre") }
    flushParagraph()
    while !frames.isEmpty { closeFrame() }
    return (Document(blocks: root).normalized(), attachments)
  }

  // MARK: Text

  mutating func appendText(_ text: String) {
    if pre != nil {
      pre!.text += text
      return
    }
    // Whitespace collapses to one space, which belongs to the text it is
    // in; none shows at the start of a line.
    var collapsed = ""
    var skipsSpace = afterSpace || atLineStart
    for character in text {
      if character.isWhitespace, character != "\u{A0}" {
        if !skipsSpace { collapsed.append(" ") }
        skipsSpace = true
      } else {
        collapsed.append(character == "\u{A0}" ? " " : character)
        skipsSpace = false
      }
    }
    guard !collapsed.isEmpty else { return }
    afterSpace = collapsed.hasSuffix(" ")
    inlines.append(.text(collapsed, marks: marks))
  }

  /// Whether nothing (or a line break) comes before in the paragraph.
  private var atLineStart: Bool {
    guard let last = inlines.last else { return true }
    if case .text(let text, _) = last { return text.hasSuffix("\n") }
    return false
  }

  mutating func flushParagraph() {
    afterSpace = false
    var content = inlines
    inlines.removeAll()
    // Trailing spaces and a trailing line break don't show.
    while case .text(let text, let marks)? = content.last {
      var trimmed = text
      while let last = trimmed.last, last == " " || last == "\n" { trimmed.removeLast() }
      if trimmed.isEmpty {
        content.removeLast()
        continue
      }
      content[content.count - 1] = .text(trimmed, marks: marks)
      break
    }
    content = Normalizer.inlines(content)
    guard !content.isEmpty else { return }
    append(.paragraph(content))
  }

  mutating func append(_ block: Block) {
    guard let top = frames.last else {
      root.append(block)
      return
    }
    switch top {
    case .quote(var children):
      children.append(block)
      frames[frames.count - 1] = .quote(children)
    case .item(let checked, var blocks):
      blocks.append(block)
      frames[frames.count - 1] = .item(checked: checked, blocks)
    case .list:
      // Content directly in a list, outside any item: an item of its own.
      frames.append(.item(checked: nil, [block]))
      closeFrame()
    }
  }

  /// Closes the innermost frame into its parent.
  mutating func closeFrame() {
    guard let frame = frames.popLast() else { return }
    switch frame {
    case .quote(let children):
      if !children.isEmpty { append(.quote(children)) }
    case .item(let checked, let blocks):
      let item = ListItem(checked: checked, blocks: blocks.isEmpty ? [.paragraph([])] : blocks)
      if case .list(let kind, var items)? = frames.last {
        items.append(item)
        frames[frames.count - 1] = .list(kind, items)
      } else {
        frames.append(.list(.bullet, [item]))
        closeFrame()
      }
    case .list(let kind, let items):
      if !items.isEmpty { append(.list(kind, items: items)) }
    }
  }

  // MARK: Tags

  static let blockTags: Set<String> = [
    "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure",
    "figcaption", "table", "thead", "tbody", "tr", "dl", "dt", "dd", "address", "hr", "body",
    "html",
  ]
  static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

  mutating func start(_ name: String, _ attributes: [String: String]) {
    if pre != nil {
      if name == "br" { pre!.text += "\n" }
      if name == "code", pre!.language == nil, let language = Self.language(attributes["class"]) {
        pre!.language = language
      }
      return
    }
    switch name {
    case _ where Self.blockTags.contains(name):
      flushParagraph()
    case _ where Self.headingTags.contains(name):
      flushParagraph()
      headings += 1
    case "br":
      inlines.append(.text("\n", marks: marks))
      afterSpace = false
    case "td", "th":
      if !inlines.isEmpty, !afterSpace { appendText(" ") }
    case "pre":
      flushParagraph()
      pre = (nil, "")
    case "blockquote":
      flushParagraph()
      frames.append(.quote([]))
    case "ul", "ol":
      flushParagraph()
      if case .list? = frames.last { frames.append(.item(checked: nil, [])) }
      let start = attributes["start"].flatMap { Int($0) } ?? 1
      frames.append(.list(name == "ol" ? .ordered(start: start) : .bullet, []))
    case "li":
      flushParagraph()
      if case .item? = frames.last { closeFrame() }
      if case .list? = frames.last {} else { frames.append(.list(.bullet, [])) }
      frames.append(.item(checked: nil, []))
    case "input":
      guard attributes["type"]?.lowercased() == "checkbox",
        case .item(_, let blocks)? = frames.last
      else { return }
      frames[frames.count - 1] = .item(checked: attributes["checked"] != nil, blocks)
    case "img":
      if let source = attributes["src"], let url = URL(string: source) {
        attachments.append(Attachment(payload: url, name: attributes["alt"]))
      }
    default:
      var effect = InlineEffect(name: name, marks: Marks())
      switch name {
      case "b", "strong": effect.marks.bold = true
      case "i", "em", "cite", "var": effect.marks.italic = true
      case "s", "del", "strike": effect.marks.strikethrough = true
      case "code", "kbd", "samp", "tt": effect.marks.code = true
      case "a":
        if let href = attributes["href"], !href.isEmpty, !href.hasPrefix("#"),
          !href.lowercased().hasPrefix("javascript:")
        {
          effect.marks.link = href
        }
      case "span", "font", "u", "mark", "small", "sup", "sub", "abbr", "label": break
      default: return
      }
      if let style = attributes["style"] { Self.apply(style: style, to: &effect) }
      effects.append(effect)
    }
  }

  mutating func end(_ name: String) {
    if let block = pre {
      guard name == "pre" else { return }
      pre = nil
      var text = block.text
      if text.hasPrefix("\n") { text.removeFirst() }
      if text.hasSuffix("\n") { text.removeLast() }
      append(.codeBlock(language: block.language, text: Normalizer.lineEndings(text)))
      return
    }
    switch name {
    case _ where Self.blockTags.contains(name):
      flushParagraph()
    case _ where Self.headingTags.contains(name):
      flushParagraph()
      headings = max(headings - 1, 0)
    case "blockquote":
      flushParagraph()
      close { if case .quote = $0 { true } else { false } }
    case "li":
      flushParagraph()
      close { if case .item = $0 { true } else { false } }
    case "ul", "ol":
      flushParagraph()
      close { if case .list = $0 { true } else { false } }
    default:
      if let index = effects.lastIndex(where: { $0.name == name }) {
        effects.removeSubrange(index...)
      }
    }
  }

  /// Closes frames up to and including the innermost one `matches` accepts,
  /// if there is one.
  private mutating func close(_ matches: (Frame) -> Bool) {
    guard frames.contains(where: matches) else { return }
    while let top = frames.last {
      let done = matches(top)
      closeFrame()
      if done { break }
    }
  }

  static func language(_ classes: String?) -> String? {
    guard let classes else { return nil }
    for name in classes.split(separator: " ") {
      for prefix in ["language-", "lang-"] where name.hasPrefix(prefix) {
        return String(name.dropFirst(prefix.count))
      }
    }
    return nil
  }

  static func apply(style: String, to effect: inout InlineEffect) {
    for declaration in style.split(separator: ";") {
      let parts = declaration.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
      switch property {
      case "font-weight":
        if value == "bold" || value == "bolder" || (Int(value) ?? 0) >= 600 {
          effect.marks.bold = true
        } else if value == "normal" || (Int(value) ?? 1000) < 600 {
          effect.marks.bold = false
          effect.clearsBold = true
        }
      case "font-style":
        if value == "italic" || value == "oblique" { effect.marks.italic = true }
      case "text-decoration", "text-decoration-line":
        if value.contains("line-through") { effect.marks.strikethrough = true }
      default: break
      }
    }
  }
}
