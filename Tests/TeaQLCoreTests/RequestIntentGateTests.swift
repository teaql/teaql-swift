import Foundation
import XCTest
@testable import TeaQLCore

final class RequestIntentGateTests: XCTestCase {
  private let descriptor = EntityDescriptor(name: "School", table: "school_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

  func testMissingQueryIntentRejectsBeforePolicyAndProvider() async throws {
    for logging in [false, true] {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { query in calls.increment("policy"); return query },
      querySQLLogEnabled: logging, mutationSQLLogEnabled: logging)
    for blank in [nil, "", " \t\r\n", "\u{85}", "\u{a0}", "\u{2003}"] as [String?] {
      for field in ["comment", "purpose"] {
        var query = SelectQuery(entity: descriptor)
        query.comment = field == "comment" ? blank : "load SECRET-CANARY"
        query.purpose = field == "purpose" ? blank : "render SECRET-CANARY"
        do { _ = try await context.execute(query); XCTFail("missing intent was accepted") }
        catch { checkIntentError(error, field: field, kind: "query") }
        do { _ = try await context.count(query); XCTFail("missing intent reached count") }
        catch { checkIntentError(error, field: field, kind: "query") }
      }
    }
    XCTAssertEqual(calls.value("policy"), 0)
    XCTAssertEqual(calls.value("query"), 0)
    XCTAssertEqual(calls.value("count"), 0)
    }
  }

  private func checkIntentError(_ error: Error, field: String, kind: String,
    file: StaticString = #filePath, line: UInt = #line) {
    guard let error = error as? RequestIntentError else {
      XCTFail("Expected structured request intent error: \(error)", file: file, line: line)
      return
    }
    XCTAssertEqual(error.code, field == "purpose" ? "QUERY_PURPOSE_REQUIRED" : "REQUEST_COMMENT_REQUIRED", file: file, line: line)
    XCTAssertEqual(error.field, field, file: file, line: line)
    XCTAssertEqual(error.requestKind, kind, file: file, line: line)
    XCTAssertFalse(error.description.contains("SECRET-CANARY"), file: file, line: line)
  }

  func testMissingMutationIntentRejectsBeforeCheckerWithLogsDisabled() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "intent", entities: [descriptor],
      checkers: ["School": IntentGateChecker(calls: calls)]))
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    do { _ = try await context.execute(Mutation(kind: .create, entity: descriptor)); XCTFail("missing reason accepted") }
    catch { checkIntentError(error, field: "comment", kind: "mutation") }
    XCTAssertEqual(calls.value("checker"), 0)
    XCTAssertEqual(calls.value("mutation"), 0)
  }

  func testTraceOnlyMutationCannotSupplyMissingRequestComment() async throws {
    for logging in [false, true] {
      let calls = IntentGateCalls()
      let provider = IntentGateProvider(calls: calls)
      var runtime = TeaQLRuntime()
      try runtime.install(RuntimeModule(name: "trace-only intent", entities: [descriptor],
        checkers: ["School": IntentGateChecker(calls: calls)]))
      let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
        requestPolicy: RequestPolicy { query in calls.increment("queryPolicy"); return query },
        auditSink: IntentGateAudit(calls: calls), telemetrySink: IntentGateTelemetry(calls: calls),
        diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in calls.increment("diagnostic") }),
        querySQLLogEnabled: logging, mutationSQLLogEnabled: logging,
        runtimeTelemetry: IntentGateRuntimeTelemetry(calls: calls),
        mutationPolicyRegistry: IntentGateRegistry(calls: calls),
        mutationGovernanceSink: DelegatingMutationGovernanceSink { _, _ in calls.increment("governance") })
      // Real caller input for TC-REQ-12; no explicit mutation comment is set.
      let lineage = [TraceNode(entity: "School", comment: "SECRET-CANARY trace-only reason",
        purpose: "", kind: "auditReason", entityID: .int(801))]
      let mutation = Mutation(kind: .create, entity: descriptor,
        values: ["id": .int(801)], mutationLineage: lineage)
      XCTAssertNil(mutation.auditReason)
      XCTAssertEqual(mutation.mutationLineage, lineage)
      do { _ = try MutationRequest(mutation: mutation); XCTFail("trace supplied the request comment") }
      catch { checkIntentError(error, field: "comment", kind: "mutation") }
      do { _ = try context.preflightMutation(mutation); XCTFail("trace reached preflight") }
      catch { checkIntentError(error, field: "comment", kind: "mutation") }
      do { _ = try await context.execute(mutation); XCTFail("trace reached mutation execution") }
      catch { checkIntentError(error, field: "comment", kind: "mutation") }
      do { _ = try await provider.execute(mutation); XCTFail("trace reached direct provider execution") }
      catch { checkIntentError(error, field: "comment", kind: "mutation") }
      for name in ["checker", "queryPolicy", "policy", "query", "count", "begin", "mutation",
        "commit", "rollback", "sql", "diagnostic", "audit", "governance", "telemetry"] {
        XCTAssertEqual(calls.value(name), 0, "\(name), logging=\(logging)")
      }
      XCTAssertNil(mutation.auditReason)
      XCTAssertEqual(mutation.mutationLineage, lineage)
    }
  }

  func testPolicyCannotReplaceOwnedQueryIntent() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { query in
        var changed = query; changed.comment = "POLICY-CANARY"; changed.purpose = "POLICY-CANARY"
        return changed
      })
    var query = SelectQuery(entity: descriptor)
    query.comment = "root query"; query.purpose = "root purpose"
    _ = try await context.execute(query)
    XCTAssertEqual(calls.text("queryComment"), "root query")
    XCTAssertEqual(calls.text("queryPurpose"), "root purpose")
  }

  func testCheckerCannotReplaceOwnedMutationReason() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "intent", entities: [descriptor],
      checkers: ["School": IntentReplacingChecker()]))
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 })
    _ = try await context.execute(Mutation(kind: .create, entity: descriptor, auditReason: "root write"))
    XCTAssertEqual(calls.text("mutationComment"), "root write")
  }

  func testBlankGraphRootCannotUseChildReasonOrStartTransaction() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    let child = Mutation(kind: .create, entity: descriptor, auditReason: "valid child reason")
    do {
      _ = try await context.executeGraphSave(comment: "\u{85}") { context, _ in try await context.execute(child) }
      XCTFail("blank graph root accepted")
    } catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.field, "comment")
      XCTAssertEqual(error.requestKind, "mutation")
    }
    XCTAssertEqual(calls.value("begin"), 0)
    XCTAssertEqual(calls.value("mutation"), 0)
  }

  func testBatchMissingRootRejectsBeforeCheckerPolicyAndTransactionWithLogsDisabled() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "intent", entities: [descriptor],
      checkers: ["School": IntentGateChecker(calls: calls)]))
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: IntentGateAudit(calls: calls),
      telemetrySink: IntentGateTelemetry(calls: calls),
      querySQLLogEnabled: false, mutationSQLLogEnabled: false,
      mutationPolicyRegistry: IntentGateRegistry(calls: calls))
    let items = [Mutation(kind: .create, entity: descriptor, auditReason: "valid child")]
    for comment in [nil, "", " ", "\u{85}", "\u{2007}"] as [String?] {
      do {
        _ = try await context.execute(MutationBatchRequest(mutations: items, comment: comment))
        XCTFail("missing batch root accepted")
      } catch let error as RequestIntentError {
        XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
        XCTAssertEqual(error.field, "comment")
        XCTAssertEqual(error.requestKind, "mutation")
      }
    }
    for name in ["checker", "policy", "begin", "mutation", "commit", "rollback", "sql", "audit"] {
      XCTAssertEqual(calls.value(name), 0, name)
    }
  }
}

