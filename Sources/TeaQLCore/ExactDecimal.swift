import Foundation

private let exactDecimalLocale = Locale(identifier: "en_US_POSIX")

/// Shared package-only parser for exact query operands and database storage.
/// Reject Foundation's silent prefix acceptance and rounding, not equivalent scales.
package func parseExactDecimal(_ text: String) -> Decimal? {
  guard let input = exactDecimalKey(text),
    let value = Decimal(string: text, locale: exactDecimalLocale),
    exactDecimalKey(String(describing: value)) == input
  else { return nil }
  return value
}

private func exactDecimalKey(_ text: String) -> String? {
  guard !text.isEmpty && text.utf8.count <= 256 else { return nil }
  let bytes = Array(text.utf8)
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
