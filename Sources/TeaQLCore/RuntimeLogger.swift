import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum RuntimeLoggingError: Error, Sendable { case initializationFailed }
public enum RuntimeLogLevel: String, Sendable { case info = "INFO", warn = "WARN", error = "ERROR" }
public struct RuntimeLoggingOptions: Sendable {
  public var logName: String?
  public var logFormat: String?
  public var modelNames: [String]
  public var environment: [String: String]?
  public var workingDirectory: URL?
  public init(logName: String? = nil, logFormat: String? = nil, modelNames: [String] = [], environment: [String: String]? = nil, workingDirectory: URL? = nil) {
    self.logName = logName; self.logFormat = logFormat; self.modelNames = modelNames; self.environment = environment; self.workingDirectory = workingDirectory
  }
}

private func loggingOpen(_ path: String, _ flags: Int32) -> Int32 {
  #if canImport(Darwin)
  return Darwin.open(path, flags, mode_t(0o600))
  #else
  return Glibc.open(path, flags, mode_t(0o600))
  #endif
}
private func loggingClose(_ descriptor: Int32) -> Int32 {
  #if canImport(Darwin)
  return Darwin.close(descriptor)
  #else
  return Glibc.close(descriptor)
  #endif
}
private func loggingWrite(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
  return Darwin.write(descriptor, pointer, count)
  #else
  return Glibc.write(descriptor, pointer, count)
  #endif
}

/// Application-owned structured output. Immutable configuration and the gate
/// protect the only mutable resource: the destination during an append.
public final class RuntimeLogger: @unchecked Sendable {
  public let logName: String
  public let logFormat: String
  public let path: URL?
  public let maxSize: Int64
  public let maxFiles: Int
  private let stream: String?
  private let gate = NSLock()
  private final class Defaults: @unchecked Sendable {
    let gate = NSLock()
    var loggers: [String: RuntimeLogger] = [:]
  }
  private static let defaults = Defaults()

