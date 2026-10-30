import ComposerCore
import Testing

/// One unit of a document's linear form, with what it carries.
struct Unit: Hashable {
  var code: UInt16
  var marks: Marks?
  var node: AtomicNode?
}

/// The document's linear form (see `Position`), unit by unit.
func units(_ document: Document) -> [Unit] {
  var result: [Unit] = []
  for (index, block) in document.textBlocks.enumerated() {
    if index > 0 { result.append(Unit(code: 10)) }
    switch block.content {
    case .paragraph(let inlines):
      for inline in inlines {
        switch inline {
        case .text(let text, let marks): result += text.utf16.map { Unit(code: $0, marks: marks) }
        case .node(let node): result.append(Unit(code: 0xFFFC, node: node))
        case .unknown: result.append(Unit(code: 0xFFFD))
        }
      }
    case .code(_, let text):
      result += text.utf16.map { Unit(code: $0) }
    }
  }
  return result
}

/// Whether the changeset accounts for every difference between two
/// documents: applying its edits to the old units, with the replacements
/// unknown, leaves only units that equal the new ones.
func changesetCovers(_ changeset: Changeset, from old: Document, to new: Document) -> Bool {
  var applied = units(old).map(Optional.some)
  for edit in changeset.edits {
    let range = edit.range.lowerBound.offset..<edit.range.upperBound.offset
    guard range.lowerBound >= 0, range.upperBound <= applied.count else { return false }
    applied.replaceSubrange(range, with: repeatElement(nil, count: edit.replacementLength))
  }
  let expected = units(new)
  guard applied.count == expected.count else { return false }
  return zip(applied, expected).allSatisfy { $0 == nil || $0 == $1 }
}

/// Paragraphs are kept merged: no empty runs and no two adjacent runs with
/// the same marks.
func isMerged(_ document: Document) -> Bool {
  document.textBlocks.allSatisfy { block in
    guard case .paragraph(let inlines) = block.content else { return true }
    var previous: Marks?
    for inline in inlines {
      guard case .text(let text, let marks) = inline else {
        previous = nil
        continue
      }
      if text.isEmpty || marks == previous { return false }
      previous = marks
    }
    return true
  }
}

@Suite struct EditorStateTests {
  static let counter = PluginKey("counter", default: 0)

  @Test func copiesAreIndependent() {
    var a = EditorState(document: Document(blocks: [paragraph(text("hi"))]))
    let b = a
    a.insert("!")
    #expect(units(b.document).count == 2)
    #expect(units(a.document).count == 3)
    #expect(a != b)
    var c = b
    c[Self.counter] = 1
    #expect(b[Self.counter] == 0)
    #expect(c != b)
  }

  @Test func equalityIsByValue() {
    let document = Document(blocks: [paragraph(text("hi"))])
    var a = EditorState(document: document)
    var b = EditorState(document: document)
    #expect(a == b)
    a[Self.counter] = 2
    #expect(a != b)
    b[Self.counter] = 2
    #expect(a == b)
    // A key set back to its default is the same as one never set.
    a[Self.counter] = 0
    #expect(a == EditorState(document: document))
    a.selection = .caret(0)
    #expect(a != EditorState(document: document))
    a.markedText = MarkedText(range: Position(0)..<Position(1))
    #expect(a.markedText != nil)
  }

  @Test func pluginKeysAreTypedByName() {
    let label = PluginKey("label", default: "none")
    var state = EditorState()
    state[label] = "set"
    #expect(state[label] == "set")
    #expect(state[Self.counter] == 0)
  }

  @Test func caretStartsAtTheEnd() {
    let state = EditorState(document: Document(blocks: [paragraph(text("a😀"))]))
    #expect(state.selection == .caret(3))
  }
}

@Suite struct EditingTests {
  func state(_ blocks: Block..., caret: Int? = nil) -> EditorState {
    let document = Document(blocks: blocks)
    return EditorState(document: document, selection: caret.map(Selection.caret))
  }

