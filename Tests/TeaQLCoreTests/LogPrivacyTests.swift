import XCTest
@testable import TeaQLCore

final class LogPrivacyTests: XCTestCase {
  func testEnvironmentChild() async {
    guard ProcessInfo.processInfo.environment["TEAQL_LOG_PRIVACY_TEST_CHILD"] == "1" else { return }
    let sink = TextDiagnosticSQLLogSink()
    await sink.write(entry(field: "name", value: "PRIVATE-CUSTOMER-CANARY"))
    await sink.write(entry(field: "password", value: "PASSWORD-CANARY"))
    print("TEAQL_LOG_PRIVACY_CHILD_DONE")
  }

  func testRealProcessEnvironmentAndFileOutput() throws {
    // Xcode can inherit a test configuration that overrides command-line
    // selection. Never recursively spawn if a child runs the whole suite.
    guard ProcessInfo.processInfo.environment["TEAQL_LOG_PRIVACY_TEST_CHILD"] != "1" else { return }
    for setting: String? in [nil, "true", LogPrivacy.acknowledgement + " ", LogPrivacy.acknowledgement] {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-process-\(UUID().uuidString).log")
      XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
      let handle = try FileHandle(forWritingTo: file)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      #if os(macOS)
      process.arguments = ["-XCTest", "TeaQLCoreTests.LogPrivacyTests/testEnvironmentChild",
        Bundle(for: LogPrivacyTests.self).bundleURL.path]
      #else
      process.arguments = ["TeaQLCoreTests.LogPrivacyTests/testEnvironmentChild"]
      #endif
      var environment = ProcessInfo.processInfo.environment
      environment["TEAQL_LOG_PRIVACY_TEST_CHILD"] = "1"
      environment[LogPrivacy.environmentName] = setting
      environment.removeValue(forKey: "XCTestConfigurationFilePath")
      process.environment = environment
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      let deadline = Date().addingTimeInterval(30)
      while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning {
        process.terminate()
        try handle.close()
        XCTFail("Privacy child did not terminate within 30 seconds")
        return
      }
      try handle.close()
      let text = try String(contentsOf: file, encoding: .utf8)
      XCTAssertEqual(process.terminationStatus, 0, text)
      XCTAssertTrue(text.contains("TEAQL_LOG_PRIVACY_CHILD_DONE"), text)
      XCTAssertEqual(text.contains("PRIVATE-CUSTOMER-CANARY"), setting == LogPrivacy.acknowledgement, text)
      XCTAssertEqual(text.contains("may be written to disk"), setting == LogPrivacy.acknowledgement, text)
      XCTAssertFalse(text.contains("PASSWORD-CANARY"), text)
    }
  }

  func testAcknowledgementRequiresExactValue() {
    for value: String? in [nil, "", "true", LogPrivacy.acknowledgement + " "] {
      XCTAssertFalse(LogPrivacy.accepts(value))
    }
    XCTAssertTrue(LogPrivacy.accepts(LogPrivacy.acknowledgement))
  }

  func testProjectionPreservesExecutionValuesAndAlwaysHidesCredentials() {
    let source = entry(field: "name", value: "PRIVATE-CUSTOMER-CANARY")
    let safe = LogPrivacy.project(source)
    XCTAssertEqual(safe.parameters, [.string(LogPrivacy.maskAuditValue("PRIVATE-CUSTOMER-CANARY"))])
    XCTAssertFalse(safe.comment!.contains("PRIVATE-CUSTOMER-CANARY"))
    XCTAssertEqual(source.parameters, [.string("PRIVATE-CUSTOMER-CANARY")])
    XCTAssertEqual(LogPrivacy.project(source, allowPlaintext: true).parameters, source.parameters)
    let password = LogPrivacy.project(entry(field: "password", value: "PASSWORD-CANARY"), allowPlaintext: true)
    XCTAssertEqual(password.parameters, [.string("[REDACTED]")])
    XCTAssertFalse(password.debugSQL.contains("PASSWORD-CANARY"))
  }

  func testTargetIDOnlyScrubsIntentAndPreservesStructuralCounts() {
    let source = SQLExecutionMetadata(operation: .update, comment: "update order 1",
      purpose: "verify order 1", auditReason: "update order 1",
      parameterizedSQL: "update order_data set version = ? where id = ?",
      parameters: [.int(2), .int(1)], debugSQL: "", elapsedMicros: 1,
      affectedRows: 1, resultSummary: "1 rows affected",
      parameterLogPolicies: [.plain, .plain], generatedSQL: true)
    let safe = LogPrivacy.project(source, intentValues: [.int(1)])
    XCTAssertEqual(safe.auditReason, "update order [REDACTED]")
    XCTAssertEqual(safe.comment, "update order [REDACTED]")
    XCTAssertEqual(safe.purpose, "verify order [REDACTED]")
    XCTAssertEqual(safe.resultSummary, "1 rows affected")
    XCTAssertEqual(safe.parameters, [.int(2), .int(1)])
    XCTAssertEqual(source.auditReason, "update order 1")
  }

  func testDirectSinkAndEvidenceStoreAreSafe() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-privacy-\(UUID().uuidString).log")
    let sink = TextDiagnosticSQLLogSink(writer: { text in
      // A real file endpoint, not only a string assertion.
      try! text.write(to: path, atomically: true, encoding: .utf8)
    })
    let source = entry(field: "password", value: "PASSWORD-CANARY")
    await sink.write(source)
    XCTAssertFalse(try String(contentsOf: path, encoding: .utf8).contains("PASSWORD-CANARY"))
    let evidence = SQLExecutionEvidenceStore()
    await evidence.record(source)
    let entries = await evidence.snapshot()
    XCTAssertEqual(entries[0].parameters, [.string("[REDACTED]")])
  }

  private func entry(field: String, value: String) -> SQLExecutionMetadata {
    SQLExecutionMetadata(operation: .select, comment: "load \(value)", purpose: "test privacy",
      parameterizedSQL: "select * from customer where \(field) = ?", parameters: [.string(value)],
      debugSQL: "select * from customer where \(field) = '\(value)'", elapsedMicros: 1,
      resultCount: 1, resultSummary: "one row",
      parameterLogPolicies: [field == "password" ? .credential : .masked])
  }
}
