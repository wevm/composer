import Foundation

/// A JSON parser into `JSONValue`. `JSONDecoder` can't peek at a value's
/// type, so decoding `JSONValue` through it costs a thrown error per failed
/// guess; this reads each value once.
struct JSONParser {
  /// Deeper input is rejected rather than risking the stack: Apple platforms
  /// give secondary threads 512 KB. Documents nest about 40 levels at most.
  static let maxDepth = 100

  private let bytes: [UInt8]
  private var index = 0

  init(_ data: Data) {
    bytes = [UInt8](data)
  }

  static func parse(_ data: Data) throws -> JSONValue {
    var parser = JSONParser(data)
    parser.skipWhitespace()
    let value = try parser.value(depth: 0)
    parser.skipWhitespace()
    guard parser.index == parser.bytes.count else { throw parser.error("Trailing characters") }
    return value
  }

  private func error(_ message: String) -> JSONCodec.DecodingError {
    .invalid("\(message) at byte \(index)")
  }

  private mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  private mutating func value(depth: Int) throws -> JSONValue {
    guard depth < Self.maxDepth else { throw error("Nested too deeply") }
    guard index < bytes.count else { throw error("Unexpected end") }
    switch bytes[index] {
    case UInt8(ascii: "{"):
      index += 1
      var object: [String: JSONValue] = [:]
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(object)
      }
      while true {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
          throw error("Expected a key")
        }
        let key = try string()
        skipWhitespace()
        try expect(UInt8(ascii: ":"))
        skipWhitespace()
        object[key] = try value(depth: depth + 1)
        skipWhitespace()
        if try separator(closing: UInt8(ascii: "}")) { return .object(object) }
      }
    case UInt8(ascii: "["):
      index += 1
      var array: [JSONValue] = []
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(array)
      }
      while true {
        skipWhitespace()
        array.append(try value(depth: depth + 1))
        skipWhitespace()
        if try separator(closing: UInt8(ascii: "]")) { return .array(array) }
      }
    case UInt8(ascii: "\""):
      return .string(try string())
    case UInt8(ascii: "t"):
      try literal("true")
      return .bool(true)
    case UInt8(ascii: "f"):
      try literal("false")
      return .bool(false)
    case UInt8(ascii: "n"):
      try literal("null")
      return .null
    default:
      return try number()
    }
  }

  /// Reads `,` (returns `false`) or `closing` (returns `true`).
  private mutating func separator(closing: UInt8) throws -> Bool {
    guard index < bytes.count else { throw error("Unexpected end") }
    if bytes[index] == UInt8(ascii: ",") {
      index += 1
      return false
    }
    try expect(closing)
    return true
  }

  private mutating func expect(_ byte: UInt8) throws {
    guard index < bytes.count, bytes[index] == byte else {
      throw error("Expected \"\(Unicode.Scalar(byte))\"")
    }
    index += 1
  }

  private mutating func literal(_ word: String) throws {
    for byte in word.utf8 {
      guard index < bytes.count, bytes[index] == byte else { throw error("Unexpected character") }
      index += 1
    }
  }

  private mutating func number() throws -> JSONValue {
    let start = index
    var isInteger = true
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
    func digits() -> Int {
      let from = index
      while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
        index += 1
      }
      return index - from
    }
    let integerStart = index
    let integerDigits = digits()
    guard integerDigits > 0 else { throw error("Unexpected character") }
    if integerDigits > 1, bytes[integerStart] == UInt8(ascii: "0") {
      throw error("Leading zero")
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      isInteger = false
      index += 1
      guard digits() > 0 else { throw error("Expected a digit") }
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      isInteger = false
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
      {
        index += 1
      }
      guard digits() > 0 else { throw error("Expected a digit") }
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    if isInteger, let value = Int64(text) { return .int(value) }
    guard let value = Double(text) else { throw error("Invalid number") }
    // Like `JSONDecoder`: an integral value such as `1E10` or `1.0` is an
    // integer when it fits.
    if let integer = Int64(exactly: value) { return .int(integer) }
    return .double(value)
  }

  private mutating func string() throws -> String {
    index += 1  // The opening quote.
    var result = [UInt8]()
    while true {
      guard index < bytes.count else { throw error("Unterminated string") }
      let byte = bytes[index]
      index += 1
      switch byte {
      case UInt8(ascii: "\""):
        guard let string = String(validating: result, as: UTF8.self) else {
          throw error("Invalid UTF-8")
        }
        return string
      case UInt8(ascii: "\\"):
        guard index < bytes.count else { throw error("Unterminated string") }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): result.append(escape)
        case UInt8(ascii: "b"): result.append(0x08)
        case UInt8(ascii: "f"): result.append(0x0C)
        case UInt8(ascii: "n"): result.append(0x0A)
        case UInt8(ascii: "r"): result.append(0x0D)
        case UInt8(ascii: "t"): result.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if UTF16.isLeadSurrogate(UInt16(scalar)), index + 1 < bytes.count,
            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
          {
            let saved = index
            index += 2
            let low = try hex4()
            if UTF16.isTrailSurrogate(UInt16(low)) {
              scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else {
              index = saved
            }
          }
          // A lone surrogate becomes U+FFFD.
          result += Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8)
        default:
          throw error("Invalid escape")
        }
      case 0..<0x20:
        throw error("Control character in string")
      default:
        result.append(byte)
      }
    }
  }

  private mutating func hex4() throws -> UInt32 {
    guard index + 4 <= bytes.count else { throw error("Unexpected end") }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      let digit: UInt8
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
      default: throw error("Invalid escape")
      }
      value = value * 16 + UInt32(digit)
      index += 1
    }
    return value
  }
}
