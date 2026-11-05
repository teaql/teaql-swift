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
  for (id, scope, code, amount, active) in [
    (1, 7, "KEEP-001", 100, true), (2, 7, "KEEP-002", 200, true),
    (3, 7, "KEEP-003", 300, true), (4, 8, "KEEP-004", 400, true),
    (5, 7, "DROP-005", 500, true), (6, 7, "KEEP-006", 600, false)
  ] {
    _ = try await service.execute(Mutation(kind: .create, entity: descriptor, id: .int(Int64(id)),
      values: ["scope": .int(Int64(scope)), "referenceCode": .string(code), "amount": .decimal(Decimal(amount)),
        "active": .bool(active), "date": .calendarDate("2026-10-11")], auditReason: "seed generated scalar search counterexamples"))
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

@Test func generatedCalendarDateSearchMatchesCalendarStorageAcrossOperators() async throws {
  let descriptor = EntityDescriptor(name: "CalendarProbe", table: "calendar_probe", properties: [
    .init(name: "id", type: .int, isID: true), .init(name: "version", type: .int, isVersion: true),
    .init(name: "scope", type: .int), .init(name: "when", column: "calendar_date", type: .date, nullable: true),
    .init(name: "instant", type: .timestamp),
  ])
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
    querySQLLogEnabled: false, mutationSQLLogEnabled: false)
  try await context.ensureSchema(RuntimeModule(name: "calendar-probe", entities: [descriptor]))
  for (id, scope, value) in [(1, 7, TeaQLValue.calendarDate("2024-02-28")), (2, 7, .calendarDate("2024-02-29")),
    (3, 7, .calendarDate("2024-03-01")), (4, 8, .calendarDate("2024-02-29")), (5, 7, .null)] {
    _ = try await service.execute(Mutation(kind: .create, entity: descriptor, id: .int(Int64(id)),
      values: ["scope": .int(Int64(scope)), "when": value, "instant": .timestamp(1792488600125 + Int64(id - 2))],
      auditReason: "seed canonical calendar storage and a scope counterexample"))
  }
  let models = ["CalendarProbe": GeneratedSearchModel(model: SearchModel(fields: ["when": "date", "calendar_date": "date", "instant": "timestamp"]),
    queryFields: ["when": "when", "calendar_date": "when", "instant": "instant"])]
  var original = SelectQuery(entity: descriptor); original.filter = .equal("scope", .int(7)); original.limit = 10
  original.orderBy = [OrderBy("id", .ascending)]; original.comment = "Load scoped calendar probes"; original.purpose = "Compare actual SQLite Date predicate outcomes"
  let cases: [(String, [Int64])] = [
    (#"{"$eq":"2024-02-29"}"#, [2]), (#"{"$ne":"2024-02-29"}"#, [1, 3]),
    (#"{"$gt":"2024-02-29"}"#, [3]), (#"{"$gte":"2024-02-29"}"#, [2, 3]),
    (#"{"$lt":"2024-02-29"}"#, [1]), (#"{"$lte":"2024-02-29"}"#, [1, 2]),
    (#"{"$in":["2024-02-28","2024-02-29"]}"#, [1, 2]), (#"{"$notIn":["2024-02-29"]}"#, [1, 3]),
    (#"{"$in":[]}"#, []), (#"{"$notIn":[]}"#, [1, 2, 3, 5]), (#"null"#, [5]), (#"{"$ne":null}"#, [1, 2, 3]),
  ]
  for field in ["when", "calendar_date"] {
    for (predicate, expected) in cases {
      let result = try DynamicSearch.mergeGeneratedScalar(original, source: "{\"filter\":{\"\(field)\":\(predicate)}}", models: models)
      let rows = try await context.execute(result.query)
      #expect(rows.records.compactMap { $0["id"]?.int64Value } == expected)
      #expect(original.filter == .equal("scope", .int(7)))
      #expect(original.orderBy == [OrderBy("id", .ascending)])
    }
  }
  let instant = try DynamicSearch.mergeGeneratedScalar(original, source: #"{"filter":{"instant":1792488600125}}"#, models: models)
  let rows = try await context.execute(instant.query)
  #expect(rows.records.compactMap { $0["id"]?.int64Value } == [2])
  #expect(rows.records.first?["when"] == .calendarDate("2024-02-29"))
}
