import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

/// Capture actual SQLite rows without changing requests, results or trace frames.
private actor FacetRowCapture: QueryExecutor, QueryIntentProvenanceExecutor {
  let service: SQLiteDataService
  private var results: [QueryResult] = []
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    let result = try await service.execute(request)
    results.append(result)
    return result
  }
  func snapshot() -> [QueryResult] { results }
  func queryIntentProvenance(_ request: QueryRequest) async throws -> SQLExecutionMetadata {
    try await service.queryIntentProvenance(request)
  }
}

private func facetEntity(_ name: String, fields: [PropertyDescriptor] = [], privateFields: [String] = []) -> EntityDescriptor {
  EntityDescriptor(name: name, table: "facet_trace_" + name.lowercased(), properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ] + fields, auditMaskFields: privateFields)
}

private func verifyFacetTrace(loadedRelation: Bool, logging: Bool) async throws {
  let payment = facetEntity("Payment", fields: [PropertyDescriptor(name: "customerOrder", type: .int)])
  let order = facetEntity("CustomerOrder", fields: [PropertyDescriptor(name: "platform", type: .int)])
  let platform = facetEntity("Platform", fields: [PropertyDescriptor(name: "organization", type: .int)])
  let organization = facetEntity("Organization", fields: [PropertyDescriptor(name: "name", type: .string)],
    privateFields: ["name"])
  let service = try SQLiteDataService(path: ":memory:")
  let seed = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
    querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  try await seed.ensureSchema(RuntimeModule(name: "nested-facet-trace", entities: [payment, order, platform, organization]))
  let canary = "FACET-PRIVATE-CANARY"
  let rows: [(EntityDescriptor, TeaQLRecord)] = [
    (organization, ["id": .int(100), "name": .string(canary)]),
    (organization, ["id": .int(200), "name": .string("other organization")]),
    (platform, ["id": .int(10), "organization": .int(100)]),
    (platform, ["id": .int(20), "organization": .int(200)]),
    (order, ["id": .int(1), "platform": .int(10)]),
    (order, ["id": .int(2), "platform": .int(10)]),
    (order, ["id": .int(3), "platform": .int(20)]),
    (payment, ["id": .int(1), "customerOrder": .int(1)]),
    (payment, ["id": .int(2), "customerOrder": .int(2)]),
  ]
  for (entity, values) in rows {
    _ = try await seed.execute(Mutation(kind: .create, entity: entity, values: values,
      auditReason: "seed native facet trace"))
  }
  let capture = FacetRowCapture(service), evidence = SQLExecutionEvidenceStore()
  let text = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: capture, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: text,
    querySQLLogEnabled: logging)
  var organizations = SelectQuery(entity: organization)
  organizations.filter = .equal("name", .string(canary))
  organizations.orderBy = [OrderBy("id", .ascending)]
  var platforms = SelectQuery(entity: platform)
  platforms.orderBy = [OrderBy("id", .ascending)]
  platforms.facets = [FacetRequest(name: "organizations", relationName: "organization", query: organizations)]
  var orders = SelectQuery(entity: order)
  orders.filter = .inList("id", [.int(1), .int(2)])
  orders.orderBy = [OrderBy("id", .ascending)]
  orders.facets = [FacetRequest(name: "platforms", relationName: "platform", query: platforms)]
  var query = orders
  if loadedRelation {
    query = SelectQuery(entity: payment)
    query.orderBy = [OrderBy("id", .ascending)]
    query.relationQuery("orderEntity", localKey: "customerOrder", foreignKey: "id", many: false,
      query: orders, traceName: "customerOrder")
  }
  query.limit = 2
  query.comment = "inspect \(canary) facets"
  query.purpose = "verify nested facet counts and materialization"
  let original = query
  let result = try await context.execute(query)
  #expect(result.records.count == 2)
  if loadedRelation {
    for (index, row) in result.records.enumerated() {
      guard case .object(let loaded) = row["orderEntity"] else { Issue.record("loaded order is missing"); continue }
      #expect(loaded["id"] == .int(Int64(index + 1)))
      #expect(loaded["platform"] == .int(10))
    }
  } else {
    let values = try #require(result.facets["platforms"])
    #expect(values.map { $0["id"] } == [.int(10), .int(20)])
    #expect(values.map { $0["count"] } == [.int(2), .int(0)])
    // Nested Facet metadata must survive decoration of its parent's rows.
    let nested = values.facets["organizations"]
    #expect(nested?.map { $0["id"] } == [.int(100)])
    #expect(nested?.map { $0["count"] } == [.int(1)])
  }
  let facts = await evidence.snapshot(), actualRows = await capture.snapshot()
  let offset = loadedRelation ? 1 : 0
  #expect(facts.count == 5 + offset && actualRows.count == facts.count)
  // These are provider-returned membership and materialization rows, not
  // synthetic SQL or fixture-supplied metadata. Counts are computed from them.
  #expect(actualRows[offset + 1].records.map { $0["platform"] } == [.int(10), .int(10)])
  #expect(actualRows[offset + 2].records.map { $0["id"] } == [.int(10), .int(20)])
  #expect(actualRows[offset + 3].records.map { $0["organization"] } == [.int(100), .int(200)])
  #expect(actualRows[offset + 4].records.map { $0["id"] } == [.int(100)])
  let prefix = loadedRelation ? ["customerOrder"] : []
  let detailPrefix = loadedRelation ? ["Payment.customerOrder"] : []
  let routes = (loadedRelation ? [[]] : []) + [prefix, prefix,
    prefix + ["platform"], prefix + ["platform"], prefix + ["platform", "organization"]]
  let details = (loadedRelation ? [[]] : []) + [detailPrefix, detailPrefix,
    detailPrefix + ["CustomerOrder.platform"], detailPrefix + ["CustomerOrder.platform"],
    detailPrefix + ["CustomerOrder.platform", "Platform.organization"]]
  for (index, fact) in facts.enumerated() {
    #expect(fact.tracePath.map(\.kind) == ["operation", "request"]
      + Array(repeating: "relation", count: routes[index].count) + ["provider", "sql"])
    #expect(fact.tracePath.prefix(2).map(\.name) == [query.entity.name, query.entity.name])
    #expect(fact.tracePath.filter { $0.kind == "relation" }.map(\.name) == routes[index])
    #expect(fact.tracePath.filter { $0.kind == "relation" }.map(\.comment) == details[index])
    #expect(fact.tracePath.map(\.level) == Array(fact.tracePath.indices))
    #expect(fact.tracePath.suffix(2).map(\.name) == ["sqlite", "select"])
    #expect(fact.executionOutcome == "success" && fact.resultCount == actualRows[index].records.count)
    #expect(fact.comment == "inspect [REDACTED] facets" && fact.purpose == query.purpose)
  }
  #expect(!facts.description.contains(canary))
  #expect((await text.snapshot()).count == (logging ? facts.count : 0))
  #expect(query == original && orders.tracePath.isEmpty && platforms.tracePath.isEmpty && organizations.tracePath.isEmpty)
  var independent = SelectQuery(entity: platform)
  independent.limit = 1; independent.comment = "independent \(canary)"; independent.purpose = "verify invocation isolation"
  _ = try await context.execute(independent)
  let last = try #require(await evidence.snapshot().last)
  #expect(last.comment == independent.comment && last.tracePath.filter { $0.kind == "relation" }.isEmpty)
}

@Test(arguments: [false, true])
func swiftNestedFacetsRetainSQLOriginAndCounts(logging: Bool) async throws {
  try await verifyFacetTrace(loadedRelation: false, logging: logging)
}

@Test(arguments: [false, true])
func swiftLoadedRelationFacetsRetainAncestorsAndMembership(logging: Bool) async throws {
  try await verifyFacetTrace(loadedRelation: true, logging: logging)
}
