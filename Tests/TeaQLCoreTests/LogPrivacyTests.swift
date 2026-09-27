import XCTest
@testable import TeaQLCore

final class LogPrivacyTests: XCTestCase {
  func testEnvironmentChild() async {
    guard ProcessInfo.processInfo.environment["TEAQL_LOG_PRIVACY_TEST_CHILD"] == "1" else { return }
    let sink = TextDiagnosticSQLLogSink()
    await sink.write(entry(field: "name", value: "PRIVATE-CUSTOMER-CANARY"))
    await sink.write(entry(field: "password", value: "PASSWORD-CANARY"))
  }

  func testRealProcessEnvironmentAndFileOutput() throws {
    for setting: String? in [nil, "true", LogPrivacy.acknowledgement + " ", LogPrivacy.acknowledgement] {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-process-\(UUID().uuidString).log")
      XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
      let handle = try FileHandle(forWritingTo: file)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      process.arguments = ["TeaQLCoreTests.LogPrivacyTests/testEnvironmentChild"]
      var environment = ProcessInfo.processInfo.environment
      environment["TEAQL_LOG_PRIVACY_TEST_CHILD"] = "1"
      environment[LogPrivacy.environmentName] = setting
      process.environment = environment
      process.standardOutput = handle
      process.standardError = handle
      try process.run()
      process.waitUntilExit()
      try handle.close()
      let text = try String(contentsOf: file, encoding: .utf8)
      XCTAssertEqual(process.terminationStatus, 0, text)
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
    XCTAssertEqual(safe.parameters, [.null])
    XCTAssertFalse(safe.comment!.contains("PRIVATE-CUSTOMER-CANARY"))
    XCTAssertEqual(source.parameters, [.string("PRIVATE-CUSTOMER-CANARY")])
    XCTAssertEqual(LogPrivacy.project(source, allowPlaintext: true).parameters, source.parameters)
    let password = LogPrivacy.project(entry(field: "password", value: "PASSWORD-CANARY"), allowPlaintext: true)
    XCTAssertEqual(password.parameters, [.null])
    XCTAssertFalse(password.debugSQL.contains("PASSWORD-CANARY"))
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
    XCTAssertEqual(entries[0].parameters, [.null])
  }

  private func entry(field: String, value: String) -> SQLExecutionMetadata {
    SQLExecutionMetadata(operation: .select, comment: "load \(value)", purpose: "test privacy",
      parameterizedSQL: "select * from customer where \(field) = ?", parameters: [.string(value)],
      debugSQL: "select * from customer where \(field) = '\(value)'", elapsedMicros: 1,
      resultCount: 1, resultSummary: "one row")
  }
}
