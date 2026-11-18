import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TeaQLCore

final class RuntimeLoggingPresentationsTests: XCTestCase, @unchecked Sendable {
  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-presentations-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    directory = directory.resolvingSymlinksInPath()
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  private func make(_ format: String, _ environment: [String: String] = [:], base: URL? = nil) throws -> RuntimeLogger {
    let workingDirectory = URL(fileURLWithPath: (base ?? directory).path, isDirectory: true)
    return try RuntimeLogger(RuntimeLoggingOptions(logFormat: format, environment: environment, workingDirectory: workingDirectory))
  }
  private func scalar(_ text: String) throws -> String {
    try JSONSerialization.jsonObject(with: Data(("\"" + text.replacingOccurrences(of: "\"", with: "\\\"") + "\"").utf8), options: [.fragmentsAllowed]) as! String
  }
  private func parse(_ data: Data, _ format: String) throws -> [[String: Any]] {
    XCTAssertEqual(data.last, 10)
    guard !data.isEmpty else { throw RuntimeLoggingError.initializationFailed }
    let lines = String(data: data, encoding: .utf8)!.components(separatedBy: "\n").dropLast()
    if format == "json" { return try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] } }
    let header = try NSRegularExpression(pattern: #"^(\S+) \[TeaQL\]\[(.*)\]\[(INFO|WARN|ERROR)\] (.*) runtime=(\S+)$"#)
    var rows: [[String: Any]] = []; var sql: [String]?
    for line in lines {
      XCTAssertFalse(line.unicodeScalars.contains { $0.value < 32 || (127...159).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029 })
      if let match = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
        func part(_ index: Int) -> String { String(line[Range(match.range(at: index), in: line)!]) }
        let timestamp = part(1); XCTAssertTrue(timestamp.hasSuffix("Z"))
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; XCTAssertNotNil(formatter.date(from: timestamp))
        rows.append(["timestamp": timestamp, "log_name": try scalar(part(2)), "level": part(3), "event": try scalar(part(4)), "runtime": part(5)]); sql = nil
      } else {
        XCTAssertFalse(rows.isEmpty); XCTAssertTrue(line.hasPrefix("  ")); let index = rows.count - 1
        if rows[index]["message"] == nil { rows[index]["message"] = try scalar(String(line.dropFirst(2))) }
        else if line == "  sql:" { sql = []; rows[index]["sql"] = "" }
        else if line.hasPrefix("    "), sql != nil { sql!.append(try scalar(String(line.dropFirst(4)))); rows[index]["sql"] = sql!.joined(separator: "\n") }
        else {
          let fields = line.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false); XCTAssertEqual(fields.count, 2)
          rows[index][try scalar(String(fields[0]))] = try JSONSerialization.jsonObject(with: Data(fields[1].utf8), options: [.fragmentsAllowed]); sql = nil
        }
      }
    }
    for row in rows { for key in ["timestamp", "level", "log_name", "runtime", "event", "message"] { XCTAssertNotNil(row[key] as? String) } }
    return rows
  }
  private func read(_ files: [URL], _ format: String) throws -> [[String: Any]] { try files.flatMap { try parse(Data(contentsOf: $0), format) } }
  private func files(_ path: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil) }

  func testSelectionNamesOverrideFixedContextsDefaultAndTwoStarts() throws {
    XCTAssertEqual(try RuntimeLogger(RuntimeLoggingOptions(environment: [:], workingDirectory: directory.appendingPathComponent("default"))).logFormat, "json")
    for format in ["json", "human"] {
      let cases: [(String?, String, [String], String)] = [("application", "domain", ["model"], "application"), (nil, "domain", ["model"], "domain"),
        (nil, "", ["model"], "model"), (nil, "", [], "teaql"), (nil, "", ["one", "two"], "teaql")]
      for (index, item) in cases.enumerated() {
        let base = directory.appendingPathComponent("\(format)-\(index)", isDirectory: true)
        var env = ["TEAQL_DOMAIN": item.1, "TEAQL_LOG_FORMAT": format]
        let logger = try RuntimeLogger(RuntimeLoggingOptions(logName: item.0, modelNames: item.2, environment: env, workingDirectory: base))
        XCTAssertEqual(logger.logName, item.3); XCTAssertEqual(logger.logFormat, format); XCTAssertEqual(logger.path, base.appendingPathComponent("logs/\(item.3).log"))
        env["TEAQL_LOG_FORMAT"] = "invalid-unused"; env["TEAQL_DOMAIN"] = "changed"
        let context = context(logger); XCTAssertTrue(context.runtimeLogger === context._generatedBootstrapContext().runtimeLogger)
        XCTAssertTrue(logger.write(.info, event: "frozen", message: "startup-owned"))
        _ = try RuntimeLogger(RuntimeLoggingOptions(logName: item.3, logFormat: format, environment: [:], workingDirectory: base)); XCTAssertEqual(try read([logger.path!], format).count, 3)
        let other = try make(format, ["TEAQL_LOG_FORMAT": "invalid-unused", "TEAQL_LOG_ENDPOINT": "override/custom.log"], base: base)
        XCTAssertEqual(other.path, base.appendingPathComponent("override/custom.log")); XCTAssertEqual(other.logFormat, format)
      }
    }
    for value in ["", "debug", "JSON", "human\nFORMAT-CANARY"] {
      XCTAssertThrowsError(try RuntimeLogger(RuntimeLoggingOptions(logFormat: value, environment: [:], workingDirectory: directory)))
      XCTAssertThrowsError(try RuntimeLogger(RuntimeLoggingOptions(environment: ["TEAQL_LOG_FORMAT": value], workingDirectory: directory)))
    }
  }

  func testSameTypedEventUnknownKindAndControlEscaping() throws {
    for format in ["json", "human"] {
      let logger = try make(format, base: directory.appendingPathComponent(format))
      var fields: [String: Any] = ["category": "SQL", "trace_id": "0123456789abcdef0123456789abcdef", "outcome": "retrying", "error_code": "connection_timeout",
        "entity_id": Int64(9007199254740993), "enabled": true, "result_count": 0, "omission_reason": NSNull(), "changes": [["field": "password", "value": "***"]],
        "sql": "SELECT id\nFROM customer\n\u{1b}\r\u{85}\u{2028}"]
      let message = "Readable \\u001b\nFORGED\u{1b}\r\u{85}\u{2029}"
      XCTAssertTrue(logger.write(.warn, event: "unknown.kind", message: message, safeFields: fields))
      var row = try read([logger.path!], format)[1]; row.removeValue(forKey: "timestamp")
      fields.merge(["level": "WARN", "log_name": "teaql", "runtime": "swift", "event": "unknown.kind", "message": message]) { _, value in value }
      XCTAssertEqual(try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
    }
  }
  private final class OriginalFailure: Error, @unchecked Sendable { let message = "PRIVATE-BUSINESS-CANARY" }
  private struct Stub: QueryExecutor, MutationExecutor {
    let failure: OriginalFailure?
    init(_ failure: OriginalFailure? = nil) { self.failure = failure }
    func execute(_ request: QueryRequest) async throws -> QueryResult {
      if let failure { throw failure }; return QueryResult(records: [["id": .int(1)]], backend: "stub")
    }
    func execute(_ request: MutationRequest) async throws -> MutationResult { MutationResult(affectedRows: 1) }
  }
  private func context(_ logger: RuntimeLogger, failure: OriginalFailure? = nil) -> UserContext {
    UserContext(runtime: TeaQLRuntime(runtimeLogger: logger), queryExecutor: Stub(failure), mutationExecutor: Stub(), requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry())
  }
  private func query() -> SelectQuery {
    let entity = EntityDescriptor(name: "Probe", table: "probe", properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    var query = SelectQuery(entity: entity); query.comment = "read probe"; query.purpose = "verify presentations"; return query
  }
  func testNativeSuccessRejectionFailurePrivacyAckAndCorrelation() async throws {
    let previous = getenv("TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS").map { String(cString: $0) }
    defer { if let previous { setenv("TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS", previous, 1) } else { unsetenv("TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS") } }
    for format in ["json", "human"] {
      let logger = try make(format, base: directory.appendingPathComponent(format)); let context = context(logger)
      let result = try await context.execute(query())
      XCTAssertEqual(result.records.count, 1)
      var invalid = query(); invalid.purpose = nil; do { _ = try await context.execute(invalid); XCTFail("accepted invalid query") } catch { }
      let original = OriginalFailure(); do { _ = try await self.context(logger, failure: original).execute(query()); XCTFail("lost error") } catch { XCTAssertTrue((error as? OriginalFailure) === original) }
      for ack in ["", "true", "I_UNDERSTAND_SENSITIVE_DATA_MAY_BE_WRITTEN_TO_DISK"] {
        setenv("TEAQL_ALLOW_SENSITIVE_PLAINTEXT_LOGS", ack, 1)
        let metadata = SQLExecutionMetadata(operation: .select, parameterizedSQL: "SELECT id FROM probe WHERE password = ?", parameters: [.string("PASSWORD-CANARY")],
          debugSQL: "PASSWORD-CANARY", elapsedMicros: 1, resultSummary: "", executionOutcome: "retrying")
          .withTelemetryCorrelation(SQLTelemetryCorrelation(owner: UUID(), traceID: "0123456789abcdef0123456789abcdef", spanID: "0123456789abcdef"))
        await RuntimeDiagnosticSQLLogSink(logger: logger).write(metadata); XCTAssertEqual(metadata.parameters, [.string("PASSWORD-CANARY")])
      }
      let entity = EntityDescriptor(name: "CredentialProbe", table: "credential_probe", properties: [
        PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "password", type: .string)])
      let mutation = Mutation(kind: .create, entity: entity, values: ["id": .int(42), "password": .string("AUDIT-CREDENTIAL-CANARY")], auditReason: "create AUDIT-CREDENTIAL-CANARY")
      _ = try await context.execute(mutation)
      XCTAssertEqual(mutation.values["password"], .string("AUDIT-CREDENTIAL-CANARY"))
      let rows = try read([logger.path!], format)
      XCTAssertTrue(rows.contains { $0["level"] as? String == "INFO" && $0["event"] as? String == "operation.success" })
      XCTAssertTrue(rows.contains { $0["level"] as? String == "WARN" && $0["event"] as? String == "query.rejected" })
      XCTAssertTrue(rows.contains { $0["level"] as? String == "ERROR" && $0["event"] as? String == "operation.failure" })
      let sql = rows.filter { $0["event"] as? String == "sql.retry" }; XCTAssertEqual(sql.count, 3)
      for row in sql { XCTAssertEqual(row["level"] as? String, "WARN"); XCTAssertEqual(row["trace_id"] as? String, "0123456789abcdef0123456789abcdef") }
      XCTAssertTrue(rows.contains { $0["event"] as? String == "audit.event" && $0["category"] as? String == "AUDIT" })
      XCTAssertFalse(try String(contentsOf: logger.path!, encoding: .utf8).contains("CANARY"))
    }
  }

  func testPositiveRetentionKeepsNumericNewestOrderAndWholeBlocks() throws {
    for format in ["json", "human"] {
      let logger = try make(format, ["TEAQL_LOG_MAX_SIZE": "256", "TEAQL_LOG_MAX_FILES": "2"], base: directory.appendingPathComponent(format))
      for index in 0..<5 { XCTAssertTrue(logger.write(.info, event: "retention", message: String(repeating: "界", count: 200), safeFields: ["sequence": index, "sql": "SELECT\n\(index)"])) }
      for index in 0..<3 {
        let rows = try read([URL(fileURLWithPath: logger.path!.path + (index == 0 ? "" : ".\(index)"))], format)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["sequence"] as? Int, 4 - index); XCTAssertEqual(rows[0]["sql"] as? String, "SELECT\n\(4 - index)")
      }
      XCTAssertEqual(try files(logger.path!).count, 3); XCTAssertFalse(FileManager.default.fileExists(atPath: logger.path!.path + ".3"))
    }
  }
  func testWholeUtf8MultilineSizeDayRestartOversizeRetentionAndOverride() throws {
    for format in ["json", "human"] { for override in [false, true] {
      let base = directory.appendingPathComponent("\(format)-\(override)"); var env = ["TEAQL_LOG_MAX_SIZE": "1K", "TEAQL_LOG_MAX_FILES": "100"]
      if override { env["TEAQL_LOG_ENDPOINT"] = "override/custom.log" }
      let logger = try make(format, env, base: base); let path = logger.path!
      for index in 0..<40 { XCTAssertTrue(logger.write(.info, event: "regular", message: String(repeating: "界", count: 25), safeFields: ["index": index, "sql": "SELECT id\nFROM customer"])) }
      let paths = try files(path); XCTAssertGreaterThan(paths.count, 1); for file in paths { let size = try Data(contentsOf: file).count; XCTAssertGreaterThan(size, 0); XCTAssertLessThanOrEqual(size, 1024) }
      let rows = try read(paths, format); XCTAssertEqual(rows.count, 41); XCTAssertEqual(rows.compactMap { $0["index"] as? Int }.sorted(), Array(0..<40))
      for row in rows where row["index"] != nil { XCTAssertEqual(row["sql"] as? String, "SELECT id\nFROM customer") }
      XCTAssertTrue(logger.write(.warn, event: "oversize", message: "whole", safeFields: ["sql": String(repeating: "界", count: 2000) + "\nLAST"]))
      let before = try Data(contentsOf: path); XCTAssertGreaterThan(before.count, 1024); XCTAssertEqual(try parse(before, format).count, 1)
      XCTAssertTrue(logger.write(.info, event: "after", message: "next")); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path.path + ".1")), before)
      for restart in [false, true] { try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172800)], ofItemAtPath: path.path); let previous = try Data(contentsOf: path)
        if restart { _ = try make(format, env, base: base) } else { XCTAssertTrue(logger.write(.info, event: "day", message: "UTC rotation")) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path.path + ".1")), previous); XCTAssertEqual(try read([path], format).count, 1)
      }
      env["TEAQL_LOG_MAX_FILES"] = "0"; let zero = try make(format, env, base: base); XCTAssertTrue(zero.write(.info, event: "last", message: String(repeating: "界", count: 2000)))
      // Directory enumeration may spell Darwin's /var alias as /private/var.
      // Every entry comes from this same parent; only the active name remains.
      XCTAssertEqual(try files(path).map(\.lastPathComponent), [path.lastPathComponent]); XCTAssertEqual(try read([path], format).count, 1)
    } }
  }
  private func assertBlocks(_ base: URL, _ format: String, _ count: Int, _ starts: Int) throws {
    let paths = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("logs"), includingPropertiesForKeys: nil)
    let rows = try read(paths, format); let ids = rows.compactMap { $0["id"] as? String }; XCTAssertEqual(ids.count, count); XCTAssertEqual(Set(ids).count, count); XCTAssertEqual(rows.count, count + starts)
    for row in rows { if let id = row["id"] as? String { XCTAssertEqual(row["sql"] as? String, "SELECT\n" + id) } }
  }
  func testConcurrentInstancesKeepContinuationLinesWithTheirEvent() throws {
    for format in ["json", "human"] {
      let base = directory.appendingPathComponent(format, isDirectory: true)
      DispatchQueue.concurrentPerform(iterations: 4) { worker in do {
        let logger = try RuntimeLogger(RuntimeLoggingOptions(logFormat: format, environment: ["TEAQL_LOG_MAX_SIZE": "2K", "TEAQL_LOG_MAX_FILES": "100"], workingDirectory: base))
        for index in 0..<30 { let id = "\(worker)/\(index)"; XCTAssertTrue(logger.write(.info, event: "parallel", message: "多线程", safeFields: ["id": id, "sql": "SELECT\n" + id])) }
      } catch { XCTFail("concurrent startup failed") } }
      try assertBlocks(base, format, 120, 4)
    }
  }
  func testProcessWorker() throws {
    guard let raw = getenv("TEAQL_PRESENTATION_DIRECTORY"), let rawFormat = getenv("TEAQL_PRESENTATION_FORMAT"), let rawWorker = getenv("TEAQL_PRESENTATION_WORKER") else { return }
    let base = URL(fileURLWithPath: String(cString: raw), isDirectory: true); let format = String(cString: rawFormat); let worker = String(cString: rawWorker)
    let endpoint = getenv("TEAQL_PRESENTATION_STREAM").map { String(cString: $0) }
    let capture = endpoint == "stderr" ? FileHandle.standardError : FileHandle.standardOutput
    if endpoint != nil { try capture.write(contentsOf: Data("TEAQL_STREAM_BEGIN\n".utf8)) }
    let env = endpoint.map { ["TEAQL_LOG_ENDPOINT": $0] } ?? ["TEAQL_LOG_MAX_SIZE": "2K", "TEAQL_LOG_MAX_FILES": "100"]
    let logger = try RuntimeLogger(RuntimeLoggingOptions(logFormat: format, environment: env, workingDirectory: base))
    if endpoint != nil { XCTAssertTrue(logger.write(.warn, event: "sql.retry", message: "Retry scheduled", safeFields: ["category": "SQL", "sql": "SELECT\nprobe"])); try capture.write(contentsOf: Data("TEAQL_STREAM_END\n".utf8)); return }
    for index in 0..<30 { let id = "\(worker)/\(index)"; XCTAssertTrue(logger.write(.info, event: "parallel", message: "原生并发", safeFields: ["id": id, "sql": "SELECT\n" + id])) }
  }
  private func child(_ base: URL, _ format: String, _ worker: String, stream: String? = nil) throws -> (Process, Pipe, Pipe) {
    let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    #if os(macOS)
    child.arguments = ["-XCTest", "TeaQLCoreTests.RuntimeLoggingPresentationsTests/testProcessWorker", Bundle(for: RuntimeLoggingPresentationsTests.self).bundleURL.path]
    #else
    child.arguments = ["TeaQLCoreTests.RuntimeLoggingPresentationsTests/testProcessWorker"]
    #endif
    var env = ["TEAQL_PRESENTATION_DIRECTORY": base.path, "TEAQL_PRESENTATION_FORMAT": format, "TEAQL_PRESENTATION_WORKER": worker, "TMPDIR": directory.path, "TEAQL_TELEMETRY_ENABLED": "false"]
    // Darwin's XCTest runner needs the same selected Swift framework search
    // paths as its parent; other environment input remains deliberately absent.
    for key in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
      if let value = ProcessInfo.processInfo.environment[key] { env[key] = value }
    }
    if let stream { env["TEAQL_PRESENTATION_STREAM"] = stream }; child.environment = env
    let output = Pipe(), error = Pipe(); child.standardOutput = output; child.standardError = error; try child.run(); return (child, output, error)
  }
  func testIndependentProcessesSubsequentStartAndBothStreams() throws {
    for format in ["json", "human"] {
      let base = directory.appendingPathComponent(format); var children: [(Process, Pipe, Pipe)] = []
      defer { for (child, _, _) in children { if child.isRunning { child.terminate() }; child.waitUntilExit() } }
      for worker in 0..<4 { children.append(try child(base, format, "\(worker)")) }
      for (child, _, _) in children { child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0) }
      let following = try child(base, format, "following"); children.append(following); following.0.waitUntilExit(); XCTAssertEqual(following.0.terminationStatus, 0); try assertBlocks(base, format, 150, 5)
      for endpoint in ["stdout", "stderr"] {
        let capture = try child(base, format, "stream", stream: endpoint); children.append(capture); capture.0.waitUntilExit(); XCTAssertEqual(capture.0.terminationStatus, 0)
        let output = String(decoding: capture.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); let error = capture.2.fileHandleForReading.readDataToEndOfFile()
        let bytes: Data
        let selected = endpoint == "stderr" ? String(decoding: error, as: UTF8.self) : output
        let begin = selected.components(separatedBy: "TEAQL_STREAM_BEGIN\n"); XCTAssertEqual(begin.count, 2)
        let end = try XCTUnwrap(begin.last).components(separatedBy: "TEAQL_STREAM_END\n"); XCTAssertEqual(end.count, 2)
        bytes = Data(try XCTUnwrap(end.first).utf8)
        let rows = try parse(bytes, format); XCTAssertEqual(rows.count, 2); let retry = try XCTUnwrap(rows.last); XCTAssertEqual(retry["level"] as? String, "WARN"); XCTAssertEqual(retry["sql"] as? String, "SELECT\nprobe")
      }
    }
  }
  func testMixedFormatAndIoFailuresPreserveFilesAndRealQueryResult() async throws {
    for format in ["json", "human"] {
      let base = directory.appendingPathComponent(format); let logger = try make(format, base: base); let path = logger.path!; let other = format == "json" ? "human" : "json"
      let archive = URL(fileURLWithPath: path.path + ".10"); try Data("preserve archive bytes".utf8).write(to: archive); var before = try Data(contentsOf: path)
      XCTAssertThrowsError(try make(other, ["TEAQL_LOG_MAX_SIZE": "1", "TEAQL_LOG_MAX_FILES": "0"], base: base)); XCTAssertEqual(try Data(contentsOf: path), before); XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "preserve archive bytes")
      let replacement = try make(other, base: directory.appendingPathComponent("replacement-" + format)); before = try Data(contentsOf: replacement.path!); try before.write(to: path)
      let result = try await context(logger).execute(query()); XCTAssertEqual(result.records.count, 1)
      let original = OriginalFailure(); do { _ = try await context(logger, failure: original).execute(query()); XCTFail("lost error") } catch { XCTAssertTrue((error as? OriginalFailure) === original) }
      XCTAssertFalse(logger.write(.info, event: "later", message: "business completion")); XCTAssertEqual(try Data(contentsOf: path), before); XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "preserve archive bytes")
      try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false); XCTAssertFalse(logger.write(.error, event: "later", message: "I/O failure")); XCTAssertThrowsError(try make(format, base: base))
    }
  }
}
