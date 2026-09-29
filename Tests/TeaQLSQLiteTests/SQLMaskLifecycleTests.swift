import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private func lifecycleEntity(table: String = "customer_data") -> EntityDescriptor {
  EntityDescriptor(name: "Customer", table: table, properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "address", type: .string),
    PropertyDescriptor(name: "password", type: .string),
  ], auditMaskFields: ["name"])
}

@Test
func sqliteUnknownFieldPolicyKeepsTypedRowCounts() async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  // Older generated descriptors do not declare auditMaskFields. Unknown
  // parameters are masked, but their value must not erase typed row counts.
  let entity = EntityDescriptor(name: "Customer", table: "customer_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  try await context.ensureSchema(RuntimeModule(name: "unknown-policy", entities: [entity]))
  _ = try await context.execute(Mutation(kind: .create, entity: entity, id: .int(1),
    values: ["id": .int(1), "version": .int(1), "name": .string("Riverside")],
    auditReason: "create customer 1"))
  let written = await evidence.snapshot()
  #expect(written.count == 1)
  #expect(written.first?.auditReason == "create customer [REDACTED]")
  #expect(written.first?.affectedRows == 1)
  #expect(written.first?.resultSummary == "1 rows affected")

  var query = SelectQuery(entity: entity)
  query.filter = .equal("id", .int(1))
  query.limit = 1; query.comment = "read customer"; query.purpose = "verify typed count"
  let result = try await context.execute(query)
  #expect(result.records.count == 1)
  let logText = await sink.snapshot().joined(separator: "\n")
  #expect(logText.contains("1 rows affected"))
  #expect(logText.contains("1 rows returned"))
  #expect(!logText.contains("create customer 1"))
}

@Test(arguments: ["query", "insert", "update", "delete"])
func sqliteFailureProducesMaskedDiagnostic(operation: String) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "lifecycle", entities: [lifecycleEntity()]))
  let missing = lifecycleEntity(table: "missing_customer_data")
  do {
    if operation == "query" {
      var query = SelectQuery(entity: missing)
      query.filter = .equal("name", .string("Riverside"))
      query.limit = 1; query.comment = "what: inspect customer"; query.purpose = "why: failure regression"
      _ = try await context.execute(query)
    } else {
      let kind: MutationKind = operation == "insert" ? .create : operation == "update" ? .update : .delete
      _ = try await context.execute(Mutation(kind: kind, entity: missing, id: .int(1),
        values: ["id": .int(1), "name": .string("Riverside"), "address": .string("1 Runtime Road"), "password": .string("PASSWORD-CANARY")],
        expectedVersion: 1, auditReason: "what: failure mutation 1"))
    }
    Issue.record("missing table unexpectedly succeeded")
  } catch let error as SQLiteError {
    if case .sqlite(let code, _, _) = error { #expect(code != 0) }
    else { Issue.record("wrong SQLite error") }
  }
  let entries = await evidence.snapshot()
  #expect(entries.count == 1)
  if operation == "query" {
    #expect(entries.first?.tracePath.map(\.level) == [0, 1, 2, 3])
    #expect(entries.first?.comment == "what: inspect customer")
    #expect(entries.first?.purpose == "why: failure regression")
  } else {
    #expect(entries.first?.auditReason == "what: failure mutation [REDACTED]")
  }
  let text = await sink.snapshot().joined(separator: "\n")
  #expect(text.contains("outcome=failure"))
  #expect(!text.contains("Riverside"))
  #expect(!text.contains("PASSWORD-CANARY"))
  #expect(!text.contains("0 rows affected"))
  if operation != "delete" { #expect(text.contains("Ri*****de")) }
  if operation == "insert" || operation == "update" { #expect(text.contains("1 Runtime Road")) }
}

@Test(arguments: [MutationKind.update, MutationKind.delete])
func optimisticConflictHasSafeDiagnostic(kind: MutationKind) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  let entity = lifecycleEntity()
  try await context.ensureSchema(RuntimeModule(name: "lifecycle", entities: [entity]))
  do {
    _ = try await context.execute(Mutation(kind: kind, entity: entity, id: .int(123),
      values: ["name": .string("Riverside")], expectedVersion: 1, auditReason: "what: conflict regression 123"))
    Issue.record("missing versioned entity unexpectedly succeeded")
  } catch let error as TeaQLError {
    guard case .optimisticLock = error else { Issue.record("wrong error"); return }
  }
  let conflictEvidence = await evidence.snapshot()
  #expect(conflictEvidence.count == 1)
  #expect(conflictEvidence.first?.auditReason == "what: conflict regression [REDACTED]")
  let text = await sink.snapshot().joined(separator: "\n")
  // SQL executed successfully but matched no expected version; the mutation
  // still throws optimisticLock. Do not equate SQL success with business success.
  #expect(text.contains("outcome=success"))
  #expect(text.contains("0 rows affected")) // known zero, unlike failed SQLite execution
  #expect(!text.contains("Riverside"))
}

@Test(arguments: [false, true])
func duplicateInsertPreservesOriginalDataAndAudit(graph: Bool) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  let entity = lifecycleEntity()
  try await context.ensureSchema(RuntimeModule(name: "lifecycle", entities: [entity]))
  let insert = Mutation(kind: .create, entity: entity,
    values: ["id": .int(1), "name": .string("Riverside"), "address": .string("1 Runtime Road"), "password": .string("PASSWORD-CANARY")],
    auditReason: "what: create lifecycle fixture")
  _ = try await context.execute(insert)
  await evidence.enableAll()
  if graph { try await service.beginGraphTransaction() }
  do {
    _ = try await context.execute(insert)
    Issue.record("duplicate unexpectedly succeeded")
  } catch let error as SQLiteError {
    guard case .sqlite(let code, _, _) = error else { Issue.record("wrong error"); return }
    #expect(code == 19)
  }
  if graph { try await service.rollbackGraphTransaction() }
  let entries = await evidence.snapshot()
  #expect(entries.count == 1)
  #expect(entries.first?.executionOutcome == "failure")
  #expect(entries.first?.affectedRows == nil)
  var query = SelectQuery(entity: entity)
  query.limit = 1; query.comment = "what: read after failure"; query.purpose = "why: verify rollback"
  let result = try await context.execute(query)
  #expect(result.records.first?["name"] == .string("Riverside"))
  #expect(result.records.first?["password"] == .string("PASSWORD-CANARY"))
  #expect(try await service.auditEvents().count == 1)
  let text = await sink.snapshot().joined(separator: "\n")
  #expect(!text.contains("Riverside") && !text.contains("PASSWORD-CANARY"))
  #expect(text.contains("1 Runtime Road") && text.contains("Ri*****de"))
}

