import Foundation
import XCTest
@testable import TeaQLCore

final class SQLMaskingPolicyTests: XCTestCase {
  private func entry(_ sql: String = "SELECT ?, ?, ?, ?", values: [TeaQLValue] = [
    .string("Ordinary"), .string("Riverside"), .string("UNKNOWN-CANARY"), .string("PASSWORD-CANARY")
  ], policies: [SQLParameterLogPolicy] = [.plain, .masked, .unknown, .credential], trusted: Bool = true) -> SQLExecutionMetadata {
    SQLExecutionMetadata(operation: .select, comment: "what: UNKNOWN-CANARY PASSWORD-CANARY",
      purpose: "why: preserve safe SQL", parameterizedSQL: sql, parameters: values,
      debugSQL: "RAW-DEBUG-CANARY", elapsedMicros: 7, resultCount: 1, resultSummary: "1 row",
      parameterLogPolicies: policies, generatedSQL: trusted)
  }

  func testMixedPoliciesAndDebugRevocation() {
    let source = entry()
    let safe = LogPrivacy.project(source)
    XCTAssertTrue(safe.debugSQL.contains("'Ordinary', 'Ri*****de' /* masked */"))
    XCTAssertEqual(safe.maskedParameters, [false, true, true, true])
    XCTAssertFalse(safe.debugSQL.contains("CANARY"))
    XCTAssertFalse(safe.comment!.contains("CANARY"))
    XCTAssertEqual(safe.debugSQL, LogPrivacy.project(safe).debugSQL)
    XCTAssertEqual(source.parameters[1], .string("Riverside"))
    let debug = LogPrivacy.project(source, allowPlaintext: true)
    XCTAssertTrue(debug.debugSQL.contains("'Riverside'"))
    XCTAssertTrue(debug.debugSQL.contains("DEBUG PLAINTEXT; EXPLICIT OPT-IN"))
    XCTAssertTrue(debug.debugSQL.contains("NOT REPLAYABLE"))
    XCTAssertFalse(debug.debugSQL.contains("CANARY"))
    XCTAssertEqual(safe.debugSQL, LogPrivacy.project(debug).debugSQL)
    XCTAssertFalse(LogPrivacy.project(safe, allowPlaintext: true).debugSQL.contains("Riverside"))
  }

  func testUnknownPoliciesRemainHiddenInDebugAndMismatchFailsClosed() {
    let unknown = entry("SELECT ?", values: [.string("UNKNOWN-CANARY")], policies: [], trusted: false)
    XCTAssertTrue(LogPrivacy.project(unknown, allowPlaintext: true).debugSQL.contains("'[REDACTED]' /* masked */"))
    let mismatch = entry("SELECT ?", values: [.string("UNKNOWN-CANARY")])
    let safe = LogPrivacy.project(mismatch, allowPlaintext: true)
    XCTAssertEqual(safe.sqlOmissionReason, "policy_count_mismatch")
    XCTAssertFalse(safe.debugSQL.contains("CANARY"))
    XCTAssertEqual(safe.parameters, [.string("[REDACTED]")])
  }

