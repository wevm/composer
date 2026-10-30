import ComposerCore
import Foundation
import Testing

@Suite struct JSONTests {
  let codec = JSONCodec(schema: testSchema)

  func json(_ string: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8))
  }

  @Test func encodesTheVersionedForm() throws {
    let document = Document(blocks: [paragraph(text("hi ", .bold), mention("tom", id: "user_123"))])
    let encoded = String(decoding: try codec.encode(document), as: UTF8.self)
    #expect(
      encoded
        == #"{"blocks":[{"children":[{"marks":["bold"],"text":"hi ","type":"text"},{"attrs":{"id":"user_123"},"label":"tom","text":"@tom","type":"mention"}],"type":"paragraph"}],"version":1}"#
    )
  }

  @Test(arguments: 0..<2)
  func randomDocumentsRoundTripExactly(batch: UInt64) throws {
    var generator = DocumentGenerator(seed: 0x15_0000 + batch)
    for _ in 0..<300 {
      // Not normalized: JSON keeps the document exactly as it is.
      let document = generator.document()
      #expect(try codec.decode(codec.encode(document)) == document)
    }
  }

  @Test func everyBlockKind() throws {
    let document = Document(blocks: [
      .codeBlock(language: "swift", text: "let a = 1"), .codeBlock(language: nil, text: ""),
      .quote([paragraph(text("q", Marks(italic: true, strikethrough: true, code: true, link: "u")))]
      ),
      .list(
        .ordered(start: 3),
        items: [ListItem(checked: true, blocks: []), ListItem(blocks: [paragraph(text("x"))])]),
    ])
    #expect(try codec.decode(codec.encode(document)) == document)
  }

  @Test func unknownNodesSurviveVerbatim() throws {
    let source = """
      {"version": 1, "blocks": [
        {"type": "paragraph", "children": [
          {"type": "text", "text": "vote: "},
          {"type": "poll", "text": "Lunch?", "attrs": {"id": "p1", "options": ["a", "b"], "n": 2, "f": 1.5, "x": null, "open": true}},
          {"type": "poll", "attrs": {"id": "p2"}}
        ]},
        {"type": "table", "rows": [[1, 2]]}
      ]}
      """
    let document = try codec.decode(Data(source.utf8))
    guard case .paragraph(let content) = document.blocks[0], case .unknown(let poll) = content[1],
      case .unknown(let bare) = content[2], case .unknown(let table) = document.blocks[1]
    else {
      Issue.record("Unexpected shape: \(document)")
      return
    }
    #expect(poll.type == "poll")
    #expect(poll.text == "Lunch?")
    #expect(bare.text == "[poll]")
    #expect(table.text == "[table]")
    // Encoding writes the same JSON back.
    let original = try json(source)
    let reencoded = try json(String(decoding: try codec.encode(document), as: UTF8.self))
    #expect(reencoded == original)
    // Markdown shows the fallback text; an unknown block is a paragraph.
    #expect(markdown.serialize(document) == "vote: Lunch?[poll]\n\n[table]")
  }

  @Test func aSchemaWithoutThePluginKeepsItsNodes() throws {
    let document = Document(blocks: [paragraph(text("hi "), mention("tom", id: "user_123"))])
    let data = try codec.encode(document)
    // A composer without mentions keeps them as unknown nodes…
    let bare = try JSONCodec().decode(data)
    guard case .paragraph(let content) = bare.blocks[0], case .unknown(let node) = content[1] else {
      Issue.record("Expected an unknown node: \(bare)")
      return
    }
    #expect(node.text == "@tom")
    // …and writes them back for one that has them.
    #expect(try codec.decode(JSONCodec().encode(bare)) == document)
    // `Codable` is the schema-free form.
    let decoded = try JSONDecoder().decode(Document.self, from: data)
    #expect(decoded == bare)
    #expect(
      try json(String(decoding: JSONEncoder().encode(decoded), as: UTF8.self))
        == json(String(decoding: data, as: UTF8.self)))
  }

  /// The codec's own JSON parser reads values as Foundation does.
  @Test func parsesJSONLikeFoundation() throws {
    let values = [
      #""plain""#, #""esc \" \\ \/ \b \f \n \r \t""#, #""\u00e9 \ud83d\ude00 é 😀""#,
      #""\u0000""#, "0", "-0", "12", "-9223372036854775808", "1.5", "-2.5e-3", "1E10",
      "123456789012345678901234567890", "true", "false", "null", "[]", "{}",
      #"[1, [2, {"a": [true, null]}], "x"]"#, #"{"z": 1, "a": {"b": "c"}}"#,
    ]
    for value in values {
      let source = #"{"version": 1, "blocks": [{"type": "x", "v": \#(value)}]}"#
      let document = try codec.decode(Data(source.utf8))
      guard case .unknown(let node) = document.blocks.first else {
        Issue.record("Expected an unknown block for \(value)")
        continue
      }
      #expect(node.json["v"] == (try json(value)), "\(value)")
    }
  }

  @Test func rejectsMalformedJSON() {
    let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
    for source in [
      #"{"version": 1, "blocks": [],}"#, #"{"version": 01, "blocks": []}"#,
      #"{"version": 1, "blocks": []} x"#, "{\"version\": 1, \"blocks\": [\"a\nb\"]}",
      #"{"version": 1, "blocks": [{"type": "x", "v": "\q"}]}"#, #"{"version": 1"#, "",
      #"{"version": 1, "blocks": [{"type": "x", "v": \#(deep)}]}"#,
    ] {
      #expect(throws: JSONCodec.DecodingError.self, "\(source.prefix(60))") {
        try codec.decode(Data(source.utf8))
      }
    }
  }

  @Test func versionsAreChecked() {
    #expect(throws: JSONCodec.DecodingError.missingVersion) {
      try codec.decode(Data(#"{"blocks": []}"#.utf8))
    }
    #expect(throws: JSONCodec.DecodingError.unsupportedVersion(2)) {
      try codec.decode(Data(#"{"version": 2, "blocks": []}"#.utf8))
    }
    #expect(throws: JSONCodec.DecodingError.notAnObject) {
      try codec.decode(Data("[]".utf8))
    }
  }

  @Test func malformedNodesThrow() {
    for source in [
      #"{"version": 1, "blocks": [{"children": []}]}"#,
      #"{"version": 1, "blocks": [{"type": "paragraph", "children": [{"type": "text"}]}]}"#,
      #"{"version": 1, "blocks": [{"type": "list", "attrs": {"kind": "ordered"}, "children": []}]}"#,
      #"{"version": 1, "blocks": [{"type": "paragraph", "children": [{"type": "mention", "text": "@a", "attrs": {"id": 1}}]}]}"#,
    ] {
      #expect(throws: JSONCodec.DecodingError.self, "\(source)") {
        try codec.decode(Data(source.utf8))
      }
    }
  }
}