@Test(arguments: [false, true])
func failureLogSwitchRemainsEffective(mutation: Bool) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  var context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  context.querySQLLogEnabled = false; context.mutationSQLLogEnabled = false
  try await context.ensureSchema(RuntimeModule(name: "lifecycle", entities: [lifecycleEntity()]))
  let entity = lifecycleEntity(table: "missing_customer")
  do {
    if mutation {
      _ = try await context.execute(Mutation(kind: .create, entity: entity,
        values: ["id": .int(1), "name": .string("Riverside")], auditReason: "what: disabled log"))
    } else {
      var query = SelectQuery(entity: entity)
      query.limit = 1; query.comment = "what: missing table"; query.purpose = "why: disabled log"
      _ = try await context.execute(query)
    }
    Issue.record("missing table unexpectedly succeeded")
  } catch is SQLiteError {}
  #expect(await sink.snapshot().isEmpty)
  // Existing Swift contract keeps explicitly installed telemetry evidence even
  // when text diagnostics are disabled. It must still be projected.
  #expect(await evidence.snapshot().count == 1)
  #expect(!(await evidence.snapshot().description).contains("Riverside"))
}

@Test(arguments: [false, true])
func directProviderPreservesErrorType(mutation: Bool) async throws {
  let service = try SQLiteDataService(path: ":memory:")
  let entity = lifecycleEntity()
  do {
    if mutation {
      _ = try await service.execute(Mutation(kind: .delete, entity: entity, id: .int(1),
        expectedVersion: 1, auditReason: "what: direct SPI failure"))
    } else {
      var query = SelectQuery(entity: entity)
      query.limit = 1; query.comment = "what: direct SPI failure"; query.purpose = "why: error compatibility"
      _ = try await service.execute(query)
    }
    Issue.record("missing table unexpectedly succeeded")
  } catch is SQLiteError {}
}
