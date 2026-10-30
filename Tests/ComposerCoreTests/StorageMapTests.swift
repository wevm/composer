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
}
