import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TeaQLCore

final class RuntimeLoggingTests: XCTestCase, @unchecked Sendable {
  private var directory: URL!
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-logging-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  private func make(_ environment: [String: String] = [:]) throws -> RuntimeLogger {
    try RuntimeLogger(RuntimeLoggingOptions(environment: environment, workingDirectory: directory))
  }
  private func records(_ files: [URL]) throws -> [[String: Any]] {
    try files.flatMap { file in
      let bytes = try Data(contentsOf: file); XCTAssertEqual(bytes.last, 10)
      return try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map { line in
        let record = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        for key in ["timestamp", "level", "log_name", "runtime", "event", "message"] { XCTAssertFalse((record[key] as! String).isEmpty) }
        XCTAssertEqual(record["runtime"] as? String, "swift"); XCTAssertTrue((record["timestamp"] as! String).hasSuffix("Z"))
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: record["timestamp"] as! String)); return record
      }
    }
  }
  func testDefaultBeforeFirstQueryAndAppendAcrossTwoStarts() throws {
    let first = try make(); XCTAssertEqual(first.path, directory.appendingPathComponent("logs/teaql.log"))
    XCTAssertEqual(first.maxSize, 50 * 1024 * 1024); XCTAssertEqual(first.maxFiles, 7)
    XCTAssertEqual(try records([first.path!])[0]["event"] as? String, "runtime.start")
    let second = try make(); XCTAssertTrue(second.write(.info, event: "probe", message: "Completed"))
    XCTAssertEqual(try records([first.path!]).count, 3)
  }
  func testNamePrecedenceOverrideAndKnownModules() throws {
    let cases: [(String?, String, [String], String)] = [("application", "domain", ["model"], "application"),
      (nil, "domain", ["model"], "domain"), (nil, "", ["model"], "model"), (nil, "", ["one", "two"], "teaql"), ("订单", "", [], "订单")]
    for (index, item) in cases.enumerated() {
      let base = directory.appendingPathComponent("application\(index)", isDirectory: true)
      let logger = try RuntimeLogger(RuntimeLoggingOptions(logName: item.0, modelNames: item.2,
        environment: ["TEAQL_DOMAIN": item.1, "TEAQL_LOG_ENDPOINT": "other/output.jsonl"], workingDirectory: base))
      XCTAssertEqual(logger.logName, item.3); XCTAssertEqual(logger.path, base.appendingPathComponent("other/output.jsonl"))
      XCTAssertEqual(try records([logger.path!])[0]["log_name"] as? String, item.3)
    }
    let runtime = try TeaQLRuntime(modules: [RuntimeModule(name: "known-model", entities: [])],
      loggingOptions: RuntimeLoggingOptions(environment: [:], workingDirectory: directory))
    XCTAssertEqual(runtime.runtimeLogger.logName, "known-model")
  }
  func testInvalidNamesAndConfigurationFailStartup() throws {
    for name in ["", ".", "..", "../secret", "a/b", "a\\b", "bad\nname", "NUL", "COM1.txt", "trailing.", "trailing ", String(repeating: "x", count: 256)] {
      XCTAssertThrowsError(try RuntimeLogger(RuntimeLoggingOptions(logName: name, environment: [:], workingDirectory: directory)))
    }
    for value in ["0", "-1", "1.2M", "1TB", "999999999999999999999G"] { XCTAssertThrowsError(try RuntimeLogger.parseSize(value)) }
    for value in ["-1", "invalid", "1.5", "2147483648"] { XCTAssertThrowsError(try make(["TEAQL_LOG_MAX_FILES": value])) }
    for (value, bytes): (String, Int64) in [("1", 1), ("2K", 2048), ("3KB", 3072), ("2m", 2097152), ("1MB", 1048576), ("1G", 1073741824), ("1GB", 1073741824)] {
      XCTAssertEqual(try RuntimeLogger.parseSize(value), bytes)
    }
  }
  func testUtf8OversizedWholeRecordsOrderingAndZeroRetention() throws {
    let logger = try make(["TEAQL_LOG_MAX_SIZE": "256", "TEAQL_LOG_MAX_FILES": "2"])
    for index in 0..<5 { XCTAssertTrue(logger.write(.info, event: "probe", message: String(repeating: "界", count: 200), safeFields: ["sequence": index])) }
    for index in 0..<3 {
      let file = URL(fileURLWithPath: logger.path!.path + (index == 0 ? "" : ".\(index)"))
      let all = try records([file]); XCTAssertEqual(all.count, 1); XCTAssertEqual(all[0]["sequence"] as? Int, 4 - index)
      XCTAssertEqual(all[0]["message"] as? String, String(repeating: "界", count: 200))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: logger.path!.path + ".3"))
    let zero = try make(["TEAQL_LOG_MAX_SIZE": "256", "TEAQL_LOG_MAX_FILES": "0"])
    zero.write(.info, event: "probe", message: String(repeating: "x", count: 400))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: zero.path!.deletingLastPathComponent().path), ["teaql.log"])
  }
  func testUtcDayAndRestart() throws {
    for restart in [false, true] {
      let base = directory.appendingPathComponent("day-\(restart)", isDirectory: true)
      let options = RuntimeLoggingOptions(environment: [:], workingDirectory: base)
      let logger = try RuntimeLogger(options); let previous = try Data(contentsOf: logger.path!)
      try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: logger.path!.path)
      if restart { _ = try RuntimeLogger(options) } else { XCTAssertTrue(logger.write(.info, event: "next.day", message: "Next day")) }
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: logger.path!.path + ".1")), previous)
      XCTAssertEqual(try records([logger.path!]).count, 1)
    }
  }
  func testOrdinaryUtf8RecordsRespectWholeLineByteLimit() throws {
    let logger = try make(["TEAQL_LOG_MAX_SIZE": "1K", "TEAQL_LOG_MAX_FILES": "1000"])
    for index in 0..<40 { XCTAssertTrue(logger.write(.info, event: "regular", message: String(repeating: "界", count: 30), safeFields: ["index": index])) }
    let files = try FileManager.default.contentsOfDirectory(at: logger.path!.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    XCTAssertGreaterThan(files.count, 1)
    for file in files { let size = try Data(contentsOf: file).count; XCTAssertGreaterThan(size, 0); XCTAssertLessThanOrEqual(size, 1024) }
    let all = try records(files); XCTAssertEqual(all.count, 41)
    XCTAssertEqual(all.compactMap { $0["index"] as? Int }.sorted(), Array(0..<40))
  }
  func testRotationFailurePreservesForeignArchiveAndBusinessOutcome() async throws {
    let logger = try make(); let previous = try Data(contentsOf: logger.path!)
    let archive = URL(fileURLWithPath: logger.path!.path + ".1", isDirectory: true)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: false)
    try Data("preserve".utf8).write(to: archive.appendingPathComponent("marker"))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: logger.path!.path)
    let result = try await context(logger).execute(query()); XCTAssertEqual(result.records.count, 1)
    let original = OriginalFailure()
    do { _ = try await context(logger, failure: original).execute(query()); XCTFail("Lost business failure") }
    catch { XCTAssertTrue((error as? OriginalFailure) === original) }
    XCTAssertFalse(logger.write(.info, event: "probe", message: "Completed"))
    XCTAssertEqual(try Data(contentsOf: logger.path!), previous)
    XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("marker"), encoding: .utf8), "preserve")
  }
  private struct Stub: QueryExecutor, MutationExecutor {
    let failure: OriginalFailure?
    init(_ failure: OriginalFailure? = nil) { self.failure = failure }
    func execute(_ request: QueryRequest) async throws -> QueryResult {
      if let failure { throw failure }; return QueryResult(records: [["id": .int(1)]], backend: "stub")
    }
    func execute(_ request: MutationRequest) async throws -> MutationResult { MutationResult(affectedRows: 1) }
  }
  private final class OriginalFailure: Error, @unchecked Sendable { let message = "private-original-value" }
  private func context(_ logger: RuntimeLogger, failure: OriginalFailure? = nil) -> UserContext {
    UserContext(runtime: TeaQLRuntime(runtimeLogger: logger), queryExecutor: Stub(failure), mutationExecutor: Stub(),
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry())
  }
  private func query() -> SelectQuery {
    let entity = EntityDescriptor(name: "Probe", table: "probe", properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    var query = SelectQuery(entity: entity); query.comment = "read probe"; query.purpose = "verify logging"; return query
  }
  func testStartupFatalAndPostStartupPreservesActualQueryAndOriginalError() async throws {
    let active = directory.appendingPathComponent("logs/teaql.log", isDirectory: true)
    try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
    XCTAssertThrowsError(try make()); try FileManager.default.removeItem(at: active)
    let logger = try make(); let context = context(logger)
    XCTAssertTrue(context.runtimeLogger === context._generatedBootstrapContext().runtimeLogger)
    XCTAssertTrue(context.runtimeTelemetry is NoopRuntimeTelemetry)
    try FileManager.default.removeItem(at: logger.path!); try FileManager.default.createDirectory(at: logger.path!, withIntermediateDirectories: false)
    let result = try await context.execute(query()); XCTAssertEqual(result.records.count, 1)
    let original = OriginalFailure()
    do { _ = try await self.context(logger, failure: original).execute(query()); XCTFail("Lost business failure") }
    catch { XCTAssertTrue((error as? OriginalFailure) === original) }
    XCTAssertFalse(logger.write(.info, event: "probe", message: "Completed"))
  }
  func testActualSuccessRejectionFailureSafeSqlAndDefaultAudit() async throws {
    let logger = try make(); let context = context(logger)
    _ = try await context.execute(query())
    var invalid = query(); invalid.purpose = nil
    do { _ = try await context.execute(invalid); XCTFail("Accepted invalid query") } catch { }
    do { _ = try await self.context(logger, failure: OriginalFailure()).execute(query()); XCTFail("Lost final failure") } catch { }
    let sink = RuntimeDiagnosticSQLLogSink(logger: logger)
    await sink.write(SQLExecutionMetadata(operation: .select, parameterizedSQL: "SELECT id FROM probe WHERE password = ?", parameters: [.string("private-password-value")], debugSQL: "private-password-value", elapsedMicros: 1, resultSummary: "", executionOutcome: "retrying"))
    _ = try await context.execute(Mutation(kind: .create, entity: query().entity, values: [:], auditReason: "create probe"))
    let all = try records([logger.path!])
    XCTAssertTrue(all.contains { $0["level"] as? String == "INFO" && $0["event"] as? String == "operation.success" })
    XCTAssertTrue(all.contains { $0["level"] as? String == "WARN" && $0["event"] as? String == "query.rejected" })
    XCTAssertTrue(all.contains { $0["level"] as? String == "ERROR" && $0["event"] as? String == "operation.failure" })
    XCTAssertTrue(all.contains { $0["level"] as? String == "WARN" && $0["event"] as? String == "sql.retry" })
    XCTAssertTrue(all.contains { $0["category"] as? String == "AUDIT" && $0["event"] as? String == "audit.event" })
    let text = try String(contentsOf: logger.path!, encoding: .utf8)
    XCTAssertFalse(text.contains("private-password-value")); XCTAssertFalse(text.contains("private-original-value"))
  }
  private struct TraceTelemetry: RuntimeTelemetry {
    func withOperation<Result: Sendable>(_ operation: RuntimeOperation, completion: @Sendable (Result) -> [String: RuntimeTelemetryValue], _ body: () async throws -> Result) async rethrows -> Result { try await body() }
    func withSynchronousOperation<Result>(_ operation: RuntimeOperation, completion: (Result) -> [String: RuntimeTelemetryValue], _ body: () throws -> Result) rethrows -> Result { try body() }
    func inject(_ carrier: inout [String: String]) { carrier["traceparent"] = "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01" }
    func flush() async {}
    func shutdown() async {}
  }
  func testOperationKeepsAvailableTraceCorrelation() async throws {
    let logger = try make()
    let context = UserContext(runtime: TeaQLRuntime(runtimeLogger: logger), queryExecutor: Stub(), mutationExecutor: Stub(),
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: TraceTelemetry())
    _ = try await context.execute(query())
    let all = try records([logger.path!])
    let completion = all.first { $0["event"] as? String == "operation.success" }
    XCTAssertEqual(completion?["trace_id"] as? String, "0123456789abcdef0123456789abcdef")
    let metadata = SQLExecutionMetadata(operation: .select, parameterizedSQL: "SELECT id FROM probe", parameters: [], debugSQL: "SELECT id FROM probe", elapsedMicros: 1, resultSummary: "1 row")
      .withTelemetryCorrelation(SQLTelemetryCorrelation(owner: UUID(), traceID: "0123456789abcdef0123456789abcdef", spanID: "0123456789abcdef"))
    await RuntimeDiagnosticSQLLogSink(logger: logger).write(metadata)
    XCTAssertEqual(try records([logger.path!]).last?["trace_id"] as? String, "0123456789abcdef0123456789abcdef")
  }
  func testConcurrentInstancesRotateAndReopen() throws {
    let base = directory!
    DispatchQueue.concurrentPerform(iterations: 8) { worker in
      do {
        let logger = try RuntimeLogger(RuntimeLoggingOptions(environment: ["TEAQL_LOG_MAX_SIZE": "1K", "TEAQL_LOG_MAX_FILES": "1000"], workingDirectory: base))
        for index in 0..<30 { XCTAssertTrue(logger.write(.info, event: "concurrent", message: "Completed", safeFields: ["id": "\(worker)/\(index)"])) }
      } catch { XCTFail("Concurrent startup failed") }
    }
    try assertConcurrent(expected: 240, starts: 8)
  }
  private func assertConcurrent(expected: Int, starts: Int) throws {
    let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("logs"), includingPropertiesForKeys: nil)
    let all = try records(files); let ids = all.compactMap { $0["id"] as? String }
    XCTAssertEqual(Set(ids).count, expected); XCTAssertEqual(ids.count, expected); XCTAssertEqual(all.count, expected + starts)
  }
  func testProcessHelper() throws {
    guard let base = getenv("TEAQL_LOGGING_TEST_DIRECTORY"), let worker = getenv("TEAQL_LOGGING_TEST_WORKER") else { return }
    let logger = try RuntimeLogger(RuntimeLoggingOptions(environment: ["TEAQL_LOG_MAX_SIZE": "1K", "TEAQL_LOG_MAX_FILES": "1000"],
      workingDirectory: URL(fileURLWithPath: String(cString: base), isDirectory: true)))
    for index in 0..<30 { XCTAssertTrue(logger.write(.info, event: "concurrent", message: "Completed", safeFields: ["id": "\(String(cString: worker))/\(index)"])) }
  }
  func testIndependentProcessesCoordinateWholeLines() throws {
    var children: [Process] = []
    defer { for child in children { if child.isRunning { child.terminate() }; child.waitUntilExit() } }
    for worker in 0..<4 {
      let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      #if os(macOS)
      child.arguments = ["-XCTest", "TeaQLCoreTests.RuntimeLoggingTests/testProcessHelper", Bundle(for: RuntimeLoggingTests.self).bundleURL.path]
      #else
      child.arguments = ["TeaQLCoreTests.RuntimeLoggingTests/testProcessHelper"]
      #endif
      var environment = ["TEAQL_LOGGING_TEST_DIRECTORY": directory.path, "TEAQL_LOGGING_TEST_WORKER": "\(worker)", "TMPDIR": directory.path,
        "TEAQL_TELEMETRY_ENABLED": "false"]
      for key in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
        if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
      }
      child.environment = environment
      child.standardOutput = Pipe(); child.standardError = FileHandle.standardError
      try child.run(); children.append(child)
    }
    for child in children { child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0) }
    try assertConcurrent(expected: 120, starts: 4)
  }
}
