// Temporary: renders the UIKit composer to a PNG in the CI log, for
// inspecting its drawing without a simulator at hand.
#if canImport(UIKit)
  import ComposerCore
  import ComposerTesting
  import ComposerUIKit
  import Testing
  import UIKit

  @MainActor @Test func dumpUIKitRendering() throws {
    let markdown = """
      Composer renders **bold**, _italic_, ~~strikethrough~~, `inline code`, and \
      [links](https://wevm.dev), plus a token:

      > A quote, which can hold
      > more than one line.

      1. Ordered lists
      2. with nesting:
         - bullets inside
         - [x] and tasks
         - [ ] up to three levels

      ```swift
      let composer = ComposerController()
      composer.run(.toggleBold)
      ```

      Last line.
      """
    var document = MarkdownCodec().parse(markdown)
    if case .paragraph(var inlines) = document.blocks[0] {
      inlines.append(.node(AtomicNode(type: "mention", label: "Tom")))
      document.blocks[0] = .paragraph(inlines)
    }
    let driver = UIKitDriver(EditorState(document: document, selection: .caret(10)))
    let textView = driver.textView
    textView.overrideUserInterfaceStyle = .light
    textView.backgroundColor = .white
    textView.frame = CGRect(x: 0, y: 0, width: 390, height: 460)
    driver.perform(.marked(["か"], committing: nil))
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    textView.layoutIfNeeded()
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(bounds: textView.bounds, format: format).image { context in
      if !textView.drawHierarchy(in: textView.bounds, afterScreenUpdates: true) {
        textView.layer.render(in: context.cgContext)
      }
    }
    let png = try #require(image.pngData())
    let encoded = png.base64EncodedString()
    var lines: [String] = []
    var index = encoded.startIndex
    while index < encoded.endIndex {
      let end =
        encoded.index(index, offsetBy: 2000, limitedBy: encoded.endIndex) ?? encoded.endIndex
      lines.append("RENDERPNG:" + encoded[index..<end])
      index = end
    }
    print(lines.joined(separator: "\n"))
  }
#endif