  @Test func typingContinuesTheMarksBeforeTheCaretButNotALink() {
    var state = self.state(paragraph(text("a", .bold), text("b", .link("u"))))
    state.insert("x", at: .caret(1))
    #expect(state.document.blocks == [paragraph(text("ax", .bold), text("b", .link("u")))])
    state.insert("y", at: .caret(3))
    #expect(
      state.document.blocks == [paragraph(text("ax", .bold), text("b", .link("u")), text("y"))])
    #expect(state.selection == .caret(4))
  }

  @Test func atomicNodesAreOneUnit() {
    var state = self.state(paragraph(text("hi "), mention("tom", id: "1"), text("!")))
    #expect(state.document.length == 5)
    state.delete(Position(3)..<Position(4))
    #expect(state.document.blocks == [paragraph(text("hi !"))])
  }

  @Test func deletingAcrossBlocksMergesThem() {
    var state = self.state(
      paragraph(text("one")),
      bullets([paragraph(text("two"))], [paragraph(text("three"))]),
      .quote([paragraph(text("four"))]))
    // "on|e\ntwo\nth|ree": the first block takes the rest of the third.
    state.delete(Position(2)..<Position(10))
    #expect(
      state.document.blocks == [
        paragraph(text("onree")), .quote([paragraph(text("four"))]),
      ])
  }

  @Test func deletingTheSeparatorJoinsBlocks() {
    var state = self.state(paragraph(text("a")), .codeBlock(language: "js", text: "b"))
    state.delete(Position(1)..<Position(2))
    #expect(state.document.blocks == [paragraph(text("ab"))])
  }

  @Test func aCodeBlockTakesAParagraphTailAsText() {
    var state = self.state(
      .codeBlock(language: nil, text: "x"), paragraph(text("y"), mention("tom", id: "1")))
    state.delete(Position(1)..<Position(2))
    #expect(state.document.blocks == [.codeBlock(language: nil, text: "xytom")])
  }

  @Test func splitBlock() {
    var state = self.state(paragraph(text("ab", .bold)), .codeBlock(language: nil, text: "cd"))
    state.splitBlock(at: 1)
    #expect(
      state.document.blocks == [
        paragraph(text("a", .bold)), paragraph(text("b", .bold)),
        .codeBlock(language: nil, text: "cd"),
      ])
    state.splitBlock(at: 5)
    #expect(state.document.blocks.last == .codeBlock(language: nil, text: "c\nd"))
  }

  @Test func toggleMarkAddsUnlessAllHaveIt() {
    var state = self.state(paragraph(text("ab", .bold), text("cd")))
    state.toggleMark(.bold, in: Position(1)..<Position(3))
    #expect(state.document.blocks == [paragraph(text("abc", .bold), text("d"))])
    state.toggleMark(.bold, in: Position(0)..<Position(3))
    #expect(state.document.blocks == [paragraph(text("abcd"))])
  }

  @Test func marksSkipCodeBlocks() {
    var state = self.state(paragraph(text("a")), .codeBlock(language: nil, text: "b"))
    state.setMark(.italic, true, in: Position(0)..<Position(3))
    #expect(
      state.document.blocks == [
        paragraph(text("a", .italic)), .codeBlock(language: nil, text: "b"),
      ])
  }

  /// Random edits on random documents: every changeset covers exactly what
  /// changed, selections stay in bounds, and paragraphs stay merged.
  @Test @MainActor func randomEditsKeepTheirInvariants() {
    var generator = DocumentGenerator(seed: 0xED17)
    for _ in 0..<300 {
      let controller = ComposerController(
        EditorState(document: generator.document().normalized()),
        plugins: [UppercaseQ()])
      for _ in 0..<8 {
        let before = controller.state
        let length = before.document.length
        let a = generator.int(0...length)
        let b = generator.int(0...length)
        let range = Position(min(a, b))..<Position(max(a, b))
        let operation = generator.int(0...6)
        let inserted = generator.pick(["x", "q", "", "😀", "a\nb"])
        let changeset = controller.update { state in
          switch operation {
          case 0: state.insert(inserted, at: Selection(range))
          case 1: state.insert(AtomicNode(type: .mention, label: "m"), at: Selection(range))
          case 2: state.delete(range)
          case 3: state.splitBlock(at: range.lowerBound)
          case 4: state.toggleMark(generator.pick(MarkKind.allCases), in: range)
          case 5: state.setLink(generator.chance(0.5) ? "u" : nil, in: range)
          default: state.replace(range, with: [text(inserted, .bold), mention("x", id: "1")])
          }
        }
        let after = controller.state
        #expect(
          changesetCovers(changeset, from: before.document, to: after.document),
          "op \(operation) \(range) \(changeset)\n\(before.document)\n\(after.document)")
        #expect(changeset.selectionBefore == before.selection)
        #expect(changeset.selectionAfter == after.selection)
        #expect(after.selection.range.upperBound.offset <= after.document.length)
        #expect(isMerged(after.document))
        // The transform reached its fixed point (it rewrites paragraphs only).
        #expect(!plainText(after.document.paragraphsOnly).contains { $0.contains("q") })
        #expect(!changeset.reachedTransformLimit)
      }
    }
  }

  @Test func insertedTextAppearsWhereItWasInserted() {
    var generator = DocumentGenerator(seed: 0x1235)
    for _ in 0..<300 {
      var state = EditorState(document: generator.document().normalized())
      let length = state.document.length
      let old = units(state.document).map(\.code)
      // Editing rounds a position inside a surrogate pair down.
      func aligned(_ offset: Int) -> Int {
        offset < old.count && UTF16.isTrailSurrogate(old[offset]) ? offset - 1 : offset
      }
      let a = aligned(generator.int(0...length))
      let b = aligned(generator.int(0...length))
      let (lower, upper) = (min(a, b), max(a, b))
      guard case .paragraph? = state.document.textBlock(containing: Position(lower))?.content
      else { continue }
      state.insert("<>", at: Selection(Position(lower)..<Position(upper)))
      let new = units(state.document).map(\.code)
      #expect(new == Array(old[..<lower]) + Array("<>".utf16) + Array(old[upper...]))
      #expect(state.selection == .caret(lower + 2))
    }
  }
}

