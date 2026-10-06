import CSQLite
import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private actor LedgerReadbackAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func snapshot() -> [AuditEvent] { events }
}

private actor LedgerCommandProbe: GraphTransactionExecutor {
  let service: SQLiteDataService
  let audit: LedgerReadbackAudit
  private var commands: [Mutation] = []
  private var prematureAudit = false
  init(service: SQLiteDataService, audit: LedgerReadbackAudit) {
    self.service = service; self.audit = audit
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request.mutation)
    let result = try await service.execute(request)
    if !(await audit.snapshot()).isEmpty { prematureAudit = true }
    return result
  }
  func beginGraphTransaction() async throws { try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func snapshot() -> ([Mutation], Bool) { (commands, prematureAudit) }
}

private func ledgerReadbackEntity(_ name: String, table: String, masked: Bool = false) -> EntityDescriptor {
  EntityDescriptor(name: name, table: table, properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ], auditMaskFields: masked ? ["name"] : [])
}

/// Explicit native ledger input; the observer delegates and never adds trace frames.
@Test(arguments: [false, true])
func swiftLedgerOverrideAndUnannotatedSiblingReachRealSinks(logs: Bool) async throws {
  let root = ledgerReadbackEntity("CustomerOrder", table: "ledger_order")
  let payment = ledgerReadbackEntity("Payment", table: "ledger_payment", masked: true)
  let sibling = ledgerReadbackEntity("OrderItem", table: "ledger_item")
  let entities = [root, payment, sibling]
  let service = try SQLiteDataService(path: ":memory:")
  let audit = LedgerReadbackAudit(), evidence = SQLExecutionEvidenceStore()
  let probe = LedgerCommandProbe(service: service, audit: audit)
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  var context = UserContext(queryExecutor: service, mutationExecutor: probe,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: evidence,
    diagnosticSQLLogSink: sink)
  context.mutationSQLLogEnabled = logs; context.querySQLLogEnabled = logs
  try await context.ensureSchema(RuntimeModule(name: "ledger sinks", entities: entities))
  let secret = "LEDGER-PRIVATE-NAME", reason = "save graph LEDGER-PRIVATE-NAME"
  let keys = entities.map { EntityKey(entity: $0.name, id: .int(1)) }
  let ledger = EntityRoot()
  let explicitRoot = try TraceScopeToken(key: keys[0], reason: reason)
  let explicitPayment = try TraceScopeToken(parent: explicitRoot, key: keys[1],
    reason: "ledger authorize LEDGER-PRIVATE-NAME")
  let complete = explicitPayment.recover()
  ledger.setTraceChain(keys[1], chain: complete)
  let results = try await context.executeGraphSave(comment: reason) { context, session in
    let rootScope = try session.scope(key: keys[0])
    let paymentFallback = try session.scope(key: keys[1], localReason: "unused payment fallback", parent: rootScope)
    let siblingFallback = try session.scope(key: keys[2], parent: rootScope)
    let scopes = [rootScope, paymentFallback, siblingFallback]
    let commands = entities.indices.map { index in
      Mutation(kind: .create, entity: entities[index],
        values: ["id": .int(1), "name": .string(index == 1 ? secret : "public-\(index)")],
        auditReason: session.intent.comment,
        mutationLineage: ledger.traceChain(keys[index], fallback: scopes[index]))
    }
    for command in commands { _ = try context.preflightMutation(command) }
    var results: [MutationResult] = []
    for command in commands { results.append(try await context.execute(command)) }
    #expect(await audit.snapshot().isEmpty)
    return results
  }
  let (commands, prematureAudit) = await probe.snapshot()
  let facts = await evidence.snapshot(), events = await audit.snapshot()
  try #require(commands.count == 3 && results.count == 3 && facts.count == 6 && events.count == 3)
  #expect(!prematureAudit)
  #expect(commands.map(\.entity.name) == entities.map(\.name))
  #expect(commands.map(\.auditReason) == [reason, reason, reason])
  #expect(commands[1].mutationLineage == complete)
  #expect(commands[0].mutationLineage == commands[2].mutationLineage)
  #expect(commands[2].mutationLineage?.map(\.name) == [root.name])
  #expect(commands[2].mutationLineage?.map(\.comment) == [reason])
  #expect(commands[2].mutationLineage?.map(\.entityID) == [.int(1)])
  #expect(ledger.traceChain(keys[1], fallback: explicitRoot) == complete)
  let expectedNames = [[root.name], [root.name, payment.name], [root.name]]
  let expectedComments = [["save graph [REDACTED]"],
    ["save graph [REDACTED]", "ledger authorize [REDACTED]"], ["save graph [REDACTED]"]]
  for index in entities.indices {
    let raw = try #require(results[index].metadata)
    #expect(results[index].affectedRows == 1 && results[index].persistedRecord?["id"] == .int(1))
    #expect(results[index].persistedRecord?["name"] == commands[index].values["name"])
    #expect(raw.statements.map(\.operation) == [.insert, .select])
    #expect(raw.statements.first?.parameters == [.int(1), commands[index].values["name"]!, .int(1)])
    #expect(raw.statements.last?.parameters == [.int(1)])
    #expect(raw.statements.allSatisfy { $0.mutationLineage == commands[index].mutationLineage })
    let write = facts[index * 2], read = facts[index * 2 + 1]
    #expect(write.operation == .insert && write.affectedRows == 1 && write.executionOutcome == "success")
    #expect(read.operation == .select && read.resultCount == 1 && read.executionOutcome == "success")
    #expect(write.tracePath.map(\.kind) == ["operation", "entity", "provider", "sql"])
    #expect(write.tracePath.map(\.name) == [root.name, entities[index].name, "sqlite", "insert"])
    #expect(read.tracePath.map(\.name) == [root.name, root.name, "sqlite", "select"])
    #expect(write.tracePath.last?.name == "insert" && read.tracePath.last?.name == "select")
    #expect(read.tracePath.map(\.kind) == ["operation", "request", "provider", "sql"])
    #expect(write.mutationLineage.map(\.name) == expectedNames[index])
    #expect(write.mutationLineage.map(\.comment) == expectedComments[index])
    #expect(write.mutationLineage.map(\.entityID) == Array(repeating: .int(1), count: expectedNames[index].count))
    #expect(read.mutationLineage == write.mutationLineage)
    #expect(events[index].entity == entities[index].name && events[index].entityID == .int(1))
    #expect(events[index].operation == .create)
    #expect(events[index].mutationLineage == write.mutationLineage)
    #expect(events[index].reason == "save graph [REDACTED]")
  }
  #expect(try await service.auditEvents().count == 3)
  let lines = await sink.snapshot()
  #expect(lines.count == (logs ? 6 : 0))
  #expect(!lines.joined().contains(secret) && !facts.description.contains(secret))
  #expect(!events.description.contains("unused payment fallback"))
}

