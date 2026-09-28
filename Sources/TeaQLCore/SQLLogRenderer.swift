import Foundation

/// SQLite diagnostic renderer. Receives projected values; it never looks up original bindings.
public enum SQLLogRenderer {
  public enum RenderError: Error { case unsupportedSQL, parameterCount, invalidValue }

  public static func render(_ sql: String, parameters: [TeaQLValue], masked: [Bool] = [],
                            trustedStructure: Bool = true) throws -> String {
    guard masked.isEmpty || masked.count == parameters.count else { throw RenderError.parameterCount }
    let chars = Array(sql)
    var i = 0, binding = 0
    var result = ""
    while i < chars.count {
      let c = chars[i]
      let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
      if c == "'" || c == "\"" || c == "`" || c == "[" {
        guard trustedStructure else { throw RenderError.unsupportedSQL }
        let close: Character = c == "[" ? "]" : c
        result.append(c); i += 1
        var closed = false
        while i < chars.count {
          let current = chars[i]; result.append(current); i += 1
          if current == close {
            if close != "]", i < chars.count, chars[i] == close {
              result.append(chars[i]); i += 1
            } else { closed = true; break }
          }
        }
        guard closed else { throw RenderError.unsupportedSQL }
      } else if c == "-", next == "-" {
        guard trustedStructure else { throw RenderError.unsupportedSQL }
        while i < chars.count, chars[i] != "\n", chars[i] != "\r" { result.append(chars[i]); i += 1 }
      } else if c == "/", next == "*" {
        guard trustedStructure else { throw RenderError.unsupportedSQL }
        result += "/*"; i += 2
        var closed = false
        while i < chars.count {
          if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
            result += "*/"; i += 2; closed = true; break
          }
          result.append(chars[i]); i += 1
        }
        guard closed else { throw RenderError.unsupportedSQL }
      } else if c == "?" {
        guard next?.isNumber != true, binding < parameters.count else { throw RenderError.parameterCount }
        result += try literal(parameters[binding])
        if !masked.isEmpty, masked[binding] { result += " /* masked */" }
        binding += 1; i += 1
      } else {
        guard c != ":", c != "$", c != "@", c != "\0",
          trustedStructure || !c.isNumber else { throw RenderError.unsupportedSQL }
        result.append(c); i += 1
      }
    }
    guard binding == parameters.count else { throw RenderError.parameterCount }
    return result
  }

  public static func literal(_ value: TeaQLValue) throws -> String {
    switch value {
    case .null: return "NULL"
    case .bool(let v): return v ? "TRUE" : "FALSE"
    case .int(let v), .timestamp(let v): return String(v)
    case .uint(let v): return String(v)
    case .double(let v):
      guard v.isFinite else { throw RenderError.invalidValue }; return String(v)
    case .decimal(let v):
      guard !v.isNaN else { throw RenderError.invalidValue }; return NSDecimalNumber(decimal: v).stringValue
    case .string(let v), .calendarDate(let v), .localDateTime(let v): return try quote(v)
    case .date(let v): return try quote(ISO8601DateFormatter().string(from: v))
    case .data(let v): return "X'" + v.map { String(format: "%02x", $0) }.joined() + "'"
    case .array, .object:
      let data = try JSONEncoder().encode(value)
      guard let text = String(data: data, encoding: .utf8) else { throw RenderError.invalidValue }
      return try quote(text)
    }
  }

  private static func quote(_ text: String) throws -> String {
    guard !text.contains("\0") else { throw RenderError.invalidValue }
    return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }
}
