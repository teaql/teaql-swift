import Foundation
import OpenTelemetryApi
import TeaQLCore
import TeaQLSQLite
import XCTest
@testable import TeaQLStandardTelemetry

final class GraphSDKTests: XCTestCase {
  func testRealSQLiteWritesShareOneGraphTraceAndNextQueryIsIndependent() async throws {
    let capture = SDKCapture(), telemetry = try Self.telemetry(capture)
    let provider = try SQLiteDataService(path: ":memory:"), audit = GraphSDKAudit()
    let entity = Self.entity()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit,
      querySQLLogEnabled: false, mutationSQLLogEnabled: false, runtimeTelemetry: telemetry)
    try await context.ensureSchema(RuntimeModule(name: "graph SDK test", entities: [entity]))
    _ = try await context.executeGraphSave(comment: "save private graph") { invocation, _ in
      for id in 1...2 {
        _ = try await invocation.execute(Mutation(kind: .create, entity: entity,
          values: ["id": .int(Int64(id)), "name": .string("GRAPH-SECRET-CANARY")],
          auditReason: "create GRAPH-SECRET-CANARY object"))
      }
      return 2
    }
    let auditCount = await audit.count
    XCTAssertEqual(auditCount, 2)
    var query = SelectQuery(entity: entity)
    query.limit = 2; query.comment = "inspect persisted graph"; query.purpose = "verify commit"
    let result = try await context.execute(query)
    XCTAssertEqual(result.records.count, 2)
    await telemetry.flush()
    let roots = capture.spans.filter { $0.attributes["teaql.operation.name"] == .string("graph.save") }
    XCTAssertEqual(roots.count, 1)
    let root = try XCTUnwrap(roots.first)
    let sql = capture.spans.filter { $0.attributes["teaql.provider.execution"] == .string("statement") }
    let writes = sql.filter { $0.traceId == root.traceId }
    XCTAssertEqual(writes.count, 4) // Two real writes plus two readbacks.
    for span in writes {
      var parent = span
      var visited = Set<SpanId>()
      while parent.spanId != root.spanId {
        guard visited.insert(parent.spanId).inserted else { XCTFail("cyclic span ancestry"); break }
        guard let next = capture.spans.first(where: { $0.spanId == parent.parentSpanId && $0.traceId == root.traceId })
        else { XCTFail("physical statement lost graph ancestry"); break }
        parent = next
      }
    }
    let reads = sql.filter { $0.attributes["teaql.operation.name"] == .string("sqlite.select") }
    XCTAssertEqual(reads.count, 1)
    XCTAssertNotEqual(reads.first?.traceId, root.traceId)
    let diagnostics = capture.logs.filter { $0.body == .string("TeaQL SQL execution") }
    XCTAssertEqual(diagnostics.count, 5)
    for log in diagnostics {
      XCTAssertFalse(String(describing: log.attributes).contains("GRAPH-SECRET-CANARY"))
      XCTAssertEqual(log.attributes["teaql.sql.log_mode"], .string("masked"))
      XCTAssertNotNil(sql.first { $0.spanId == log.spanContext?.spanId && $0.traceId == log.spanContext?.traceId })
    }
    XCTAssertTrue(capture.logs.contains {
      $0.spanContext?.spanId == root.spanId && $0.attributes["teaql.operation.outcome"] == .string("success")
    })
    await telemetry.shutdown()
  }

  func testRealSQLiteRollbackEmitsFailureAndAllowsIndependentRetry() async throws {
    let capture = SDKCapture(), telemetry = try Self.telemetry(capture)
    let provider = try SQLiteDataService(path: ":memory:"), audit = GraphSDKAudit()
    let entity = Self.entity()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit,
      querySQLLogEnabled: false, mutationSQLLogEnabled: false, runtimeTelemetry: telemetry)
    try await context.ensureSchema(RuntimeModule(name: "graph SDK rollback", entities: [entity]))
    do {
      _ = try await context.executeGraphSave(comment: "fail one graph") { invocation, _ in
        for _ in 0..<2 {
          _ = try await invocation.execute(Mutation(kind: .create, entity: entity,
            values: ["id": .int(1), "name": .string("GRAPH-SECRET-CANARY")], auditReason: "create object"))
        }
        return 1
      }
      XCTFail("duplicate key must fail")
    } catch { XCTAssertTrue(error is SQLiteError) }
    let auditsAfterFailure = await audit.count
    XCTAssertEqual(auditsAfterFailure, 0)
    var query = SelectQuery(entity: entity)
    query.limit = 2; query.comment = "inspect rolled back graph"; query.purpose = "verify rollback"
    let empty = try await context.execute(query)
    XCTAssertTrue(empty.records.isEmpty)
    _ = try await context.executeGraphSave(comment: "retry graph") { invocation, _ in
      try await invocation.execute(Mutation(kind: .create, entity: entity,
        values: ["id": .int(1), "name": .string("safe")], auditReason: "retry object"))
    }
    let auditsAfterRetry = await audit.count
    XCTAssertEqual(auditsAfterRetry, 1)
    await telemetry.flush()
    let roots = capture.spans.filter { $0.attributes["teaql.operation.name"] == .string("graph.save") }
    XCTAssertEqual(roots.count, 2)
    XCTAssertEqual(Set(roots.map(\.traceId)).count, 2)
    let completions = capture.logs.filter { log in roots.contains { $0.spanId == log.spanContext?.spanId } }
    XCTAssertEqual(completions.count, 2)
    XCTAssertEqual(Set(completions.compactMap { log -> String? in
      if case .string(let value) = log.attributes["teaql.operation.outcome"] { return value }; return nil
    }), ["failure", "success"])
    XCTAssertTrue(capture.logs.contains { $0.attributes["teaql.sql.outcome"] == .string("failure") })
    XCTAssertFalse(String(describing: capture.logs.map(\.attributes)).contains("GRAPH-SECRET-CANARY"))
    await telemetry.shutdown()
  }

  private static func entity() -> EntityDescriptor {
    EntityDescriptor(name: "GraphEntry", table: "graph_entry_data", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ], auditMaskFields: ["name"])
  }
  private static func telemetry(_ capture: SDKCapture) throws -> StandardTelemetry {
    try StandardTelemetry(configuration: .read([
      TelemetryStartupConfiguration.enabledVariable: "true",
      TelemetryStartupConfiguration.serviceVariable: "swift-graph-sdk-test",
      TelemetryStartupConfiguration.endpointVariable: "http://localhost:4318",
    ]), traceExporter: capture, metricExporter: capture, logExporter: capture)
  }
}

private actor GraphSDKAudit: AuditSink {
  private(set) var count = 0
  func record(_ event: AuditEvent) { count += 1 }
}
