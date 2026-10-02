import CSQLite
import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private func installReadbackTrigger(path: String, update: Bool) throws {
  var db: OpaquePointer?
  guard sqlite3_open(path, &db) == SQLITE_OK else { throw TeaQLError.execution("fixture open failed") }
  defer { sqlite3_close(db) }
  let event = update ? "UPDATE" : "INSERT"
  let sql = "CREATE TRIGGER vanish AFTER \(event) ON readback_customer WHEN NEW.id = 777 BEGIN DELETE FROM readback_customer WHERE id = NEW.id; END"
  guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
    throw TeaQLError.execution("fixture trigger failed")
  }
}

@Test(arguments: [MutationKind.create, .update, .delete], 0..<4)
func missingReadbackRetainsWriteAndSafeIntent(kind: MutationKind, mode: Int) async throws {
  let graph = mode & 1 != 0
  let logs = mode & 2 != 0
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-readback-\(UUID()).sqlite").path
  let service = try SQLiteDataService(path: path)
  let entity = EntityDescriptor(name: "ReadbackCustomer", table: "readback_customer", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "password", type: .string),
  ], auditMaskFields: ["name"])
  let evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  var context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence, diagnosticSQLLogSink: sink)
  try await context.ensureSchema(RuntimeModule(name: "readback", entities: [entity]))
  let values: TeaQLRecord = ["id": .int(777), "name": .string("Riverside"), "password": .string("PASSWORD-CANARY")]
  if kind != .create {
    _ = try await context.execute(Mutation(kind: .create, entity: entity, values: values, auditReason: "what: prepare fixture"))
  }
  await evidence.enableAll()
  let before = await sink.snapshot().count
  try installReadbackTrigger(path: path, update: kind != .create)
  context.mutationSQLLogEnabled = logs
  if graph { try await service.beginGraphTransaction() }
  do {
    _ = try await context.execute(Mutation(kind: kind, entity: entity, id: kind == .create ? nil : .int(777),
      values: kind == .delete ? [:] : values, expectedVersion: kind == .create ? nil : 1,
      auditReason: kind == .delete ? "what: delete fixture" : "what: persist Riverside PASSWORD-CANARY"))
    Issue.record("missing snapshot unexpectedly succeeded")
  } catch let error as TeaQLError {
    guard case .execution = error else { Issue.record("original error type lost"); return }
  }
  if graph { try await service.rollbackGraphTransaction() }
  let entries = await evidence.snapshot()
  #expect(entries.count == 2)
  #expect(entries.first?.affectedRows == 1)
  #expect(entries.first?.executionOutcome == "success")
  #expect(entries.last?.operation == .select)
  #expect(entries.last?.comment == entries.last?.auditReason)
  #expect(entries.last?.purpose == "verify the persisted mutation result")
  #expect(entries.last?.executionOutcome == "success")
  #expect(entries.last?.resultCount == 0)
  #expect(entries.last?.tracePath.last?.name == "select")
  #expect(entries.allSatisfy { $0.tracePath.filter { $0.kind == "sql" }.count == 1 })
  #expect(entries.last?.tracePath.filter { $0.kind == "sql" }.first?.comment == "")
  #expect(entries.allSatisfy { $0.sqlOmissionReason == nil })
  #expect(!entries.description.contains("Riverside"))
  #expect(!entries.description.contains("PASSWORD-CANARY"))
  let lines = await sink.snapshot()
  #expect(lines.count == before + (logs ? 2 : 0))
  #expect(!lines.joined().contains("Riverside"))
  #expect(!lines.joined().contains("PASSWORD-CANARY"))
  var query = SelectQuery(entity: entity)
  query.limit = 2; query.comment = "what: inspect rollback"; query.purpose = "why: verify readback failure isolation"
  let rows = try await context.execute(query).records
  #expect(rows.count == (kind == .create ? 0 : 1))
  if kind != .create { #expect(rows.first?["version"] == .int(1)) }
  #expect(try await service.auditEvents().count == (kind == .create ? 0 : 1))
  _ = try await context.execute(Mutation(kind: .create, entity: entity,
    values: ["id": .int(778), "name": .string("Lakeside"), "password": .string("PASSWORD-CANARY")],
    auditReason: "what: prove connection reusable"))
}

@Test
func multipleReadbackRowsAreRejectedRatherThanTakingFirst() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-multiple-readback-\(UUID()).sqlite").path
  var db: OpaquePointer?
  #expect(sqlite3_open(path, &db) == SQLITE_OK)
  defer { sqlite3_close(db) }
  // Deliberately malformed external schema: model identity is not unique in DB.
  #expect(sqlite3_exec(db, "CREATE TABLE duplicate_customer(id INTEGER, version INTEGER, name TEXT); CREATE TRIGGER duplicate_row AFTER INSERT ON duplicate_customer BEGIN INSERT INTO duplicate_customer VALUES(NEW.id, NEW.version, NEW.name); END", nil, nil, nil) == SQLITE_OK)
  let service = try SQLiteDataService(path: path)
  let entity = EntityDescriptor(name: "DuplicateCustomer", table: "duplicate_customer", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ], auditMaskFields: ["name"])
  let evidence = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, telemetrySink: evidence,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "multiple-readback", entities: [entity]))
  do {
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(1), "name": .string("Riverside")], auditReason: "what: create Riverside"))
    Issue.record("multiple rows unexpectedly accepted")
  } catch let error as TeaQLError {
    guard case .execution(let message) = error else { Issue.record("wrong error"); return }
    #expect(message.contains("found 2"))
  }
  let entries = await evidence.snapshot()
  #expect(entries.count == 2)
  #expect(entries.last?.resultCount == 2)
  #expect(entries.last?.executionOutcome == "success")
  #expect(!entries.description.contains("Riverside"))
  var query = SelectQuery(entity: entity)
  query.limit = 10; query.comment = "what: read malformed fixture"; query.purpose = "why: verify rollback"
  #expect(try await context.execute(query).records.isEmpty)
}
