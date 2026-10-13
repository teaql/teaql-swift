import Foundation
import XCTest
@testable import TeaQLCore

final class GraphTelemetryTests: XCTestCase {
  func testRootCoversTransactionCallbacksAndCommittedAudit() async throws {
    let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
    let provider = GraphTelemetryProvider(probe: probe, failure: failure)
    let audit = GraphTelemetryAudit(probe: probe, provider: provider, failure: failure)
    let context = context(provider, probe, audit)
    let result = try await context.executeGraphSave(comment: "private root intent") { invocation, session in
      XCTAssertTrue(probe.active)
      try session.afterCommit { probe.append("callback"); XCTAssertTrue(probe.active) }
      _ = try await invocation.execute(Self.mutation())
      return 7
    }
    XCTAssertEqual(result, 7)
    XCTAssertEqual(probe.events, ["start", "begin", "mutation", "commit", "callback", "audit", "success"])
    XCTAssertEqual(probe.roots.count, 1)
    XCTAssertEqual(probe.roots.first?.family, "mutation")
    XCTAssertEqual(probe.roots.first?.name, "graph.save")
    XCTAssertFalse(probe.roots.contains { $0.attributes.values.contains(.string("private root intent")) })
    XCTAssertFalse(probe.active)
  }

  func testBeginAndCommitFailuresKeepOriginalErrorAndCloseRoot() async throws {
    for phase in ["begin", "commit"] {
      let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
      let provider = GraphTelemetryProvider(probe: probe, failure: failure, failing: phase)
      let context = context(provider, probe)
      do {
        _ = try await context.executeGraphSave(comment: "save graph") { _, _ in 1 }
        XCTFail("expected failure")
      } catch { XCTAssertTrue((error as? GraphTelemetryFailure) === failure) }
      XCTAssertEqual(probe.events, phase == "begin"
        ? ["start", "begin", "failure"] : ["start", "begin", "commit", "rollback", "failure"])
      XCTAssertFalse(probe.active)
    }
  }

  func testRollbackFailureCannotReplaceWorkFailureAndGateIsReusable() async throws {
    let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
    let original = GraphTelemetryFailure()
    let provider = GraphTelemetryProvider(probe: probe, failure: failure, failing: "rollback")
    let context = context(provider, probe)
    do {
      _ = try await context.executeGraphSave(comment: "save graph") { _, session in
        try session.afterRollback { probe.append("rollback callback"); XCTAssertTrue(probe.active) }
        throw original
      }
      XCTFail("expected failure")
    } catch { XCTAssertTrue((error as? GraphTelemetryFailure) === original) }
    XCTAssertEqual(probe.events, ["start", "begin", "rollback", "rollback callback", "failure"])
    XCTAssertFalse(probe.active)
    let result = try await context.executeGraphSave(comment: "retry graph") { _, _ in 2 }
    XCTAssertEqual(result, 2)
    XCTAssertEqual(probe.events.suffix(4), ["start", "begin", "commit", "success"])
  }

  func testPostCommitFailuresDoNotRollbackOrLeaveOpenRoot() async throws {
    for phase in ["callback", "audit"] {
      let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
      let provider = GraphTelemetryProvider(probe: probe, failure: failure)
      let audit = GraphTelemetryAudit(probe: probe, provider: provider, failure: failure, fail: phase == "audit")
      let context = context(provider, probe, audit)
      do {
        _ = try await context.executeGraphSave(comment: "save graph") { invocation, session in
          if phase == "callback" { try session.afterCommit { throw failure } }
          _ = try await invocation.execute(Self.mutation())
          return 1
        }
        XCTFail("expected delivery failure")
      } catch {
        guard let committed = error as? GraphCommittedError else { return XCTFail("wrong committed error") }
        XCTAssertEqual(committed.causes.count, 1)
        XCTAssertTrue((committed.causes.first as? GraphTelemetryFailure) === failure)
      }
      XCTAssertFalse(probe.events.contains("rollback"))
      XCTAssertEqual(probe.events.last, "failure")
      XCTAssertTrue(probe.events.contains("audit"))
      XCTAssertFalse(probe.active)
      _ = try await context.executeGraphSave(comment: "next graph") { _, _ in 2 }
      XCTAssertEqual(probe.events.last, "success")
    }
  }