  private static func environment() -> [String: String] {
    var values: [String: String] = [:]
    for key in ["TEAQL_DOMAIN", "TEAQL_LOG_ENDPOINT", "TEAQL_LOG_MAX_SIZE", "TEAQL_LOG_MAX_FILES", "TEAQL_LOG_FORMAT"] {
      if let value = getenv(key) { values[key] = String(cString: value) }
    }
    return values
  }
  private static func timestamp() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date())
  }
  private static func validName(_ name: String) -> Bool {
    let stem = name.components(separatedBy: ".")[0].uppercased()
    let device = ["CON", "PRN", "AUX", "NUL"].contains(stem)
      || stem.range(of: "^(COM|LPT)[1-9]$", options: .regularExpression) != nil
    return !name.isEmpty && name != "." && name != ".." && !name.hasSuffix(".") && !name.hasSuffix(" ")
      && !device && name.utf8.count <= 255
      && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "<>:\"/\\|?*".unicodeScalars.contains($0) }
  }
  public static func parseSize(_ input: String) throws -> Int64 {
    let value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let digits = value.prefix { $0.isASCII && $0.isNumber }
    guard let amount = Int64(digits), amount > 0 else { throw RuntimeLoggingError.initializationFailed }
    let suffix = value.dropFirst(digits.count).trimmingCharacters(in: .whitespacesAndNewlines)
    let multiplier: Int64
    switch suffix {
    case "": multiplier = 1
    case "K", "KB": multiplier = 1024
    case "M", "MB": multiplier = 1024 * 1024
    case "G", "GB": multiplier = 1024 * 1024 * 1024
    default: throw RuntimeLoggingError.initializationFailed
    }
    let (result, overflow) = amount.multipliedReportingOverflow(by: multiplier)
    guard !overflow else { throw RuntimeLoggingError.initializationFailed }
    return result
  }

  public init(_ options: RuntimeLoggingOptions = RuntimeLoggingOptions()) throws {
    var validated = "teaql"
    do {
      let environment = options.environment ?? Self.environment()
      let domain = environment["TEAQL_DOMAIN"].flatMap { $0.isEmpty ? nil : $0 }
      let name = options.logName ?? domain ?? (options.modelNames.count == 1 ? options.modelNames[0] : "teaql")
      guard Self.validName(name) else { throw RuntimeLoggingError.initializationFailed }
      validated = name; self.logName = name
      let format = options.logFormat ?? environment["TEAQL_LOG_FORMAT"] ?? "json"
      guard ["json", "human"].contains(format) else { throw RuntimeLoggingError.initializationFailed }
      self.logFormat = format
      self.maxSize = try Self.parseSize(environment["TEAQL_LOG_MAX_SIZE"] ?? "50M")
      let retention = environment["TEAQL_LOG_MAX_FILES"] ?? "7"
      guard !retention.isEmpty, retention.utf8.allSatisfy({ (48...57).contains($0) }),
        let files = Int(retention), files <= Int32.max else { throw RuntimeLoggingError.initializationFailed }
      self.maxFiles = files
      let configured = environment["TEAQL_LOG_ENDPOINT"].flatMap { $0.isEmpty ? nil : $0 } ?? "./logs/\(name).log"
      if ["stdout", "stderr", "-"].contains(configured) {
        self.path = nil; self.stream = configured
      } else {
        var endpoint = configured
        if endpoint.hasPrefix("file:") {
          guard let uri = URL(string: endpoint), uri.isFileURL, uri.query == nil, uri.fragment == nil,
            uri.host == nil || uri.host == "" || uri.host == "localhost", !uri.path.isEmpty else { throw RuntimeLoggingError.initializationFailed }
          endpoint = uri.path
        } else if endpoint.contains("://") { throw RuntimeLoggingError.initializationFailed }
        let base = options.workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let destination = URL(fileURLWithPath: endpoint, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        self.path = destination; self.stream = nil
      }
      try emit(record(.info, event: "runtime.start", message: "TeaQL runtime started", fields: [:]))
    } catch {
      Self.failure(validated, "log_destination_unavailable")
      throw RuntimeLoggingError.initializationFailed
    }
  }

  public static func defaultLogger() -> RuntimeLogger {
    let env = environment()
    let directory = FileManager.default.currentDirectoryPath
    let key = directory + "\n" + env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    return defaults.gate.withLock {
      if let existing = defaults.loggers[key] { return existing }
      do {
        let logger = try RuntimeLogger(RuntimeLoggingOptions(environment: env, workingDirectory: URL(fileURLWithPath: directory, isDirectory: true)))
        defaults.loggers[key] = logger
        return logger
      } catch { fatalError("Runtime logging initialization failed") }
    }
  }

  private func record(_ level: RuntimeLogLevel, event: String, message: String, fields: [String: Any]) -> [String: Any] {
    var result = fields
    result["timestamp"] = Self.timestamp(); result["level"] = level.rawValue
    result["log_name"] = logName; result["runtime"] = "swift"; result["event"] = event; result["message"] = message
    return result
  }
  @discardableResult public func write(_ level: RuntimeLogLevel, event: String, message: String, safeFields: [String: Any] = [:]) -> Bool {
    do { try emit(record(level, event: event, message: message, fields: safeFields)); return true }
    catch { Self.failure(logName, "log_write_failed"); return false }
  }
  package static func failure(_ name: String, _ code: String) {
    let record: [String: Any] = ["timestamp": timestamp(), "level": "ERROR", "log_name": name, "runtime": "swift",
      "event": "logging.failure", "message": "Runtime logging failed", "error_code": code]
    if let data = try? JSONSerialization.data(withJSONObject: record) { try? writeAll(2, data + Data([10])) }
  }
  private static func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = loggingWrite(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw RuntimeLoggingError.initializationFailed }
        offset += count
      }
    }
  }
  private func archives(_ path: URL) throws -> [(Int, URL)] {
    let prefix = path.lastPathComponent + "."
    return try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey])
      .compactMap { file -> (Int, URL)? in
        let name = file.lastPathComponent
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = name.dropFirst(prefix.count)
        guard !suffix.isEmpty, !suffix.hasPrefix("0"), suffix.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        guard let number = Int(suffix), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw RuntimeLoggingError.initializationFailed }
        return (number, file)
      }.sorted { $0.0 > $1.0 }
  }
  private func emit(_ record: [String: Any]) throws {
    let encoded = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
    let data: Data
    if logFormat == "human" {
      guard let shared = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw RuntimeLoggingError.initializationFailed }
      data = try Self.humanRecord(shared)
    } else { data = encoded + Data([10]) }
    try gate.withLock {
      guard let path else { try Self.writeAll(stream == "stderr" ? 2 : 1, data); return }
      let lockPath = path.path + ".lock"
      let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
      var ownership: Int32
      while true {
        ownership = loggingOpen(lockPath, O_CREAT | O_EXCL | O_WRONLY)
        if ownership >= 0 { break }
        guard errno == EEXIST, DispatchTime.now().uptimeNanoseconds < deadline else { throw RuntimeLoggingError.initializationFailed }
        Thread.sleep(forTimeInterval: 0.005)
      }
      let result = Result<Void, Error> {
        try checkPresentation(path) // Before retention/rotation can alter any existing file.
        let archives = try archives(path)
        for (number, file) in archives where number > maxFiles { try FileManager.default.removeItem(at: file) }
        let attributes: [FileAttributeKey: Any]?
        do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { attributes = nil }
        if let attributes {
          guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date else { throw RuntimeLoggingError.initializationFailed }
          let day = Int64(floor(modified.timeIntervalSince1970 / 86400))
          let now = Int64(floor(Date().timeIntervalSince1970 / 86400))
          if size > 0 && (Int64(data.count) > maxSize - size || day != now) {
            for (number, file) in archives where number <= maxFiles {
              if number == maxFiles { try FileManager.default.removeItem(at: file) }
              else { try FileManager.default.moveItem(at: file, to: URL(fileURLWithPath: path.path + ".\(number + 1)")) }
            }
            if maxFiles == 0 { try FileManager.default.removeItem(at: path) }
            else { try FileManager.default.moveItem(at: path, to: URL(fileURLWithPath: path.path + ".1")) }
          }
        }
        let descriptor = loggingOpen(path.path, O_CREAT | O_APPEND | O_WRONLY)
        guard descriptor >= 0 else { throw RuntimeLoggingError.initializationFailed }
        let append = Result { try Self.writeAll(descriptor, data) }
        let closed = loggingClose(descriptor)
        try append.get()
        guard closed == 0 else { throw RuntimeLoggingError.initializationFailed }
      }
      let closed = loggingClose(ownership)
      let release = Result { try FileManager.default.removeItem(atPath: lockPath) }
      try result.get()
      guard closed == 0 else { throw RuntimeLoggingError.initializationFailed }
      try release.get()
    }
  }

  private static let eventFields: Set<String> = ["timestamp", "level", "log_name", "runtime", "event", "message"]
  private static func humanText(_ value: String, escapeBackslash: Bool) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
      if escapeBackslash && scalar.value == 92 { output += "\\\\" }
      else if scalar.value < 32 || (127...159).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029 {
        output += String(format: "\\u%04x", scalar.value)
      } else { output.unicodeScalars.append(scalar) }
    }
    return output
  }
  private static func humanRecord(_ record: [String: Any]) throws -> Data {
    func text(_ key: String) throws -> String {
      guard let value = record[key] as? String else { throw RuntimeLoggingError.initializationFailed }
      return humanText(value, escapeBackslash: true)
    }
    var output = try "\(text("timestamp")) [TeaQL][\(text("log_name"))][\(text("level"))] \(text("event")) runtime=\(text("runtime"))\n  \(text("message"))\n"
    for key in record.keys.sorted() where !eventFields.contains(key) {
      if key == "sql", let sql = record[key] as? String {
        output += "  sql:\n"
        for line in sql.components(separatedBy: "\n") { output += "    " + humanText(line, escapeBackslash: true) + "\n" }
      } else {
        let data = try JSONSerialization.data(withJSONObject: record[key]!, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        guard let value = String(data: data, encoding: .utf8) else { throw RuntimeLoggingError.initializationFailed }
        output += "  " + humanText(key, escapeBackslash: true) + "=" + humanText(value, escapeBackslash: false) + "\n"
      }
    }
    return Data(output.utf8)
  }
  private func checkPresentation(_ path: URL) throws {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: path.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = (attributes[.size] as? NSNumber)?.int64Value else { throw RuntimeLoggingError.initializationFailed }
    if size == 0 { return }
    let input = try FileHandle(forReadingFrom: path)
    defer { try? input.close() }
    var bytes = Data()
    while true {
      guard let chunk = try input.read(upToCount: 4096), !chunk.isEmpty else { throw RuntimeLoggingError.initializationFailed }
      if let newline = chunk.firstIndex(of: 10) { bytes.append(chunk.prefix(upTo: newline)); break }
      bytes.append(chunk)
    }
    guard let first = String(data: bytes, encoding: .utf8) else { throw RuntimeLoggingError.initializationFailed }
    if logFormat == "human", first.range(of: #"^\d{4}-\d\d-\d\dT\S+(?:Z|\+00:00) \[TeaQL\]\[.*\]\[(?:INFO|WARN|ERROR)\] .+ runtime=\S+$"#, options: .regularExpression) != nil { return }
    if logFormat == "json", let record = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      Self.eventFields.allSatisfy({ record[$0] is String }), let level = record["level"] as? String,
      ["INFO", "WARN", "ERROR"].contains(level) { return }
    throw RuntimeLoggingError.initializationFailed
  }

  package func writeSQL(_ metadata: SQLExecutionMetadata) {
    let safe = LogPrivacy.project(metadata, allowPlaintext: LogPrivacy.plaintextEnabled())
    let outcome = safe.executionOutcome ?? "unknown"
    let level: RuntimeLogLevel = ["failure", "cancelled", "error"].contains(outcome) ? .error : outcome == "retrying" ? .warn : .info
    do {
      func encoded<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
      var fields: [String: Any] = ["category": "SQL", "outcome": outcome, "sql": safe.debugSQL,
        "comment": safe.comment ?? "", "purpose": safe.purpose ?? "", "audit_reason": safe.auditReason ?? "",
        "trace_chain": try encoded(safe.traceChain), "trace_path": try encoded(safe.tracePath),
        "mutation_lineage": try encoded(safe.mutationLineage), "elapsed_us": safe.elapsedMicros]
      if let count = safe.resultCount { fields["result_count"] = count }
      if let count = safe.affectedRows { fields["affected_rows"] = count }
      if let reason = safe.sqlOmissionReason { fields["omission_reason"] = reason }
      if let identity = safe.telemetryCorrelation { fields["trace_id"] = identity.traceID }
      write(level, event: outcome == "retrying" ? "sql.retry" : "sql.\(outcome)", message: "TeaQL SQL execution", safeFields: fields)
    } catch { Self.failure(logName, "log_projection_failed") }
  }
  package func writeAudit(_ safe: AuditEvent) {
    do {
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(safe))
      write(.info, event: "audit.event", message: "TeaQL audit event", safeFields: ["category": "AUDIT", "outcome": "success", "audit": object])
    } catch { Self.failure(logName, "log_projection_failed") }
  }
}

