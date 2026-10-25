import CSQLite
import Foundation
import TeaQLCore
import TeaQLSQL
import Testing

@testable import TeaQLSQLite

@Test func sqliteDecimalKeepsExactValueThroughModeledMutationAndQuery() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-exact-decimal-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(
    queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let entity = EntityDescriptor(
    name: "ExactDecimal", table: "exact_decimal",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "amount", type: .decimal),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
  try await context.ensureSchema(RuntimeModule(name: "exact-decimal", entities: [entity]))
  try await context.ensureSchema(RuntimeModule(name: "exact-decimal", entities: [entity]))
  let exact = Decimal(string: "123456789012.3456789", locale: Locale(identifier: "en_US_POSIX"))!
  _ = try await service.execute(
    Mutation(
      kind: .create, entity: entity, id: .int(1),
      values: ["amount": .decimal(exact)], auditReason: "create exact Decimal fixture"))

  var query = SelectQuery(entity: entity)
  query.projection = ["id", "amount"]
  query.filter = .equal("amount", .decimal(exact))
  query.limit = 10
  query.comment = "load exact Decimal fixture"
  query.purpose = "verify precise SQLite binding and hydration"
  let rows = try await context.execute(query).records
  #expect(rows.count == 1)
  #expect(rows.first?["amount"] == .decimal(exact))
}

@Test func sqliteDecimalParserRejectsPartialAndRoundedInput() {
  #expect(parseExactDecimal("3.50") == Decimal(string: "3.5"))
  #expect(parseExactDecimal("1.2x") == nil)
  #expect(parseExactDecimal(" 3") == nil)
  #expect(parseExactDecimal("NaN") == nil)
  #expect(parseExactDecimal("12345678901234567890123456789012345678901234567890") == nil)
}

@Test func sqliteDecimalRejectsUnsafeExistingColumns() async throws {
  let entity = EntityDescriptor(
    name: "LegacyDecimal", table: "legacy_decimal",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "amount", type: .decimal),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
  for declaration in [
    "NUMERIC",
    "DECIMAL_TEXT",
    "DECIMAL_TEXT COLLATE TEAQL_DECIMAL",
    "DECIMAL_TEXT COLLATE TEAQL_DECIMAL /* CHECK (\"amount\" IS NULL OR teaql_decimal_valid(\"amount\")) */",
    "DECIMAL_TEXT COLLATE TEAQL_DECIMAL DEFAULT 'CHECK (\"amount\" IS NULL OR teaql_decimal_valid(\"amount\"))'",
  ] {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaql-swift-legacy-decimal-\(UUID().uuidString).db").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    guard let database else { continue }
    #expect(
      sqlite3_create_collation_v2(
        database, "TEAQL_DECIMAL", SQLITE_UTF8,
        nil, { _, _, _, _, _ in 0 }, nil) == SQLITE_OK)
    let sql =
      "CREATE TABLE legacy_decimal (id INTEGER PRIMARY KEY, amount \(declaration), version INTEGER)"
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let service = try SQLiteDataService(path: path)
    let context = UserContext(
      queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 })
    do {
      try await context.ensureSchema(RuntimeModule(name: "legacy-decimal", entities: [entity]))
      Issue.record("Unsafe existing \(declaration) column was accepted")
    } catch {
      #expect(String(describing: error).contains("SQLite Decimal column"))
    }
  }
}

@Test func sqliteDecimalOrdersAndSumsByNumericValue() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-decimal-aggregate-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(
    queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  let entity = EntityDescriptor(
    name: "DecimalAggregate", table: "decimal_aggregate",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "amount", type: .decimal),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
  try await context.ensureSchema(RuntimeModule(name: "decimal-aggregate", entities: [entity]))
  for (id, text) in [
    (1, "0.1"), (2, "0.2"), (3, "10"), (4, "2"), (5, "123456789012.3456789"),
  ] {
    let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
    _ = try await service.execute(
      Mutation(
        kind: .create, entity: entity,
        id: .int(Int64(id)), values: ["amount": .decimal(value)],
        auditReason: "seed exact Decimal aggregate"))
  }
  var ordered = SelectQuery(entity: entity)
  ordered.projection = ["amount"]
  ordered.orderBy = [OrderBy("amount", .ascending)]
  ordered.limit = 10
  ordered.comment = "order Decimal fixture"
  ordered.purpose = "verify numeric rather than text order"
  let orderedValues = try await context.execute(ordered).records.compactMap { $0["amount"] }
  #expect(
    orderedValues
      == ["0.1", "0.2", "2", "10", "123456789012.3456789"].map {
        .decimal(Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))!)
      })

  var range = ordered
  range.filter = .between(
    "amount", .decimal(Decimal(string: "2")!),
    .decimal(Decimal(string: "10")!))
  range.comment = "load Decimal numeric range"
  range.purpose = "verify between preserves numeric comparison"
  let rangeValues = try await context.execute(range).records.compactMap { $0["amount"] }
  #expect(rangeValues == ["2", "10"].map { .decimal(Decimal(string: $0)!) })

  var aggregate = SelectQuery(entity: entity)
  aggregate.aggregates = [
    QueryAggregate(.sum, field: "amount", alias: "total"),
    QueryAggregate(.min, field: "amount", alias: "minimum"),
    QueryAggregate(.max, field: "amount", alias: "maximum"),
    QueryAggregate(.count, field: "amount", alias: "items"),
  ]
  aggregate.comment = "sum Decimal fixture"
  aggregate.purpose = "verify exact numeric aggregate"
  let result = try await context.execute(aggregate).records.first
  #expect(result?["total"] == .decimal(Decimal(string: "123456789024.6456789")!))
  #expect(result?["minimum"] == .decimal(Decimal(string: "0.1")!))
  #expect(result?["maximum"] == .decimal(Decimal(string: "123456789012.3456789")!))
  #expect(result?["items"] == .int(5))
}
