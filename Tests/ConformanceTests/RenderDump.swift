// Temporary: renders the composer to a PNG in the CI log, for inspecting
// the layout fragments without a Mac.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import ComposerAppKit
  import ComposerCore
  import ComposerTesting
  import Testing

  @MainActor @Test func dumpRendering() throws {
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
    let driver = AppKitDriver(EditorState(document: document, selection: .caret(10)))
    let textView = driver.textView
    textView.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
    driver.window.setContentSize(NSSize(width: 460, height: 420))
    driver.window.appearance = NSAppearance(named: .aqua)
    driver.perform(.marked(["か"], committing: nil))
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
    textView.layoutSubtreeIfNeeded()
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(textView.bounds.width * 2),
        pixelsHigh: Int(textView.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0))
    rep.size = textView.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    textView.bounds.fill()
    NSGraphicsContext.restoreGraphicsState()
    textView.cacheDisplay(in: textView.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    let encoded = png.base64EncodedString()
    var index = encoded.startIndex
    while index < encoded.endIndex {
      let end =
        encoded.index(index, offsetBy: 2000, limitedBy: encoded.endIndex) ?? encoded.endIndex
      print("RENDERPNG:" + encoded[index..<end])
      index = end
    }
  }
#endif