private final class IntentGateCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Int] = [:]
  private var texts: [String: String] = [:]
  func increment(_ name: String) { lock.withLock { values[name, default: 0] += 1 } }
  func value(_ name: String) -> Int { lock.withLock { values[name, default: 0] } }
  func observe(_ name: String, text: String) { lock.withLock { texts[name] = text } }
  func text(_ name: String) -> String? { lock.withLock { texts[name] } }
}

private struct IntentGateProvider: QueryExecutor, GraphTransactionExecutor {
  let calls: IntentGateCalls
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    calls.observe("queryComment", text: request.intent.comment)
    calls.observe("queryPurpose", text: request.intent.purpose)
    calls.increment("query"); return QueryResult(records: [], backend: "intent-test")
  }
  func count(_ request: QueryRequest) async throws -> Int { calls.increment("count"); return 0 }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    calls.observe("mutationComment", text: request.intent.comment)
    calls.increment("mutation"); return MutationResult(affectedRows: 1)
  }
  func beginGraphTransaction() async throws { calls.increment("begin") }
  func commitGraphTransaction() async throws { calls.increment("commit") }
  func rollbackGraphTransaction() async throws { calls.increment("rollback") }
}

private struct IntentReplacingChecker: EntityChecker {
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.auditReason = "CHECKER-CANARY"; return []
  }
}

private struct IntentGateChecker: EntityChecker {
  let calls: IntentGateCalls
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    calls.increment("checker"); return []
  }
}

private struct IntentGateRegistry: MutationPolicyRegistry {
  let calls: IntentGateCalls
  func resolve(requestKey: String) -> (any MutationPolicy)? {
    calls.increment("policy"); return nil
  }
}

private struct IntentGateAudit: AuditSink {
  let calls: IntentGateCalls
  func record(_ event: AuditEvent) { calls.increment("audit") }
}

private struct IntentGateTelemetry: RuntimeTelemetrySink {
  let calls: IntentGateCalls
  func record(_ metadata: SQLExecutionMetadata) { calls.increment("sql") }
}

private struct IntentGateRuntimeTelemetry: RuntimeTelemetry {
  let calls: IntentGateCalls
  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation, completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    calls.increment("telemetry")
    return try await body()
  }
  func withSynchronousOperation<Result>(
    _ operation: RuntimeOperation, completion: (Result) -> [String: RuntimeTelemetryValue],
    _ body: () throws -> Result
  ) rethrows -> Result {
    calls.increment("telemetry")
    return try body()
  }
  func flush() async {}
  func shutdown() async {}
}
