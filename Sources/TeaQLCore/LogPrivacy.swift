import Foundation

enum LogPrivacy {
  static let environmentName = "TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS"
  static let acknowledgement = "I_UNDERSTAND_SENSITIVE_DATA_MAY_BE_WRITTEN_TO_DISK"
  static let redactedSQL = "[REDACTED SQL; NOT REPLAYABLE]"
  private final class WarningState: @unchecked Sendable {
    let lock = NSLock()
    var emitted = false
    func emit() {
      lock.lock()
      defer { lock.unlock() }
      guard !emitted else { return }
      emitted = true
      FileHandle.standardError.write(Data("[TeaQL WARNING] Sensitive plaintext logging enabled; business data may be written to disk. Credentials remain redacted.\n".utf8))
    }
  }
  private static let warning = WarningState()
  static func accepts(_ value: String?) -> Bool { value == acknowledgement }
  static func plaintextEnabled() -> Bool {
    guard accepts(ProcessInfo.processInfo.environment[environmentName]) else { return false }
    warning.emit()
    return true
  }
  static func credential(_ name: String) -> Bool {
    let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
    return ["password", "passwd", "passphrase", "privatekey", "secret", "accesstoken",
      "refreshtoken", "idtoken", "apikey", "authorization", "credential", "sessiontoken",
      "magiclinktoken"].contains { key.contains($0) }
  }
  static func hasCredentials(_ value: TeaQLValue) -> Bool {
    switch value {
    case .object(let fields): return fields.contains { credential($0.key) || hasCredentials($0.value) }
    case .array(let values): return values.contains { hasCredentials($0) }
    default: return false
    }
  }
  static func strings(_ value: TeaQLValue) -> [String] {
    switch value {
    case .null: return []
    case .string(let text), .calendarDate(let text), .localDateTime(let text): return [text]
    case .object(let fields): return fields.values.flatMap(strings)
    case .array(let values): return values.flatMap(strings)
    case .int(let value), .timestamp(let value): return [String(value)]
    case .uint(let value): return [String(value)]
    case .double(let value): return [String(value)]
    case .decimal(let value): return [NSDecimalNumber(decimal: value).stringValue]
    case .bool(let value): return [String(value)]
    case .date(let value): return [String(describing: value)]
    case .data(let value): return [value.base64EncodedString()]
    }
  }
  static func scrub(_ text: String, values: [TeaQLValue]) -> String {
    var result = text
    for value in Set(values.flatMap(strings)).filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
      result = result.replacingOccurrences(of: value, with: "[REDACTED]")
    }
    return result
  }
  static func project(_ source: SQLExecutionMetadata, allowPlaintext: Bool = false) -> SQLExecutionMetadata {
    let reveal = allowPlaintext && !credential(source.parameterizedSQL) && !credential(source.debugSQL)
      && !source.parameters.contains(where: hasCredentials)
    if reveal { return source }
    func safe(_ text: String) -> String { scrub(text, values: source.parameters) }
    var sql = source.parameterizedSQL
    if sql.contains(where: { "'\"`$".contains($0) || $0.isNumber }) || sql.contains("--") || sql.contains("/*") {
      sql = redactedSQL
    }
    return SQLExecutionMetadata(
      operation: source.operation, comment: source.comment.map(safe), purpose: source.purpose.map(safe),
      auditReason: source.auditReason.map(safe),
      tracePath: source.tracePath.map { TraceNode(entity: safe($0.entity), comment: safe($0.comment),
        purpose: safe($0.purpose), level: $0.level, kind: $0.kind, name: safe($0.name)) },
      parameterizedSQL: sql, parameters: source.parameters.map { _ in .null }, debugSQL: redactedSQL,
      elapsedMicros: source.elapsedMicros, resultCount: source.resultCount,
      affectedRows: source.affectedRows, resultSummary: safe(source.resultSummary))
  }
}
