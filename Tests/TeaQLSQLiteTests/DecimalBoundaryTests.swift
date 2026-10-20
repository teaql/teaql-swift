import CSQLite
import Foundation
import TeaQLCore
import Testing

@testable import TeaQLSQLite

private let boundaryEntity = EntityDescriptor(
  name: "DecimalBoundary", table: "decimal_boundary",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "amount", type: .decimal),
    PropertyDescriptor(name: "note", type: .string, nullable: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])

private func boundaryQuery(aggregate: Bool = false) -> SelectQuery {
  var query = SelectQuery(entity: boundaryEntity)
  query.projection = ["id", "amount", "note"]
  if aggregate { query.aggregates = [QueryAggregate(.sum, field: "amount", alias: "total")] }
  query.limit = 10
  query.comment = "read exact Decimal boundary fixture"
  query.purpose = "reject truncation at the SQLite C boundary"
  return query
}

@Test func sqliteDecimalBoundaryPreservesEmbeddedNulInOrdinaryText() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-nul-text-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "boundary", entities: [boundaryEntity]))
  let note = "left\0中文-right"
  _ = try await service.execute(Mutation(kind: .create, entity: boundaryEntity, id: .int(1),
    values: ["amount": .decimal(Decimal(string: "3.50")!), "note": .string(note)],
    auditReason: "persist ordinary text without truncating its UTF-8 bytes"))
  let row = try await context.execute(boundaryQuery()).records.first
  #expect(row?["note"] == .string(note))
  var equality = boundaryQuery()
  equality.filter = .equal("note", .string(note))
  #expect(try await context.execute(equality).records.first?["note"] == .string(note))
}

@Test(arguments: ["3.50\0junk", "3.50\0"])
func sqliteDecimalBoundaryRejectsNulSuffixBeforeMutation(_ text: String) async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-nul-mutation-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "boundary", entities: [boundaryEntity]))
  do {
    _ = try await service.execute(Mutation(kind: .create, entity: boundaryEntity, id: .int(1),
      values: ["amount": .string(text)], auditReason: "reject a malformed Decimal lexeme"))
    Issue.record("Malformed Decimal with a NUL suffix was silently accepted")
  } catch {
    #expect(!String(describing: error).contains(text))
  }
  #expect(try await context.execute(boundaryQuery()).records.isEmpty)
}

@Test(arguments: [false, true], ["332e3530006a756e6b", "332e353000"])
func sqliteDecimalBoundaryRejectsCorruptStoredNul(_ aggregate: Bool, _ hex: String) async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-nul-storage-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  // An external unchecked table is deliberately corrupt. It must not be
  // repaired by silently interpreting only a prefix as the Decimal value.
  var raw: OpaquePointer?
  #expect(sqlite3_open(path, &raw) == SQLITE_OK)
  guard let raw else { throw TeaQLError.execution("unable to open test database") }
  let ddl = "CREATE TABLE decimal_boundary(id INTEGER, amount TEXT, note TEXT, version INTEGER); "
    + "INSERT INTO decimal_boundary VALUES (1, CAST(X'\(hex)' AS TEXT), NULL, 1)"
  let status = sqlite3_exec(raw, ddl, nil, nil, nil)
  sqlite3_close(raw)
  #expect(status == SQLITE_OK)
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 })
  do {
    _ = try await context.execute(boundaryQuery(aggregate: aggregate))
    Issue.record("Corrupt stored Decimal was silently shortened at NUL")
  } catch {
    #expect(!String(describing: error).contains("junk"))
  }
}
