import Foundation

/// Read numeric lexemes only after the ordinary JSON decoder has validated the
/// document. This is not a JSON parser: strings/escapes are copied unchanged and
/// Foundation still parses the structure. Quoting numbers avoids Decimal/Double
/// rounding before trusted field metadata decides which values must be exact.
enum DynamicSearchDecimal {
  static func literalFilters(_ validatedJSON: String) throws -> [String: TeaQLValue] {
    let input = Array(validatedJSON.utf8)
    var quoted: [UInt8] = []
    quoted.reserveCapacity(input.count)
    var cursor = 0
    while cursor < input.count {
      let byte = input[cursor]
      if byte == 34 {
        let start = cursor
        cursor += 1
        while cursor < input.count {
          if input[cursor] == 92 { cursor += 2 }
          else if input[cursor] == 34 { cursor += 1; break }
          else { cursor += 1 }
        }
        quoted.append(contentsOf: input[start..<cursor])
      } else if byte == 45 || (48...57).contains(byte) {
        let start = cursor
        cursor += 1
        while cursor < input.count && ((48...57).contains(input[cursor]) || [43, 45, 46, 69, 101].contains(input[cursor])) {
          cursor += 1
        }
        quoted.append(34)
        quoted.append(contentsOf: input[start..<cursor])
        quoted.append(34)
      } else {
        quoted.append(byte)
        cursor += 1
      }
    }
    let decoded = try JSONDecoder().decode(TeaQLValue.self, from: Data(quoted))
    guard case .object(let root) = decoded, case .object(let filter) = root["filter"] else { return [:] }
    return filter
  }

  static func exactValue(_ value: TeaQLValue, literal: TeaQLValue) throws -> TeaQLValue {
    switch value {
    case .int, .uint, .double, .decimal:
      guard case .string(let text) = literal, let exact = parseExactDecimal(text) else {
        throw DynamicSearchError.invalid("Decimal is outside the exact native range")
      }
      return .decimal(exact)
    case .array(let values):
      guard case .array(let literals) = literal, literals.count == values.count else {
        throw DynamicSearchError.invalid("Invalid Decimal value list")
      }
      return .array(try zip(values, literals).map { try exactValue($0, literal: $1) })
    default: return value
    }
  }
}
