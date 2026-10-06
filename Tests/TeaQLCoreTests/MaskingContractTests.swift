import Foundation
import XCTest
@testable import TeaQLCore

final class MaskingContractTests: XCTestCase {
  func testMaskGolden() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try String(contentsOf: root.appendingPathComponent("test-vectors/masking-v1.tsv"), encoding: .utf8)
    for line in data.split(separator: "\n").dropFirst() {
      let values = String(line).components(separatedBy: "\t")
      XCTAssertEqual(LogPrivacy.maskAuditValue(values[1]), values[2], values[0])
    }
  }

  func testMaskContractExpandedSql() async throws {
    let cases = [("", ""), ("Ada", "***"), ("12345678", "********"),
                 ("ABCDEFGH", "AB****GH"), ("Riverside", "Ri*****de"), ("O'Reilly", "O'****ly")]
    for (raw, masked) in cases {
      let source = entry(raw)
      let safe = LogPrivacy.project(source, allowPlaintext: false)
      XCTAssertEqual(source.parameters, [.string(raw)])
      // No field policy is attached: unknown provenance needs complete masking.
      XCTAssertTrue(safe.debugSQL.contains("name = '"),
                    "expected expanded SQL for \(raw), got \(safe.debugSQL)")
      XCTAssertFalse(safe.debugSQL.contains("name = ?"))
      XCTAssertFalse(safe.debugSQL.contains("[REDACTED SQL"))
      let path = FileManager.default.temporaryDirectory.appendingPathComponent("mask-contract-\(UUID().uuidString).log")
      defer { try? FileManager.default.removeItem(at: path) }
      let sink = TextDiagnosticSQLLogSink(writer: { text in
        try! text.write(to: path, atomically: true, encoding: .utf8)
      })
      await sink.write(safe)
      let log = try String(contentsOf: path, encoding: .utf8)
      XCTAssertTrue(log.contains("name = '"))
      if raw.count >= 8 && !masked.hasPrefix("*") { XCTAssertFalse(log.contains(masked.replacingOccurrences(of: "'", with: "''"))) }
      XCTAssertTrue(log.lowercased().contains("masked"))
      if !raw.isEmpty { XCTAssertFalse(log.contains("'" + raw.replacingOccurrences(of: "'", with: "''") + "'")) }
    }
  }

  func testMaskContractEnvironmentChild() async {
    guard ProcessInfo.processInfo.environment["TEAQL_MASK_CONTRACT_CHILD"] == "1" else { return }
    let sink = TextDiagnosticSQLLogSink(writer: { print("RECORD_BOUNDARY" + $0) })
    for _ in 0..<2 {
      await sink.write(entry("Riverside", policies: [.masked]))
    }
  }

  func testMaskContractDebugProvenance() throws {
    guard ProcessInfo.processInfo.environment["TEAQL_MASK_CONTRACT_CHILD"] != "1" else { return }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("mask-provenance-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: path) }
    XCTAssertTrue(FileManager.default.createFile(atPath: path.path, contents: nil))
    let handle = try FileHandle(forWritingTo: path)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    #if os(macOS)
    process.arguments = ["-XCTest", "TeaQLCoreTests.MaskingContractTests/testMaskContractEnvironmentChild",
      Bundle(for: MaskingContractTests.self).bundleURL.path]
    #else
    process.arguments = ["TeaQLCoreTests.MaskingContractTests/testMaskContractEnvironmentChild"]
    #endif
    var environment = ProcessInfo.processInfo.environment
    environment["TEAQL_MASK_CONTRACT_CHILD"] = "1"
    environment[LogPrivacy.environmentName] = LogPrivacy.acknowledgement
    environment.removeValue(forKey: "XCTestConfigurationFilePath")
    process.environment = environment
    process.standardOutput = handle
    process.standardError = handle
    let status = try runBoundedTestChild(process, output: handle)
    let text = try String(contentsOf: path, encoding: .utf8)
    XCTAssertEqual(status, 0, text)
    let records = text.components(separatedBy: "RECORD_BOUNDARY")
    XCTAssertEqual(records.count, 3, text)
    for record in records.dropFirst() {
      XCTAssertTrue(record.contains("'Riverside'"), record)
      XCTAssertTrue(record.uppercased().contains("DEBUG"), record)
      XCTAssertTrue(record.uppercased().contains("PLAINTEXT"), record)
    }
  }

  private func entry(_ value: String, policies: [SQLParameterLogPolicy] = []) -> SQLExecutionMetadata {
    SQLExecutionMetadata(operation: .select, comment: "what: edit customer", purpose: "why: verify mask contract",
      parameterizedSQL: "UPDATE customer SET name = ?", parameters: [.string(value)],
      debugSQL: "UPDATE customer SET name = '" + value.replacingOccurrences(of: "'", with: "''") + "'",
      elapsedMicros: 1, resultCount: 1, resultSummary: "1 row affected", parameterLogPolicies: policies)
  }
}
