import XCTest
import TeaQLCore
import TeaQLSQLite

/// Exact count is a physical SELECT, not an unobserved pagination side channel.
final class CountTraceIntegrationTests: XCTestCase {
  private func entity(_ table: String = "count_trace") -> EntityDescriptor {
    EntityDescriptor(name: "CustomerOrder", table: table, properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ], auditMaskFields: ["name"])
  }

  private func query(_ entity: EntityDescriptor) -> SelectQuery {
    var query = SelectQuery(entity: entity)
    query.filter = .equal("name", .string("COUNT-PRIVATE-CANARY"))
    query.orderBy = [OrderBy("id", .descending)]
    query.offset = 1; query.limit = 1; query.projection = ["id"]
    query.comment = "count COUNT-PRIVATE-CANARY matching orders"
    query.purpose = "show the COUNT-PRIVATE-CANARY filtered total"
    return query
  }

  func testCountRetainsIntentAndSafePhysicalSQLWithoutPagination() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let descriptor = entity(), evidence = SQLExecutionEvidenceStore()
    let text = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: text)
    try await context.ensureSchema(RuntimeModule(name: "count trace", entities: [descriptor]))
    for id in 1...3 {
      _ = try await context.execute(Mutation(kind: .create, entity: descriptor,
        values: ["id": .int(Int64(id)), "name": .string(id < 3 ? "COUNT-PRIVATE-CANARY" : "excluded")],
        auditReason: "seed count trace"))
    }
    await evidence.enableAll()
    let beforeText = await text.snapshot().count
    let request = query(descriptor)
    let total = try await context.count(request)
    XCTAssertEqual(total, 2)
    XCTAssertEqual(request.offset, 1); XCTAssertEqual(request.limit, 1)
    XCTAssertEqual(request.comment, "count COUNT-PRIVATE-CANARY matching orders")
    let entries = await evidence.snapshot()
    XCTAssertEqual(entries.count, 1, "a successful physical COUNT must be observable")
    guard let entry = entries.first else { return }
    XCTAssertEqual(entry.executionOutcome, "success"); XCTAssertEqual(entry.resultCount, 1)
    XCTAssertEqual(entry.operation, .select)
    XCTAssertEqual(entry.tracePath.map(\.kind), ["operation", "request", "provider", "sql"])
    XCTAssertEqual(entry.tracePath.map(\.name), ["CustomerOrder", "CustomerOrder", "sqlite", "select"])
    XCTAssertEqual(entry.comment, "count [REDACTED] matching orders")
    XCTAssertEqual(entry.purpose, "show the [REDACTED] filtered total")
    XCTAssertTrue(entry.parameterizedSQL.contains("COUNT(*)"))
    XCTAssertFalse(entry.parameterizedSQL.contains("LIMIT")); XCTAssertFalse(entry.parameterizedSQL.contains("ORDER BY"))
    XCTAssertEqual(entry.parameters, [.string("CO****************RY")])
    XCTAssertFalse(entry.debugSQL.contains("COUNT-PRIVATE-CANARY"))
    let lines = Array(await text.snapshot().dropFirst(beforeText))
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].contains("COUNT(*)")); XCTAssertFalse(lines[0].contains("COUNT-PRIVATE-CANARY"))
  }

  func testCountFailureKeepsSafeSQLAndOriginalErrorType() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let evidence = SQLExecutionEvidenceStore(), text = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: text)
    do {
      _ = try await context.count(query(entity("absent_count_table")))
      XCTFail("absent table must fail")
    } catch is SQLiteError { }
    let entries = await evidence.snapshot()
    XCTAssertEqual(entries.count, 1, "failed COUNT must retain its attempted physical SQL")
    guard let entry = entries.first else { return }
    XCTAssertEqual(entry.executionOutcome, "failure"); XCTAssertNil(entry.resultCount)
    XCTAssertEqual(entry.tracePath.first?.name, "CustomerOrder")
    XCTAssertEqual(entry.tracePath.last?.name, "select")
    XCTAssertEqual(entry.comment, "count [REDACTED] matching orders")
    XCTAssertEqual(entry.purpose, "show the [REDACTED] filtered total")
    XCTAssertTrue(entry.debugSQL.contains("COUNT(*)")); XCTAssertFalse(entry.debugSQL.contains("COUNT-PRIVATE-CANARY"))
    let lines = await text.snapshot()
    XCTAssertEqual(lines.count, 1)
  }

  func testCountMasksDescendantIntentAndDoesNotRetainItsProvenance() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let descriptor = entity(), evidence = SQLExecutionEvidenceStore()
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
      diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
    try await context.ensureSchema(RuntimeModule(name: "count provenance", entities: [descriptor]))
    var request = SelectQuery(entity: descriptor)
    request.limit = 1; request.comment = "count COUNT-PRIVATE-CANARY ancestors"
    request.purpose = "verify derived count privacy"
    let child = query(entity("absent_descendant_not_executed"))
    request.relationQuery("children", localKey: "id", foreignKey: "id", query: child)
    await evidence.enableAll()
    let total = try await context.count(request)
    XCTAssertEqual(total, 0)
    var entries = await evidence.snapshot()
    XCTAssertEqual(entries.count, 1)
    guard let counted = entries.first else { return }
    XCTAssertEqual(counted.comment, "count [REDACTED] ancestors")
    XCTAssertTrue(counted.parameters.isEmpty, "count strips eager loading but keeps invocation privacy")
    request.relations = []; request.comment = "independent COUNT-PRIVATE-CANARY literal"
    _ = try await context.count(request)
    entries = await evidence.snapshot()
    XCTAssertEqual(entries.last?.comment, request.comment, "a later independent request must not inherit hidden values")
  }

  func testCountLoggingOffStillValidatesIntentAndCapturesTelemetry() async throws {
    let provider = try SQLiteDataService(path: ":memory:")
    let descriptor = entity(), evidence = SQLExecutionEvidenceStore()
    let text = TextDiagnosticSQLLogSink(writer: { _ in })
    let context = UserContext(queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
      diagnosticSQLLogSink: text, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
    try await context.ensureSchema(RuntimeModule(name: "count logs off", entities: [descriptor]))
    await evidence.enableAll()
    var request = query(descriptor); request.comment = nil
    do { _ = try await context.count(request); XCTFail("missing intent accepted") }
    catch let error as RequestIntentError {
      XCTAssertEqual(error.code, "REQUEST_COMMENT_REQUIRED"); XCTAssertEqual(error.field, "comment")
    }
    let rejectedEntries = await evidence.snapshot()
    XCTAssertTrue(rejectedEntries.isEmpty)
    request.comment = "valid filtered count"
    let total = try await context.count(request)
    let entries = await evidence.snapshot(), lines = await text.snapshot()
    XCTAssertEqual(total, 0)
    XCTAssertEqual(entries.count, 1)
    XCTAssertTrue(lines.isEmpty)
  }
}
