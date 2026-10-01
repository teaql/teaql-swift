import Foundation
import XCTest
@testable import TeaQLCore

final class RequestIntentGateTests: XCTestCase {
  private let descriptor = EntityDescriptor(name: "School", table: "school_data",
    properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])

  func testMissingQueryIntentRejectsBeforePolicyWithLogsDisabled() async throws {
    let calls = IntentGateCalls()
    let provider = IntentGateProvider(calls: calls)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { query in calls.increment("policy"); return query },
      querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    let query = SelectQuery(entity: descriptor)
    do { _ = try await context.execute(query); XCTFail("missing comment was accepted") }
    catch { XCTAssertTrue(String(describing: error).contains("REQUEST_COMMENT_REQUIRED")) }
    do { _ = try await context.count(query); XCTFail("missing comment reached count") }
    catch { XCTAssertTrue(String(describing: error).contains("REQUEST_COMMENT_REQUIRED")) }
    XCTAssertEqual(calls.value("policy"), 0)
    XCTAssertEqual(calls.value("query"), 0)
    XCTAssertEqual(calls.value("count"), 0)
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
    catch { XCTAssertTrue(String(describing: error).contains("REQUEST_COMMENT_REQUIRED")) }
    XCTAssertEqual(calls.value("checker"), 0)
    XCTAssertEqual(calls.value("mutation"), 0)
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
      _ = try await context.executeGraphSave(comment: "\u{85}") { try await context.execute(child) }
      XCTFail("blank graph root accepted")
    } catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED")
      XCTAssertEqual(error.field, "comment")
    }
    XCTAssertEqual(calls.value("begin"), 0)
    XCTAssertEqual(calls.value("mutation"), 0)
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
