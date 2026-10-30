import Foundation
import Testing

@testable import ComposerCore

@Suite struct StorageMapTests {
  // "ab", a 4-character token, "c" | "d", a 3-character token.
  let map = StorageMap(
    document: Document(blocks: [
      paragraph(text("ab"), mention("tom", id: "1"), text("c")),
      paragraph(text("d"), mention("al", id: "2")),
    ]),
    tokenLength: { inline in
      if case .node(let node) = inline { return node.label.utf16.count + 1 }
      return 1
    })

  @Test func positionsShiftByEachTokensExtraCharacters() {
    #expect([0, 2, 3, 4, 5, 6, 7].map(map.storage) == [0, 2, 6, 7, 8, 9, 12])
    #expect(map.storageLength == 12)
    #expect(map.documentLength == 7)
  }

  @Test func storageOffsetsInsideATokenRoundToItsEdges() {
    #expect([0, 2, 6, 7, 8, 9, 12].map { map.document($0) } == [0, 2, 3, 4, 5, 6, 7])
    #expect(map.document(3) == 2, "nearer the start")
    #expect(map.document(5) == 3, "nearer the end")
    #expect(map.document(3, rounding: .up) == 3)
    #expect(map.document(5, rounding: .down) == 2)
    #expect(map.document(10) == 6)
    #expect(map.token(containing: 3) == 2)
    #expect(map.token(containing: 2) == nil, "a token's edge isn't inside it")
    #expect(map.token(containing: 6) == nil)
  }

  @Test func rangesGrowToWholeTokens() {
    #expect(map.document(NSRange(location: 3, length: 1)) == Position(2)..<Position(3))
    #expect(map.document(NSRange(location: 1, length: 3)) == Position(1)..<Position(3))
    #expect(map.storage(Position(2)..<Position(3)) == NSRange(location: 2, length: 4))
    // Every document position survives the round trip.
    for position in 0...7 { #expect(map.document(map.storage(position)) == position) }
  }

  @Test func withoutTokensItIsTheIdentity() {
    let plain = StorageMap(document: Document(blocks: [paragraph(text("abc"))])) { _ in 1 }
    #expect(plain.isIdentity)
    #expect((0...3).map(plain.storage) == [0, 1, 2, 3])
  }

  /// Updating a map through an update's combined edit gives the map of the
  /// document after it, for random documents and edits.
  @Test(arguments: 0..<4) @MainActor func updatedMapsMatchFreshOnes(batch: UInt64) {
    let length: (Inline) -> Int = { inline in
      if case .node(let node) = inline { return node.label.utf16.count + 1 }
      return 3
    }
    var generator = DocumentGenerator(seed: 0x5EED + batch)
    for _ in 0..<150 {
      let controller = ComposerController(EditorState(document: generator.document()))
      var map = StorageMap(document: controller.document, tokenLength: length)
      for _ in 0..<6 {
        let total = controller.document.length
        let a = generator.int(0...total)
        let b = generator.int(a...min(total, a + 6))
        let changeset = controller.update { state in
          switch generator.int(0...3) {
          case 0: state.insert(generator.string(), at: .caret(a), marks: Marks())
          case 1: state.delete(Position(a)..<Position(b))
          case 2: state.insert([mention("x\(a)", id: "n")], over: Position(a)..<Position(b))
          default:
            state.insert(
              Document(blocks: [paragraph(text("p")), paragraph(mention("q", id: "1"))]),
              over: Position(a)..<Position(b))
          }
        }
        if let edit = changeset.combinedEdit {
          map = map.updated(edit, in: controller.document, tokenLength: length)
        }
        let fresh = StorageMap(document: controller.document, tokenLength: length)
        #expect(map == fresh, "\(String(reflecting: controller.document))")
        if map != fresh { return }
      }
    }
  }
}
