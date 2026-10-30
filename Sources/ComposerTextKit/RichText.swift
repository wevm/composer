#if canImport(UIKit) || canImport(AppKit)
  import ComposerCore
  import Foundation
  #if canImport(UIKit)
    import UIKit
  #else
    import AppKit
  #endif

  /// Rich text on the clipboard: RTF out, rendered from a document
  /// fragment; and RTF (or any attributed string) in, mapped to the schema
  /// the way HTML is, by turning it into the same tokens.
  @MainActor
  package enum RichText {
    /// RTF of a fragment, as the composer shows it.
    package static func rtf(_ fragment: Document, mapper: AttributeMapper) -> Data? {
      let string = mapper.attributedString(for: fragment)
      return try? string.data(
        from: NSRange(location: 0, length: string.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Maps RTF to a fragment and the images in it.
    package static func document(fromRTF data: Data) -> (Document, [PastedFile])? {
      guard
        let string = try? NSAttributedString(
          data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil)
      else { return nil }
      return document(from: string)
    }

    /// Maps an attributed string: bold, italic, and monospace font traits,
    /// strikethrough, and links become marks, and text lists become lists
    /// (nested as deep as the schema allows); other attributes are dropped.
    package static func document(from string: NSAttributedString) -> (Document, [PastedFile]) {
      var builder = HTMLBuilder()
      var files: [PastedFile] = []
      var openLists: [NSTextList] = []
      let text = string.string as NSString
      var location = 0
      while location < text.length {
        let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
        defer { location = NSMaxRange(paragraph) }
        let style = string.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
        let lists = (style as? NSParagraphStyle)?.textLists ?? []
        // Close the lists this paragraph isn't in, and open the new ones.
        var shared = 0
        while shared < min(openLists.count, lists.count), openLists[shared] === lists[shared] {
          shared += 1
        }
        while openLists.count > shared {
          builder.handle(.end(Self.tag(of: openLists.removeLast())))
        }
        for list in lists.dropFirst(shared) {
          builder.handle(.start(Self.tag(of: list), [:]))
          openLists.append(list)
        }
        builder.handle(.start(lists.isEmpty ? "p" : "li", [:]))
        var content = paragraph
        // The paragraph's newline, and a list marker the importer wrote
        // into the text ("\t•\t").
        if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A {
          content.length -= 1
        }
        if !lists.isEmpty {
          let line = text.substring(with: content)
          if line.hasPrefix("\t"), let tab = line.dropFirst().firstIndex(of: "\t") {
            let marker = line.utf16.distance(from: line.startIndex, to: tab) + 1
            content = NSRange(location: content.location + marker, length: content.length - marker)
          }
        }
        string.enumerateAttributes(in: content) { attributes, range, _ in
          if let attachment = attributes[.attachment] as? NSTextAttachment {
            if let file = Self.file(of: attachment) { files.append(file) }
            return
          }
          let tags = Self.tags(for: attributes)
          for (name, attributes) in tags { builder.handle(.start(name, attributes)) }
          let piece = text.substring(with: range).replacingOccurrences(of: "\u{2028}", with: "\n")
          for (index, line) in piece.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
          {
            if index > 0 { builder.handle(.start("br", [:])) }
            if !line.isEmpty { builder.handle(.text(String(line))) }
          }
          for (name, _) in tags.reversed() { builder.handle(.end(name)) }
        }
        if lists.isEmpty { builder.handle(.end("p")) }
      }
      while let list = openLists.popLast() { builder.handle(.end(Self.tag(of: list))) }
      return (builder.finish().document, files)
    }

    private static func tag(of list: NSTextList) -> String {
      let format = list.markerFormat.rawValue
      return format.contains("decimal") || format.contains("alpha") || format.contains("roman")
        ? "ol" : "ul"
    }

    private static func tags(
      for attributes: [NSAttributedString.Key: Any]
    ) -> [(
      String, [String: String]
    )] {
      var tags: [(String, [String: String])] = []
      if let font = attributes[.font] as? PlatformFont {
        let traits = font.fontDescriptor.symbolicTraits
        #if canImport(UIKit)
          if traits.contains(.traitBold) { tags.append(("b", [:])) }
          if traits.contains(.traitItalic) { tags.append(("i", [:])) }
          if traits.contains(.traitMonoSpace) { tags.append(("code", [:])) }
        #else
          if traits.contains(.bold) { tags.append(("b", [:])) }
          if traits.contains(.italic) { tags.append(("i", [:])) }
          if traits.contains(.monoSpace) { tags.append(("code", [:])) }
        #endif
      }
      if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 {
        tags.append(("s", [:]))
      }
      if let link = attributes[.link] {
        let href = (link as? URL)?.absoluteString ?? (link as? String)
        if let href { tags.append(("a", ["href": href])) }
      }
      return tags
    }

    private static func file(of attachment: NSTextAttachment) -> PastedFile? {
      let wrapper = attachment.fileWrapper
      if let data = wrapper?.regularFileContents ?? attachment.contents {
        let name = wrapper?.preferredFilename
        return PastedFile(
          data: data, contentType: attachment.fileType ?? "public.data", name: name)
      }
      return nil
    }
  }
#endif