private func installReadbackCollationSchema(path: String) throws {
  var db: OpaquePointer?
  guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw TeaQLError.execution("fixture open failed") }
  defer { sqlite3_close(db) }
  // This connection can declare the external schema. The provider connection
  // deliberately lacks the collation: INSERT does not compare id, SELECT does.
  guard sqlite3_create_collation(db, "fixture_readback_only", SQLITE_UTF8, nil,
    { _, _, _, _, _ in 0 }) == SQLITE_OK else { throw TeaQLError.execution("fixture collation failed") }
  guard sqlite3_exec(db,
    "CREATE TABLE throwing_readback(id INTEGER COLLATE fixture_readback_only, version INTEGER, name TEXT)",
    nil, nil, nil) == SQLITE_OK else { throw TeaQLError.execution("fixture schema failed") }
}

@Test(arguments: [false, true])
func swiftReadbackProviderSQLFailureRetainsWriteAndRollsBack(logs: Bool) async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("teaql-sql-readback-\(UUID()).sqlite").path
  try installReadbackCollationSchema(path: path)
  let broken = ledgerReadbackEntity("ReadbackPayment", table: "throwing_readback", masked: true)
  let healthy = ledgerReadbackEntity("HealthyPayment", table: "healthy_readback", masked: true)
  let service = try SQLiteDataService(path: path)
  let audit = LedgerReadbackAudit(), evidence = SQLExecutionEvidenceStore()
  let sink = TextDiagnosticSQLLogSink(writer: { _ in })
  var context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: evidence,
    diagnosticSQLLogSink: sink)
  context.mutationSQLLogEnabled = logs; context.querySQLLogEnabled = logs
  try await context.ensureSchema(RuntimeModule(name: "readback SQL error", entities: [broken, healthy]))
  let secret = "READBACK-PRIVATE-NAME", reason = "persist READBACK-PRIVATE-NAME"
  do {
    try await context.executeGraphSave(comment: reason) { context, session in
      let scope = try session.scope(key: EntityKey(entity: broken.name, id: .int(301)))
      _ = try await context.execute(Mutation(kind: .create, entity: broken,
        values: ["id": .int(301), "name": .string(secret)], auditReason: session.intent.comment,
        mutationLineage: scope.recover()))
    }
    Issue.record("provider readback SQL unexpectedly succeeded")
  } catch let error as SQLiteError {
    guard case let .sqlite(code, message, sql) = error else { Issue.record("wrong SQLite error"); return }
    #expect(code == SQLITE_ERROR)
    #expect(message.contains("no such collation sequence: fixture_readback_only"))
    #expect(sql == "SELECT \"id\", \"version\", \"name\" FROM \"throwing_readback\" WHERE \"id\" = ?")
  }
  let facts = await evidence.snapshot()
  #expect(facts.count == 2)
  let write = try #require(facts.first), read = try #require(facts.last)
  #expect(write.operation == .insert && write.executionOutcome == "success" && write.affectedRows == 1)
  #expect(read.operation == .select && read.executionOutcome == "failure" && read.resultCount == nil)
  #expect(read.resultSummary == "readback failed; row count unknown")
  #expect(write.tracePath.map(\.kind) == ["operation", "entity", "provider", "sql"])
  #expect(write.tracePath.map(\.name) == [broken.name, broken.name, "sqlite", "insert"])
  #expect(read.tracePath.map(\.name) == [broken.name, broken.name, "sqlite", "select"])
  #expect(write.tracePath.last?.name == "insert" && read.tracePath.last?.name == "select")
  #expect(read.tracePath.map(\.kind) == ["operation", "request", "provider", "sql"])
  #expect(facts.allSatisfy { $0.tracePath.filter { $0.kind == "sql" }.count == 1 })
  #expect(write.mutationLineage.map(\.name) == [broken.name])
  #expect(write.mutationLineage.map(\.entityID) == [.int(301)])
  #expect(write.mutationLineage.map(\.comment) == ["persist [REDACTED]"])
  #expect(read.mutationLineage == write.mutationLineage)
  #expect(read.comment == "persist [REDACTED]" && read.auditReason == "persist [REDACTED]")
  #expect(read.purpose == "verify the persisted mutation result")
  #expect(await audit.snapshot().isEmpty)
  #expect(try await service.auditEvents().isEmpty)
  let lines = await sink.snapshot()
  #expect(lines.count == (logs ? 2 : 0))
  #expect(!lines.joined().contains(secret) && !facts.description.contains(secret))
  // A full scan requires no collation, and verifies the successful INSERT rolled back.
  var query = SelectQuery(entity: broken)
  query.limit = 2; query.comment = "inspect rolled back readback"; query.purpose = "verify atomicity"
  #expect(try await context.execute(query).records.isEmpty)
  let nextReason = "independent READBACK-PRIVATE-NAME"
  let next = try await context.execute(Mutation(kind: .create, entity: healthy,
    values: ["id": .int(302), "name": .string("new-private-value")], auditReason: nextReason))
  #expect(next.affectedRows == 1 && next.persistedRecord?["id"] == .int(302))
  let nextEvents = await audit.snapshot(), nextFacts = Array(await evidence.snapshot().suffix(2))
  #expect(nextEvents.count == 1 && nextEvents[0].entity == healthy.name && nextEvents[0].entityID == .int(302))
  #expect(nextEvents[0].reason == nextReason)
  #expect(nextEvents[0].mutationLineage?.map(\.name) == [healthy.name])
  #expect(nextFacts.map(\.executionOutcome) == ["success", "success"])
  #expect(nextFacts.allSatisfy { $0.auditReason == nextReason })
  #expect(nextFacts.allSatisfy { !$0.mutationLineage.contains { $0.name == broken.name } })
  #expect(try await service.auditEvents().count == 1)
}