  func testGoldenVectorsAtSQLBoundary() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let data = try String(contentsOf: root.appendingPathComponent("test-vectors/masking-v1.tsv"), encoding: .utf8)
    for line in data.split(separator: "\n").dropFirst() {
      let fields = String(line).components(separatedBy: "\t")
      let source = entry("SELECT ?", values: [.string(fields[1])], policies: [.masked])
      let safe = LogPrivacy.project(source)
      XCTAssertEqual(safe.parameters, [.string(fields[2])], fields[0])
      XCTAssertTrue(safe.debugSQL.contains("'" + fields[2].replacingOccurrences(of: "'", with: "''") + "' /* masked */"))
    }
  }

  func testArraysNullNestedCredentialsAndSafeFailure() throws {
    let source = entry("SELECT ?, ?, ?", values: [.array([.string("Riverside"), .string("12345678")]),
      .null, .object(["access_token": .string("TOKEN-CANARY"), "public": .string("visible")])],
      policies: [.masked, .masked, .plain])
    let safe = LogPrivacy.project(source)
    XCTAssertEqual(safe.parameters[0], .array([.string("Ri*****de"), .string("********")]))
    XCTAssertEqual(safe.parameters[1], .null)
    XCTAssertTrue(safe.debugSQL.contains("visible"))
    XCTAssertFalse(safe.debugSQL.contains("TOKEN-CANARY"))
    XCTAssertFalse(LogPrivacy.project(source, allowPlaintext: true).debugSQL.contains("TOKEN-CANARY"))
    for sql in ["SELECT ?1", "SELECT :named", "SELECT ? /*", "SELECT 'unterminated", "SELECT ?, ?", "SELECT 1"] {
      let failure = LogPrivacy.project(entry(sql, values: [.string("VALUE-CANARY")], policies: [.masked]))
      XCTAssertNotNil(failure.sqlOmissionReason, sql)
      XCTAssertFalse(failure.debugSQL.contains("SELECT"), sql)
      XCTAssertFalse(failure.debugSQL.contains("VALUE-CANARY"), sql)
    }
    let raw = LogPrivacy.project(entry("SELECT 'INLINE-CANARY', ?", values: [.string("value")], policies: [], trusted: false), allowPlaintext: true)
    XCTAssertNotNil(raw.sqlOmissionReason)
    XCTAssertFalse(raw.parameterizedSQL.contains("INLINE-CANARY"))
    XCTAssertThrowsError(try SQLLogRenderer.render("SELECT ?", parameters: [.double(.infinity)]))
  }

  func testQuotedIdentifiersCommentsAndEscapedLiteralsAreNotParameters() throws {
    let sql = "SELECT ?, '?', \"?\", [?], `?`, 'it''s ?' /* ? */ -- ?\n"
    let rendered = try SQLLogRenderer.render(sql, parameters: [.string("O'Reilly")])
    XCTAssertEqual(rendered, "SELECT 'O''Reilly', '?', \"?\", [?], `?`, 'it''s ?' /* ? */ -- ?\n")
  }

  func testInheritedIntentAndImmutableCopyDebugRevocation() {
    let write = entry()
    let source = SQLExecutionMetadata(operation: .select, comment: "what: Riverside UNKNOWN-CANARY",
      purpose: "why: reload PASSWORD-CANARY", auditReason: "persist Riverside PASSWORD-CANARY",
      tracePath: [TraceNode(entity: "Riverside", comment: "Riverside", purpose: "PASSWORD-CANARY",
        level: 3, kind: "UNKNOWN-CANARY", name: "Riverside")],
      parameterizedSQL: "SELECT name FROM customer WHERE id = ? LIMIT 10000", parameters: [.int(1)],
      debugSQL: "", elapsedMicros: 1, resultCount: 0, resultSummary: "Riverside snapshot missing",
      parameterLogPolicies: [.plain], generatedSQL: true)
    let safe = LogPrivacy.project(source, intentSource: write)
    XCTAssertFalse(String(describing: safe).contains("Riverside"))
    XCTAssertFalse(String(describing: safe).contains("CANARY"))
    XCTAssertEqual(safe.parameters, [.int(1)])
    XCTAssertEqual(safe.parameterizedSQL, source.parameterizedSQL)
    XCTAssertTrue(safe.debugSQL.contains("LIMIT 10000"))
    let debug = LogPrivacy.project(source, allowPlaintext: true, intentSource: write)
    XCTAssertTrue(debug.auditReason!.contains("Riverside"))
    XCTAssertFalse(String(describing: debug).contains("CANARY"))
    let copied = debug
    let downgraded = LogPrivacy.project(copied)
    XCTAssertEqual(downgraded.auditReason, safe.auditReason)
    XCTAssertEqual(downgraded.debugSQL, safe.debugSQL)
    XCTAssertFalse(String(describing: downgraded).contains("Riverside"))
    XCTAssertFalse(LogPrivacy.project(downgraded, allowPlaintext: true).debugSQL.contains("DEBUG PLAINTEXT"))
    let reconstructed = SQLExecutionMetadata(operation: debug.operation, auditReason: debug.auditReason,
      parameterizedSQL: debug.parameterizedSQL, parameters: debug.parameters, debugSQL: debug.debugSQL,
      elapsedMicros: debug.elapsedMicros, resultSummary: debug.resultSummary,
      parameterLogPolicies: debug.parameterLogPolicies, maskedParameters: debug.maskedParameters, generatedSQL: true)
    XCTAssertEqual(LogPrivacy.project(reconstructed).auditReason, "[REDACTED]")
    XCTAssertEqual(source.auditReason, "persist Riverside PASSWORD-CANARY")
  }

  func testInheritedNestedUnknownAndNumericBindings() {
    let write = entry("UPDATE customer SET a=?, b=?, c=?, d=?", values: [
      .double(1.25), .object(["password": .string("NESTED-CANARY"), "label": .string("ordinary")]),
      .string("UNKNOWN-CANARY"), .array([.string("Riverside")])], policies: [.masked, .plain, .unknown, .masked])
    let source = SQLExecutionMetadata(operation: .select, auditReason: "1.25 NESTED-CANARY UNKNOWN-CANARY Riverside",
      parameterizedSQL: "SELECT * FROM customer WHERE id=? LIMIT 10000", parameters: [.int(1)], debugSQL: "",
      elapsedMicros: 0, resultSummary: "readback", parameterLogPolicies: [.plain], generatedSQL: true)
    for debug in [false, true] {
      let result = LogPrivacy.project(source, allowPlaintext: debug, intentSource: write)
      XCTAssertFalse(result.auditReason!.contains("CANARY"))
      XCTAssertEqual(result.auditReason!.contains("1.25"), debug)
      XCTAssertEqual(result.auditReason!.contains("Riverside"), debug)
      XCTAssertEqual(result.parameterizedSQL, source.parameterizedSQL)
    }
  }

  func testInvalidInheritedPoliciesFailClosedEvenInDebug() {
    let write = entry("UPDATE customer SET a=?", values: [.string("UNKNOWN-CANARY")], policies: [.plain, .plain])
    let source = SQLExecutionMetadata(operation: .select, auditReason: "UNKNOWN-CANARY",
      parameterizedSQL: "SELECT ?", parameters: [.int(1)], debugSQL: "", elapsedMicros: 0,
      resultSummary: "readback", parameterLogPolicies: [.plain], generatedSQL: true)
    XCTAssertEqual(LogPrivacy.project(source, allowPlaintext: true, intentSource: write).auditReason, "[REDACTED]")
  }

  func testRepeatedProjectionDoesNotScrubSQLStructure() {
    for value: TeaQLValue in [.int(1), .string("customer")] {
      let sql = "SELECT name FROM customer WHERE name=? LIMIT 10000"
      let source = entry(sql, values: [value], policies: [.masked])
      let safe = LogPrivacy.project(source)
      let again = LogPrivacy.project(safe)
      XCTAssertEqual(again.parameterizedSQL, sql)
      XCTAssertEqual(again.debugSQL, safe.debugSQL)
    }
  }

  func testPhysicalReadbackChildrenAreSafeAndDebugCanBeRevoked() {
    let write = entry("INSERT INTO customer VALUES (?, ?)",
      values: [.string("Riverside"), .string("PASSWORD-CANARY")], policies: [.masked, .credential])
    let read = SQLExecutionMetadata(operation: .select, comment: "persist Riverside PASSWORD-CANARY",
      purpose: "verify persisted mutation", parameterizedSQL: "SELECT name FROM customer WHERE id=?",
      parameters: [.int(17)], debugSQL: "", elapsedMicros: 1, resultCount: 1,
      resultSummary: "1 row", parameterLogPolicies: [.plain], generatedSQL: true)
    let source = write.includingStatements([write, read])
    let safe = LogPrivacy.project(source)
    XCTAssertEqual(safe.statements.count, 2)
    XCTAssertEqual(safe.statements[1].parameters, [.int(17)])
    XCTAssertEqual(safe.statements[1].comment, "persist [REDACTED] [REDACTED]")
    XCTAssertFalse(String(describing: safe).contains("Riverside"))
    XCTAssertFalse(String(describing: safe).contains("PASSWORD-CANARY"))
    let debug = LogPrivacy.project(source, allowPlaintext: true)
    XCTAssertEqual(debug.statements[1].comment, "persist Riverside [REDACTED]")
    XCTAssertFalse(String(describing: debug).contains("PASSWORD-CANARY"))
    let revoked = LogPrivacy.project(debug)
    XCTAssertEqual(revoked.statements[1].comment, safe.statements[1].comment)
    XCTAssertFalse(String(describing: revoked).contains("Riverside"))
    XCTAssertEqual(source.statements[1].comment, "persist Riverside PASSWORD-CANARY")
    XCTAssertEqual(source.statements[0].parameters, write.parameters)
  }
}