extension Document {
  var paragraphsOnly: Document {
    Document(
      blocks: textBlocks.compactMap {
        if case .paragraph(let inlines) = $0.content { .paragraph(inlines) } else { nil }
      })
  }
}

/// A transform that uppercases `q`, so tests can see that transforms ran.
struct UppercaseQ: ComposerPlugin {
  func register(in registry: inout PluginRegistry) {
    registry.addTransform(
      replacing("q", with: "Q", name: "uppercaseQ"))
  }
}

/// A transform that replaces the first `pattern` in a paragraph with
/// `replacement`. Text runs only; nodes count as one unit.
func replacing(_ pattern: String, with replacement: String, name: String) -> NodeTransform {
  NodeTransform(name) { state, range in
    guard let block = state.document.textBlock(containing: range.lowerBound),
      case .paragraph(let inlines) = block.content
    else { return }
    var codes: [UInt16] = []
    for inline in inlines {
      if case .text(let text, _) = inline { codes += text.utf16 } else { codes.append(0xFFFC) }
    }
    let target = Array(pattern.utf16)
    guard codes.count >= target.count else { return }
    for start in 0...(codes.count - target.count)
    where Array(codes[start..<start + target.count]) == target {
      let lower = block.range.lowerBound.offset + start
      state.replace(Position(lower)..<Position(lower + target.count), with: [.text(replacement)])
      return
    }
  }
}

@Suite struct TextBlockContainerTests {
  @Test func blocksComeWithTheirContainers() {
    let document = Document(blocks: [
      .quote([paragraph(text("a"))]),
      .list(
        .bullet,
        items: [
          ListItem(blocks: [paragraph(text("b")), .quote([paragraph(text("c"))])]),
          ListItem(checked: true, blocks: [paragraph(text("d"))]),
        ]),
      paragraph(text("e")),
    ])
    var visited: [(String, [TextBlock.Container])] = []
    // "a" 0..<1, "b" 2..<3, "c" 4..<5, "d" 6..<7, "e" 8..<9: the range touches b, c, and d.
    document.forEachTextBlock(in: Position(3)..<Position(6)) { block, containers in
      guard case .paragraph(let inlines) = block.content, case .text(let string, _) = inlines[0]
      else { return }
      visited.append((string, containers))
    }
    #expect(visited.map(\.0) == ["b", "c", "d"])
    #expect(
      visited.map(\.1) == [
        [.listItem(kind: .bullet, index: 0, checked: nil, isFirstBlock: true)],
        [.listItem(kind: .bullet, index: 0, checked: nil, isFirstBlock: false), .quote],
        [.listItem(kind: .bullet, index: 1, checked: true, isFirstBlock: true)],
      ])
    var all: [[TextBlock.Container]] = []
    document.forEachTextBlock(in: Position(0)..<Position(document.length)) { all.append($1) }
    #expect(all.count == 5)
    #expect(all.first == [.quote] && all.last == [])
  }
}
