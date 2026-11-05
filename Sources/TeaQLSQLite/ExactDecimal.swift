import Foundation

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
