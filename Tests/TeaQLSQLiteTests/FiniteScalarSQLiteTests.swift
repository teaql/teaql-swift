import CSQLite
import Foundation
import TeaQLCore
import Testing
@testable import TeaQLSQLite

private let finiteStoredEntity = EntityDescriptor(name: "FiniteStoredProbe", table: "finite_stored_probe", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "amount", type: .double, nullable: true),
  PropertyDescriptor(name: "version", type: .int, isVersion: true),
])

private func finiteStoredQuery() -> SelectQuery {
  var query = SelectQuery(entity: finiteStoredEntity)
  query.projection = ["id", "amount", "version"]
  query.limit = 10
  query.comment = "inspect bounded floating-point rows"
  query.purpose = "verify SQLite finite bind and readback boundaries"
  return query
}

@Test func finiteMutationSQLiteDirectProviderRejectsNaNAndInfinityWithoutChangingRows() async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "finite-storage", entities: [finiteStoredEntity]))
  _ = try await service.execute(Mutation(kind: .create, entity: finiteStoredEntity, id: .int(1),
    values: ["amount": .double(-7.5)], auditReason: "seed a valid negative number"))
  for kind in [MutationKind.create, .update] {
    for value in [Double.nan, .infinity, -.infinity] {
      do {
        _ = try await service.execute(Mutation(kind: kind, entity: finiteStoredEntity,
          id: .int(kind == .create ? 2 : 1), values: ["amount": .double(value)],
          expectedVersion: kind == .update ? 1 : nil, auditReason: "reject a non-finite provider input"))
        Issue.record("SQLite accepted a non-finite input")
      } catch {
        let cause = (error as? SQLExecutionFailure)?.cause ?? error
        #expect(String(describing: cause).contains("non-finite"))
      }
      let rows = try await context.execute(finiteStoredQuery()).records
      #expect(rows.count == 1)
      #expect(rows.first?["amount"] == .double(-7.5))
      #expect(rows.first?["version"] == .int(1))
    }
  }
}

@Test(arguments: ["1e999", "-1e999"])
func finiteMutationSQLiteRejectsCorruptLegacyInfinityInsteadOfReturningIt(_ literal: String) async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-finite-\(UUID().uuidString).sqlite").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let context = UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 })
  try await context.ensureSchema(RuntimeModule(name: "finite-legacy", entities: [finiteStoredEntity]))
  var handle: OpaquePointer?
  #expect(sqlite3_open(path, &handle) == SQLITE_OK)
  guard let handle else { throw TeaQLError.execution("Unable to open the owned legacy fixture") }
  defer { sqlite3_close(handle) }
  // Deliberately bypass the provider: represent an old/corrupt database, not
  // an application mutation path that ought to pass current validation.
  #expect(sqlite3_exec(handle, "INSERT INTO finite_stored_probe(id,amount,version) VALUES(1,\(literal),1)", nil, nil, nil) == SQLITE_OK)
  do {
    _ = try await context.execute(finiteStoredQuery())
    Issue.record("Legacy Infinity escaped as a normal typed value")
  } catch {
    let cause = (error as? SQLExecutionFailure)?.cause ?? error
    #expect(String(describing: cause).contains("non-finite"))
  }
}
