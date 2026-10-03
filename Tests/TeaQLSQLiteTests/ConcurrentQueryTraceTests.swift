import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

/// Delegates unchanged requests to SQLite, then holds both physical root results.
/// No trace frames or expected metadata are inserted by this observer.
private actor PausedRootQueries: QueryExecutor {
  let service: SQLiteDataService
  private var roots: [QueryRequest] = []
  private var released = false
  init(_ service: SQLiteDataService) { self.service = service }
  func observedRoots() -> [QueryRequest] { roots }
  func release() { released = true }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    let result = try await service.execute(request)
    if request.query.entity.name == "QueryParent" {
      roots.append(request)
      while !released { try await Task.sleep(for: .milliseconds(1)) }
    }
    return result
  }
}

@Test(arguments: [false, true])
func swiftOverlappingQueriesKeepOwnedIntentThroughRealRelations(logging: Bool) async throws {
  let parent = EntityDescriptor(name: "QueryParent", table: "query_parent", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let child = EntityDescriptor(name: "QueryChild", table: "query_child", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "parent_id", type: .int),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let seed = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await seed.ensureSchema(RuntimeModule(name: "query-overlap", entities: [parent, child]))
  for id: Int64 in [1, 2] {
    _ = try await seed.execute(Mutation(kind: .create, entity: parent,
      values: ["id": .int(id)], auditReason: "seed query parent"))
    _ = try await seed.execute(Mutation(kind: .create, entity: child,
      values: ["id": .int(id + 10), "parent_id": .int(id)], auditReason: "seed query child"))
  }
  let executor = PausedRootQueries(service)
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: executor, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
    diagnosticSQLLogSink: sink, querySQLLogEnabled: logging)
  func query(_ id: Int64) -> SelectQuery {
    // Keep the correlation label separate from bound IDs: safe logs mask
    // matching bound values in intent, including numeric identifiers.
    let label = id == 1 ? "alpha" : "beta"
    var nested = SelectQuery(entity: child); nested.limit = 2
    var request = SelectQuery(entity: parent); request.limit = 1
    request.filter = .equal("id", .int(id))
    request.comment = "load graph \(label)"; request.purpose = "render graph \(label)"
    request.relationQuery("items", localKey: "id", foreignKey: "parent_id", many: true,
      query: nested, traceName: "children")
    return request
  }
  let firstQuery = query(1), secondQuery = query(2)
  let first = Task { try await context.execute(firstQuery) }
  let second = Task { try await context.execute(secondQuery) }
  // Bounded, cancellation-aware waiting: an early SQL failure cannot hang CI.
  defer { first.cancel(); second.cancel() }
  for _ in 0..<1_000 {
    if await executor.observedRoots().count == 2 { break }
    try await Task.sleep(for: .milliseconds(3))
  }
  let live = await executor.observedRoots()
  try #require(live.count == 2, "both root SQL results must be held before release")
  #expect(Set(live.map { $0.intent.comment }) == ["load graph alpha", "load graph beta"])
  for request in live {
    #expect(request.intent.purpose == request.intent.comment.replacingOccurrences(of: "load", with: "render"))
    #expect(request.query.tracePath.filter { $0.kind == "relation" }.isEmpty)
  }
  #expect(firstQuery.tracePath.isEmpty && secondQuery.tracePath.isEmpty)
  await executor.release()
  let results = try await [first.value, second.value]
  for (offset, result) in results.enumerated() {
    let id = Int64(offset + 1)
    let root = try #require(result.records.first)
    #expect(root["id"] == .int(id))
    guard case .array(let items) = root["items"], case .object(let item)? = items.first else {
      Issue.record("missing related row"); continue
    }
    #expect(items.count == 1 && item["id"] == .int(id + 10))
  }
  let facts = await evidence.snapshot()
  #expect(facts.count == 4)
  for label in ["alpha", "beta"] {
    let own = facts.filter { $0.comment == "load graph \(label)" }
    #expect(own.count == 2, "observed safe intents: \(facts.map { [$0.comment ?? "nil", $0.purpose ?? "nil"] })")
    for (depth, fact) in own.enumerated() {
      #expect(fact.purpose == "render graph \(label)" && fact.executionOutcome == "success")
      #expect(fact.tracePath.map(\.kind) == ["operation", "request"]
        + (depth == 0 ? [] : ["relation"]) + ["provider", "sql"])
      #expect(fact.tracePath.prefix(2).map(\.name) == ["QueryParent", "QueryParent"])
      #expect(fact.tracePath.filter { $0.kind == "relation" }.map(\.name) == (depth == 0 ? [] : ["children"]))
      #expect(fact.tracePath.last?.name == "select")
    }
  }
  #expect((await sink.snapshot()).count == (logging ? 4 : 0))
}
