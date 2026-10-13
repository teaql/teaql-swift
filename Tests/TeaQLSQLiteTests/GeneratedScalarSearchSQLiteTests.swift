import Foundation
import TeaQLCore
import TeaQLSQLite
import Testing

@Test func generatedScalarSearchCompilesAllSiblingsAndRetainsScopeInSQLite() async throws {
  let descriptor = EntityDescriptor(name: "Invoice", table: "generated_search_invoice", properties: [
    .init(name: "id", type: .int, isID: true), .init(name: "version", type: .int, isVersion: true),
    .init(name: "scope", type: .int), .init(name: "referenceCode", column: "reference_code", type: .string),
    .init(name: "amount", type: .decimal), .init(name: "active", type: .bool), .init(name: "date", type: .date)
  ])
  let database = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-generated-search-\(UUID()).sqlite")
  let service = try SQLiteDataService(path: database.path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
    querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  try await context.ensureSchema(RuntimeModule(name: "generated-search", entities: [descriptor]))
  let date = ISO8601DateFormatter().date(from: "2026-10-11T00:00:00Z")!
  for (id, scope, code, amount, active) in [
    (1, 7, "KEEP-001", 100, true), (2, 7, "KEEP-002", 200, true),
    (3, 7, "KEEP-003", 300, true), (4, 8, "KEEP-004", 400, true),
    (5, 7, "DROP-005", 500, true), (6, 7, "KEEP-006", 600, false)
  ] {
    _ = try await service.execute(Mutation(kind: .create, entity: descriptor, id: .int(Int64(id)),
      values: ["scope": .int(Int64(scope)), "referenceCode": .string(code), "amount": .decimal(Decimal(amount)),
        "active": .bool(active), "date": .date(date)], auditReason: "seed generated scalar search counterexamples"))
  }
  var query = SelectQuery(entity: descriptor)
  query.filter = .equal("scope", .int(7)); query.projection = ["id", "referenceCode"]
  query.limit = 10; query.comment = "load scoped invoices"; query.purpose = "verify generated scalar search"
  let models: [String: GeneratedSearchModel] = ["Invoice": GeneratedSearchModel(model: SearchModel(fields: [
    "reference_code": "string", "referenceCode": "string", "amount": "decimal", "active": "boolean", "date": "date"
  ]), queryFields: ["reference_code": "referenceCode", "referenceCode": "referenceCode", "amount": "amount", "active": "active", "date": "date"])]
  let result = try DynamicSearch.mergeGeneratedScalar(query, source:
    #"{"filter":{"reference_code":{"$contains":"KEEP"},"amount":{"$gte":"200"},"active":true,"date":"2026-10-11","gone":"secret"},"orderBy":[{"field":"referenceCode","direction":"desc"}]}"#,
    models: models, warn: { _ in })
  let rows = try await context.execute(result.query).records
  #expect(rows.map { $0["id"]?.int64Value } == [3, 2])
  #expect(result.warnings.count == 1)
  #expect(query.filter == .equal("scope", .int(7)))
  #expect(query.orderBy.isEmpty)
}