package struct RuntimeDiagnosticSQLLogSink: DiagnosticSQLLogSink {
  let logger: RuntimeLogger
  package func write(_ metadata: SQLExecutionMetadata) async { logger.writeSQL(metadata) }
}

package struct RuntimeLoggingAuditSink: AuditSink {
  let logger: RuntimeLogger
  let delegate: (any AuditSink)?
  package func record(_ event: AuditEvent) async throws {
    logger.writeAudit(event)
    try await delegate?.record(event)
  }
}

package struct RuntimeLoggingTelemetry: RuntimeTelemetry {
  let delegate: any RuntimeTelemetry
  let logger: RuntimeLogger
  private func log(_ operation: RuntimeOperation, error: (any Error)?) {
    var category = error.map { runtimeErrorCategory(String(reflecting: type(of: $0))) }
    if error is CheckException { category = "validation" }
    if let rejection = error as? TeaQLError {
      switch rejection {
      case .missingComment, .missingPurpose, .missingAuditReason, .invalidHardLimit, .invalidLimit, .hardLimitExceeded, .invalidOffset, .unknownEntity, .unknownProperty: category = "validation"
      case .optimisticLock: category = "conflict"
      default: break
      }
    }
    if let policy = error as? MutationPolicyError, case .denied = policy { category = "authorization" }
    let outcome = error == nil ? "success" : "failure"
    let level: RuntimeLogLevel = error == nil ? .info : ["validation", "authorization", "conflict"].contains(category ?? "") ? .warn : .error
    var fields: [String: Any] = ["category": operation.family.uppercased(), "outcome": outcome]
    var carrier: [String: String] = [:]
    delegate.inject(&carrier)
    if let parent = carrier["traceparent"] {
      let parts = parent.split(separator: "-", omittingEmptySubsequences: false)
      if parts.count == 4, parts[0] != "ff", zip(parts, [2, 32, 16, 2]).allSatisfy({ value, count in
        value.utf8.count == count && value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      }), parts[1].contains(where: { $0 != "0" }), parts[2].contains(where: { $0 != "0" }) {
        fields["trace_id"] = String(parts[1])
      }
    }
    if let category { fields["error_code"] = category }
    logger.write(level, event: "operation.\(outcome)", message: "TeaQL operation \(outcome)", safeFields: fields)
  }
  package func withOperation<Result: Sendable>(_ operation: RuntimeOperation, completion: @Sendable (Result) -> [String: RuntimeTelemetryValue], _ body: () async throws -> Result) async rethrows -> Result {
    try await delegate.withOperation(operation, completion: completion) {
      do { let result = try await body(); log(operation, error: nil); return result }
      catch { log(operation, error: error); throw error }
    }
  }
  package func withSynchronousOperation<Result>(_ operation: RuntimeOperation, completion: (Result) -> [String: RuntimeTelemetryValue], _ body: () throws -> Result) rethrows -> Result {
    try delegate.withSynchronousOperation(operation, completion: completion) {
      do { let result = try body(); log(operation, error: nil); return result }
      catch { log(operation, error: error); throw error }
    }
  }
  package func inject(_ carrier: inout [String: String]) { delegate.inject(&carrier) }
  package func recordSQL(_ metadata: SQLExecutionMetadata) { delegate.recordSQL(metadata) }
  package func flush() async { await delegate.flush() }
  package func shutdown() async { await delegate.shutdown() }
}
