import Foundation

final class SQLMaskedAlternative: Sendable {
  let metadata: SQLExecutionMetadata
  init(_ metadata: SQLExecutionMetadata) { self.metadata = metadata }
}

enum LogPrivacy {
  // Count Unicode scalars (not grapheme clusters); only ASCII digits are numeric IDs.
  static func maskAuditValue(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars)
    if scalars.count < 8 || scalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
      return String(repeating: "*", count: scalars.count)
    }
    let prefix = String(String.UnicodeScalarView(scalars.prefix(2)))
    let suffix = String(String.UnicodeScalarView(scalars.suffix(2)))
    return prefix + String(repeating: "*", count: scalars.count - 4) + suffix
  }

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
  private static func projectValue(_ value: TeaQLValue, policy: SQLParameterLogPolicy,
                                   allowPlaintext: Bool) -> TeaQLValue {
    if case .null = value { return value }
    switch policy {
    case .unknown, .credential: return .string("[REDACTED]")
    case .masked where !allowPlaintext:
      if case .array(let values) = value {
        return .array(values.map { projectValue($0, policy: .masked, allowPlaintext: false) })
      }
      if case .object = value { return .string("[REDACTED]") }
      return .string(maskAuditValue(strings(value).first ?? ""))
    default:
      switch value {
      case .object(let fields):
        return .object(fields.mapValues { $0 }.reduce(into: [:]) { output, field in
          output[field.key] = projectValue(field.value, policy: credential(field.key) ? .credential : .plain,
                                           allowPlaintext: allowPlaintext)
        })
      case .array(let values):
        return .array(values.map { projectValue($0, policy: .plain, allowPlaintext: allowPlaintext) })
      default: return value
      }
    }
  }

  private static func policies(_ source: SQLExecutionMetadata) -> [SQLParameterLogPolicy] {
    let count = source.parameters.count
    if source.parameterLogPolicies.count != count ||
      (!source.maskedParameters.isEmpty && source.maskedParameters.count != count) {
      return Array(repeating: .unknown, count: count)
    }
    if !source.generatedSQL && credential(source.parameterizedSQL) {
      return Array(repeating: .credential, count: count)
    }
    return source.parameterLogPolicies
  }

  // Call-local ancestor bindings, never attached to a query, shared context,
  // or output record. Normalize policies against their original SQL first.
  static func inheritIntent(_ current: SQLExecutionMetadata?,
                            inherited: SQLExecutionMetadata?) -> SQLExecutionMetadata? {
    let sources = [inherited, current].compactMap { $0 }
    guard !sources.isEmpty else { return nil }
    return SQLExecutionMetadata(operation: .select, parameterizedSQL: "",
      parameters: sources.flatMap(\.parameters), debugSQL: "", elapsedMicros: 0, resultSummary: "",
      parameterLogPolicies: sources.flatMap { policies($0) }, generatedSQL: true)
  }

  static func project(_ source: SQLExecutionMetadata, allowPlaintext: Bool = false,
                      intentSource: SQLExecutionMetadata? = nil) -> SQLExecutionMetadata {
    project(source, allowPlaintext: allowPlaintext, intentSource: intentSource, intentValues: [])
  }

  static func project(_ source: SQLExecutionMetadata, allowPlaintext: Bool = false,
                      intentSource: SQLExecutionMetadata? = nil,
                      intentValues: [TeaQLValue]) -> SQLExecutionMetadata {
    let allowPlaintext = allowPlaintext && !source.isSafeProjection
    if !allowPlaintext, intentValues.isEmpty, let alternative = source.maskedAlternative { return alternative.metadata }
    let count = source.parameters.count
    let invalidPolicies = !source.parameterLogPolicies.isEmpty && source.parameterLogPolicies.count != count
    let invalidFlags = !source.maskedParameters.isEmpty && source.maskedParameters.count != count
    let policies = policies(source)
    var values: [TeaQLValue] = []
    var flags: [Bool] = []
    var hidden: [TeaQLValue] = []
    for (i, value) in source.parameters.enumerated() {
      let wasMasked = !invalidFlags && !source.maskedParameters.isEmpty && source.maskedParameters[i]
      let projected = wasMasked ? value : projectValue(value, policy: policies[i], allowPlaintext: allowPlaintext)
      let masked = wasMasked || projected != value || policies[i] == .unknown || policies[i] == .credential
        || (policies[i] == .masked && !allowPlaintext)
      values.append(projected); flags.append(masked)
      if masked { hidden.append(value) }
    }
    if let intentSource {
      for (value, policy) in zip(intentSource.parameters, Self.policies(intentSource)) {
        if projectValue(value, policy: policy, allowPlaintext: allowPlaintext) != value ||
          policy == .credential || policy == .unknown || (policy == .masked && !allowPlaintext) {
          hidden.append(value)
        }
      }
    }
    let intentHidden = hidden + intentValues
    // A manually reconstructed debug record can lose private provenance. Its
    // own ID bindings cannot prove inherited free-form intent safe.
    let orphanedDebug = !allowPlaintext && source.maskedAlternative == nil &&
      source.debugSQL.hasPrefix("-- TeaQL DEBUG PLAINTEXT; EXPLICIT OPT-IN")
    func safe(_ text: String, values: [TeaQLValue]) -> String {
      orphanedDebug && !text.isEmpty ? "[REDACTED]" : scrub(text, values: values)
    }
    func safeIntent(_ text: String) -> String { safe(text, values: intentHidden) }
    func safeSummary(_ text: String) -> String {
      // Counts come from typed execution metadata, not SQL parameters. Keep
      // only a matching canonical prefix; scrub any free-form suffix normally.
      for (count, label) in [(source.affectedRows, " rows affected"),
                             (source.resultCount, " rows returned")] {
        guard let count else { continue }
        let prefix = "\(count)\(label)"
        guard text.hasPrefix(prefix) else { continue }
        let suffix = String(text.dropFirst(prefix.count))
        guard suffix.isEmpty || suffix.first == ";" || suffix.first == " " || suffix.first == "," else { continue }
        return prefix + safe(suffix, values: hidden)
      }
      return safe(text, values: hidden)
    }
    var omission = source.sqlOmissionReason
    if invalidPolicies { omission = "policy_count_mismatch" }
    if invalidFlags { omission = "mask_count_mismatch" }
    var rendered = ""
    if omission == nil {
      do {
        rendered = try SQLLogRenderer.render(source.parameterizedSQL, parameters: values,
          masked: flags, trustedStructure: source.generatedSQL)
      } catch { omission = "unsafe_or_unsupported_sql" }
    }
    let label = allowPlaintext ? "DEBUG PLAINTEXT; EXPLICIT OPT-IN" : "SAFE"
    let status = flags.contains(true) || omission != nil ? "; MASKED; NOT REPLAYABLE" : ""
    let debug = "-- TeaQL " + label + status + "\n"
      + (omission == nil ? rendered : "[SQL OMITTED; NOT REPLAYABLE]")
    var result = SQLExecutionMetadata(
      operation: source.operation, comment: source.comment.map(safeIntent), purpose: source.purpose.map(safeIntent),
      auditReason: source.auditReason.map(safeIntent),
      tracePath: source.tracePath.map { TraceNode(entity: safeIntent($0.entity), comment: safeIntent($0.comment),
        purpose: safeIntent($0.purpose), level: $0.level, kind: safeIntent($0.kind), name: safeIntent($0.name),
        entityID: $0.entityID) },
      mutationLineage: TraceChain.maskLineage(source.mutationLineage, values: intentHidden),
      parameterizedSQL: omission == nil ? source.parameterizedSQL : redactedSQL,
      parameters: values, debugSQL: debug, elapsedMicros: source.elapsedMicros,
      resultCount: source.resultCount, affectedRows: source.affectedRows, resultSummary: safeSummary(source.resultSummary),
      parameterLogPolicies: policies, maskedParameters: flags, generatedSQL: source.generatedSQL,
      sqlOmissionReason: omission, executionOutcome: source.executionOutcome)
    result.isSafeProjection = !allowPlaintext
    if allowPlaintext {
      result.maskedAlternative = source.maskedAlternative ?? SQLMaskedAlternative(
        project(source, allowPlaintext: false, intentSource: intentSource, intentValues: intentValues))
    }
    return result
  }
}
