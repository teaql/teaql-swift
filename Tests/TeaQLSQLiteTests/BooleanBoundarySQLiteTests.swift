import CSQLite
import Foundation
import TeaQLCore
import Testing
@testable import TeaQLSQLite

private let booleanStoredEntity = EntityDescriptor(name: "BooleanStoredBoundary", table: "boolean_stored_boundary", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "requiredFlag", modelName: "required_flag", column: "required_flag", type: .bool),
  PropertyDescriptor(name: "optionalFlag", modelName: "optional_flag", column: "optional_flag", type: .bool, nullable: true),
  PropertyDescriptor(name: "observedAt", column: "observed_at", type: .timestamp, nullable: true),
  PropertyDescriptor(name: "version", type: .int, isVersion: true),
])

private func booleanQuery() -> SelectQuery {
  var query = SelectQuery(entity: booleanStoredEntity)
  query.projection = ["id", "requiredFlag", "optionalFlag", "version"]; query.limit = 10
  query.comment = "Inspect a bounded Boolean result"
  query.purpose = "Keep Boolean hydration and predicates consistent"
  return query
}

private func booleanContext(_ service: SQLiteDataService) -> UserContext {
  UserContext(queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
    querySQLLogEnabled: false, mutationSQLLogEnabled: false)
}

@Test func booleanBoundarySQLiteDirectMutationsRejectWrongCarriersAtomically() async throws {
  let service = try SQLiteDataService(path: ":memory:"), context = booleanContext(service)
  try await context.ensureSchema(RuntimeModule(name: "boolean-mutations", entities: [booleanStoredEntity]))
  _ = try await service.execute(Mutation(kind: .create, entity: booleanStoredEntity,
    values: ["id": .int(1), "required_flag": .bool(false), "optional_flag": .null], auditReason: "Seed a valid Boolean control"))
  for kind in [MutationKind.create, .update] {
    for value: TeaQLValue in [.int(0), .int(1), .int(2), .double(0.5), .string("PRIVATE-BOOLEAN-MARKER"), .data(Data([1]))] {
      do {
        _ = try await service.execute(Mutation(kind: kind, entity: booleanStoredEntity, id: .int(kind == .create ? 2 : 1),
          values: ["required_flag": value], expectedVersion: kind == .update ? 1 : nil,
          auditReason: "Reject an invalid direct provider mutation"))
        Issue.record("Direct provider admitted an invalid Boolean carrier")
      } catch let error as CheckException {
        #expect(error.violations.first?.location.modelPath == "required_flag")
        #expect(!String(describing: error).contains("PRIVATE-BOOLEAN-MARKER"))
      }
      let rows = try await context.execute(booleanQuery()).records
      #expect(rows.count == 1 && rows.first?["requiredFlag"] == .bool(false) && rows.first?["version"] == .int(1))
    }
  }
}

@Test func booleanBoundarySQLiteCorruptStorageFailsPreciselyAndProjectionStaysBounded() async throws {
  for field in ["required_flag", "optional_flag"] {
    for literal in ["2", "-1", "9223372036854775807", "0.5", "'PRIVATE-BOOLEAN-MARKER'", "X'01'"] {
      let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-boolean-\(UUID().uuidString).sqlite").path
      defer { try? FileManager.default.removeItem(atPath: path) }
      let service = try SQLiteDataService(path: path), context = booleanContext(service)
      try await context.ensureSchema(RuntimeModule(name: "boolean-legacy", entities: [booleanStoredEntity]))
      var connection: OpaquePointer?
      guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else { throw TeaQLError.execution("Cannot open the owned Boolean corruption fixture") }
      // Only test-only corruption bypasses audited mutation APIs.
      let required = field == "required_flag" ? literal : "1", optional = field == "optional_flag" ? literal : "NULL"
      let status = sqlite3_exec(connection, "INSERT INTO boolean_stored_boundary(id,required_flag,optional_flag,version) VALUES(1,\(required),\(optional),1)", nil, nil, nil)
      sqlite3_close(connection); #expect(status == SQLITE_OK)
      do {
        _ = try await service.executeDiagnosed(QueryRequest(query: booleanQuery()))
        Issue.record("Corrupt Boolean storage escaped typed hydration")
      } catch let failure as SQLExecutionFailure {
        let error = try #require(failure.cause as? CheckException)
        #expect(error.violations.first?.ruleID == "invalid_type")
        #expect(error.violations.first?.location.modelPath == field)
        #expect(!String(describing: error).contains("PRIVATE-BOOLEAN-MARKER"))
        #expect(failure.diagnostics.last?.metadata.executionOutcome == "failure")
      }
      var ids = booleanQuery(); ids.projection = ["id", "version"]
      let rows = try await context.execute(ids).records
      #expect(rows.count == 1 && rows.first?["requiredFlag"] == nil && rows.first?["optionalFlag"] == nil)
      var count = ids; count.projection = []; count.aggregates = [QueryAggregate(.count, field: "*", alias: "required_flag")]
      #expect(try await context.execute(count).records == [["required_flag": .int(1)]])
    }
  }
}

@Test func booleanBoundarySQLiteValidStatesAndAggregateAliasesKeepTheirOwnDomains() async throws {
  let service = try SQLiteDataService(path: ":memory:"), context = booleanContext(service)
  try await context.ensureSchema(RuntimeModule(name: "boolean-controls", entities: [booleanStoredEntity]))
  for id: Int64 in 1...3 {
    _ = try await context.execute(Mutation(kind: .create, entity: booleanStoredEntity,
      values: ["id": .int(id), "required_flag": .bool(id != 1), "optional_flag": id == 3 ? .null : .bool(id == 2)],
      auditReason: "Seed true false and nullable Boolean states"))
  }
  var query = booleanQuery(); query.filter = .equal("required_flag", .bool(true))
  #expect(try await context.execute(query).records.count == 2)
  query.filter = .isNull("optional_flag")
  #expect(try await context.execute(query).records.count == 1)
  for alias in ["required_flag", "requiredFlag", "observed_at"] {
    query.filter = nil; query.projection = []; query.aggregates = [QueryAggregate(.count, field: "*", alias: alias)]
    #expect(try await context.execute(query).records == [[alias: .int(3)]])
  }
  query.aggregates = [QueryAggregate(.min, field: "requiredFlag", alias: "_minimum")]
  query.filter = .equal("id", .int(99))
  #expect(try await context.execute(query).records == [["_minimum": .null]])
}
