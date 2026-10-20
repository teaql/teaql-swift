import Foundation

private let exactDecimalLocale = Locale(identifier: "en_US_POSIX")

/// Parse the entire lexeme and reject Foundation Decimal's silent prefix
/// acceptance or precision rounding. Equivalent scale spellings are allowed.
func parseExactDecimal(_ text: String) -> Decimal? {
  guard let input = exactDecimalKey(text),
    let value = Decimal(string: text, locale: exactDecimalLocale),
    exactDecimalKey(String(describing: value)) == input
  else { return nil }
  return value
}

private func exactDecimalKey(_ text: String) -> String? {
  let bytes = Array(text.utf8)
  guard !bytes.isEmpty && bytes.count <= 256 else { return nil }
  var cursor = 0
  var negative = false
  if bytes[cursor] == 45 || bytes[cursor] == 43 {
    negative = bytes[cursor] == 45
    cursor += 1
  }
  var digits: [UInt8] = []
  while cursor < bytes.count && (48...57).contains(bytes[cursor]) {
    digits.append(bytes[cursor])
    cursor += 1
  }
  guard !digits.isEmpty else { return nil }
  var fractionCount = 0
  if cursor < bytes.count && bytes[cursor] == 46 {
    cursor += 1
    while cursor < bytes.count && (48...57).contains(bytes[cursor]) {
      digits.append(bytes[cursor])
      fractionCount += 1
      cursor += 1
    }
    guard fractionCount > 0 else { return nil }
  }
  var exponent = 0
  if cursor < bytes.count && (bytes[cursor] == 69 || bytes[cursor] == 101) {
    cursor += 1
    let exponentStart = cursor
    if cursor < bytes.count && (bytes[cursor] == 45 || bytes[cursor] == 43) { cursor += 1 }
    let exponentDigitsStart = cursor
    while cursor < bytes.count && (48...57).contains(bytes[cursor]) { cursor += 1 }
    guard cursor > exponentDigitsStart,
      let parsed = Int(String(decoding: bytes[exponentStart..<cursor], as: UTF8.self))
    else { return nil }
    exponent = parsed
  }
  guard cursor == bytes.count else { return nil }
  let (scale, overflow) = exponent.subtractingReportingOverflow(fractionCount)
  guard !overflow else { return nil }
  var significant = Array(digits.drop(while: { $0 == 48 }))
  guard !significant.isEmpty else { return "0" }
  var adjustedScale = scale
  while significant.last == 48 {
    significant.removeLast()
    let (next, overflow) = adjustedScale.addingReportingOverflow(1)
    guard !overflow else { return nil }
    adjustedScale = next
  }
  return "\(negative ? "-" : "")\(String(decoding: significant, as: UTF8.self))e\(adjustedScale)"
}

/// Keep quoted identifiers but remove SQL comments and single-quoted literal
/// contents before checking that a stored table DDL really has a CHECK.
func sqliteDDLCode(_ sql: String) -> String {
  let bytes = Array(sql.utf8)
  var code: [UInt8] = []
  var cursor = 0
  while cursor < bytes.count {
    let byte = bytes[cursor]
    if byte == 39 {  // SQL string literal, with doubled apostrophes.
      code.append(32)
      cursor += 1
      while cursor < bytes.count {
        if bytes[cursor] == 39 {
          cursor += 1
          if cursor < bytes.count && bytes[cursor] == 39 {
            cursor += 1
          } else {
            break
          }
        } else {
          cursor += 1
        }
      }
    } else if byte == 34 {  // Preserve a quoted identifier verbatim.
      code.append(byte)
      cursor += 1
      while cursor < bytes.count {
        code.append(bytes[cursor])
        if bytes[cursor] == 34 {
          cursor += 1
          if cursor < bytes.count && bytes[cursor] == 34 {
            code.append(bytes[cursor])
            cursor += 1
          } else {
            break
          }
        } else {
          cursor += 1
        }
      }
    } else if byte == 45 && cursor + 1 < bytes.count && bytes[cursor + 1] == 45 {
      code.append(32)
      cursor += 2
      while cursor < bytes.count && bytes[cursor] != 10 { cursor += 1 }
    } else if byte == 47 && cursor + 1 < bytes.count && bytes[cursor + 1] == 42 {
      code.append(32)
      cursor += 2
      while cursor + 1 < bytes.count && !(bytes[cursor] == 42 && bytes[cursor + 1] == 47) {
        cursor += 1
      }
      cursor = min(cursor + 2, bytes.count)
    } else {
      code.append(byte)
      cursor += 1
    }
  }
  return String(decoding: code, as: UTF8.self)
}