  func testRejectedNestedRootDoesNotCreateAnotherOperation() async throws {
    let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
    let provider = GraphTelemetryProvider(probe: probe, failure: failure)
    let context = context(provider, probe)
    _ = try await context.executeGraphSave(comment: "outer graph") { invocation, _ in
      do {
        _ = try await invocation.executeGraphSave(comment: "nested graph") { _, _ in 1 }
        XCTFail("must reject independent nested root")
      } catch { }
      XCTAssertTrue(probe.active)
      return 2
    }
    XCTAssertEqual(probe.roots.count, 1)
    XCTAssertEqual(probe.events, ["start", "begin", "commit", "success"])
  }

  func testNoopTelemetryPreservesGraphResult() async throws {
    let probe = GraphTelemetryProbe(), failure = GraphTelemetryFailure()
    let provider = GraphTelemetryProvider(probe: probe, failure: failure)
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, runtimeTelemetry: NoopRuntimeTelemetry())
    let result = try await context.executeGraphSave(comment: "disabled telemetry") { _, _ in 9 }
    XCTAssertEqual(result, 9)
    XCTAssertTrue(probe.roots.isEmpty)
    XCTAssertEqual(probe.events, ["begin", "commit"])
  }

  private func context(_ provider: GraphTelemetryProvider, _ probe: GraphTelemetryProbe,
    _ audit: GraphTelemetryAudit? = nil) -> UserContext {
    UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit, runtimeTelemetry: probe)
  }

  private static func mutation() -> Mutation {
    Mutation(kind: .create, entity: EntityDescriptor(name: "Task", table: "task_data",
      properties: [PropertyDescriptor(name: "id", type: .int, isID: true)]),
      values: ["id": .int(1)], auditReason: "create task")
  }
}

private final class GraphTelemetryFailure: Error, @unchecked Sendable {}

private final class GraphTelemetryProbe: RuntimeTelemetry, @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = [], storedRoots: [RuntimeOperation] = []
  private var depth = 0
  var active: Bool { lock.withLock { depth > 0 } }
  var events: [String] { lock.withLock { storedEvents } }
  var roots: [RuntimeOperation] { lock.withLock { storedRoots } }
  func append(_ value: String) { lock.withLock { storedEvents.append(value) } }
  func withOperation<Result: Sendable>(_ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result) async rethrows -> Result {
    guard operation.name == "graph.save" else { return try await body() }
    lock.withLock { depth += 1; storedRoots.append(operation); storedEvents.append("start") }
    defer { lock.withLock { depth -= 1 } }
    do {
      let result = try await body()
      _ = completion(result); append("success")
      return result
    } catch { append("failure"); throw error }
  }
  func withSynchronousOperation<Result>(_ operation: RuntimeOperation,
    completion: (Result) -> [String: RuntimeTelemetryValue], _ body: () throws -> Result) rethrows -> Result {
    try body()
  }
  func flush() async {}
  func shutdown() async {}
}

private actor GraphTelemetryProvider: QueryExecutor, GraphTransactionExecutor {
  let probe: GraphTelemetryProbe, failure: GraphTelemetryFailure, failing: String?
  private(set) var committed = false
  init(probe: GraphTelemetryProbe, failure: GraphTelemetryFailure, failing: String? = nil) {
    self.probe = probe; self.failure = failure; self.failing = failing
  }
  private func phase(_ name: String) throws { probe.append(name); if failing == name { throw failure } }
  func beginGraphTransaction() async throws { committed = false; try phase("begin") }
  func commitGraphTransaction() async throws { try phase("commit"); committed = true }
  func rollbackGraphTransaction() async throws { try phase("rollback") }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "probe") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    probe.append("mutation"); return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
}

private actor GraphTelemetryAudit: AuditSink {
  let probe: GraphTelemetryProbe, provider: GraphTelemetryProvider, failure: GraphTelemetryFailure, fail: Bool
  init(probe: GraphTelemetryProbe, provider: GraphTelemetryProvider,
    failure: GraphTelemetryFailure, fail: Bool = false) {
    self.probe = probe; self.provider = provider; self.failure = failure; self.fail = fail
  }
  func record(_ event: AuditEvent) async throws {
    let committed = await provider.committed
    XCTAssertTrue(committed)
    XCTAssertTrue(probe.active)
    probe.append("audit")
    if fail { throw failure }
  }
}
