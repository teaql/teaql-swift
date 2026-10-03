import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private actor BatchAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func snapshot() -> [AuditEvent] { events }
}

private actor BatchCommandProbe: GraphTransactionExecutor {
  let service: SQLiteDataService
  let audit: BatchAudit
  private var commands: [Mutation] = []
  private var prematureAudit = false
  init(service: SQLiteDataService, audit: BatchAudit) { self.service = service; self.audit = audit }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request.mutation)
    let result = try await service.execute(request)
    if !(await audit.snapshot()).isEmpty { prematureAudit = true }
    await Task.yield()
    return result
  }
  func beginGraphTransaction() async throws { try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { try await service.rollbackGraphTransaction() }
  func snapshot() -> ([Mutation], Bool) { (commands, prematureAudit) }
}

private func batchEntity() -> EntityDescriptor {
  EntityDescriptor(name: "School", table: "batch_school", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "privateMemo", modelName: "private_memo", type: .string, nullable: true),
  ], auditMaskFields: ["private_memo"])
}

@Test
func swiftBatchHasIndependentItemLineageAndSiblingPrivacyAtRealSinks() async throws {
  let entity = batchEntity(), service = try SQLiteDataService(path: ":memory:")
  let audit = BatchAudit(), sql = SQLExecutionEvidenceStore()
  let probe = BatchCommandProbe(service: service, audit: audit)
  let context = UserContext(queryExecutor: service, mutationExecutor: probe,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "batch", entities: [entity]))
  let root = "process batch PRIVATE-MEMO-CANARY"
  let originals = [
    Mutation(kind: .create, entity: entity, values: ["id": .int(101), "name": .string("first")],
      auditReason: root),
    Mutation(kind: .create, entity: entity, values: ["id": .int(102), "name": .string("second"),
      "privateMemo": .string("PRIVATE-MEMO-CANARY")], auditReason: "inspect PRIVATE-MEMO-CANARY"),
    Mutation(kind: .create, entity: entity, values: ["id": .int(103), "name": .string("third")]),
  ]
  let request = try MutationBatchRequest(mutations: originals, comment: root)
  let results = try await context.execute(request)
  let (commands, prematureAudit) = await probe.snapshot()
  let physical = await sql.snapshot(), events = await audit.snapshot()
  let entries = physical.filter { $0.operation != .select }
  let reads = physical.filter { $0.operation == .select }
  #expect(results.count == 3 && commands.count == 3 && entries.count == 3 && events.count == 3)
  #expect(physical.count == 6 && reads.count == 3)
  #expect(!prematureAudit)
  #expect(commands.map(\.auditReason) == [root, root, root])
  #expect(commands[0].mutationLineage?.map(\.comment) == [root])
  #expect(commands[1].mutationLineage?.map(\.comment) == [root, "inspect PRIVATE-MEMO-CANARY"])
  #expect(commands[2].mutationLineage?.map(\.comment) == [root])
  #expect(commands[0].mutationLineage?.map(\.entityID) == [.int(101)])
  #expect(commands[1].mutationLineage?.map(\.entityID) == [nil, .int(102)])
  for index in entries.indices {
    #expect(reads[index].mutationLineage == entries[index].mutationLineage)
    #expect(reads[index].auditReason == "process batch [REDACTED]")
    #expect(reads[index].tracePath.map(\.kind) == ["operation", "request", "provider", "sql"])
    #expect(reads[index].resultCount == 1)
    #expect(entries[index].executionOutcome == "success")
    #expect(entries[index].auditReason == "process batch [REDACTED]")
    #expect(entries[index].mutationLineage == events[index].mutationLineage)
    #expect(!entries[index].mutationLineage.contains { $0.comment.contains("PRIVATE-MEMO-CANARY") })
    #expect(entries[index].tracePath.last?.name == "insert")
    #expect(events[index].entityID == .int(Int64(101 + index)))
  }
  #expect(request.intent.comment == root && originals[1].auditReason == "inspect PRIVATE-MEMO-CANARY")
  #expect(results[1].persistedRecord?["privateMemo"] == .string("PRIVATE-MEMO-CANARY"))
  #expect(commands[1].values["privateMemo"] == .string("PRIVATE-MEMO-CANARY"))
  // A later independent request must not retain the batch's private values.
  _ = try await context.execute(Mutation(kind: .create, entity: entity,
    values: ["id": .int(104), "name": .string("new-record")], auditReason: "after PRIVATE-MEMO-CANARY"))
  #expect(await sql.snapshot().last?.auditReason == "after PRIVATE-MEMO-CANARY")
  #expect(await audit.snapshot().last?.reason == "after PRIVATE-MEMO-CANARY")
}

@Test
func swiftBatchProviderFailureRollsBackWithoutDroppingEarlierSQLOrSiblingPrivacy() async throws {
  let entity = batchEntity(), service = try SQLiteDataService(path: ":memory:")
  let audit = BatchAudit(), sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "batch failure", entities: [entity]))
  let items = [
    Mutation(kind: .create, entity: entity, values: ["id": .int(101), "name": .string("alpha-record")],
      auditReason: "first item"),
    Mutation(kind: .create, entity: entity, values: ["id": .int(101), "name": .string("duplicate"),
      "privateMemo": .string("FUTURE-SIBLING-CANARY")], auditReason: "second item"),
  ]
  do {
    _ = try await context.execute(MutationBatchRequest(mutations: items, comment: "batch FUTURE-SIBLING-CANARY"))
    Issue.record("duplicate batch item must fail")
  } catch is SQLiteError { }
  let entries = await sql.snapshot()
  #expect(entries.map(\.executionOutcome) == ["success", "success", "failure"])
  #expect(entries[0].mutationLineage.map(\.comment) == ["batch [REDACTED]", "first item"])
  #expect(entries[1].mutationLineage == entries[0].mutationLineage)
  #expect(entries[1].operation == .select)
  #expect(entries[2].mutationLineage.map(\.comment) == ["batch [REDACTED]", "second item"])
  #expect(await audit.snapshot().isEmpty)
  #expect(try await service.auditEvents().isEmpty)
  var query = SelectQuery(entity: entity); query.limit = 3
  query.comment = "inspect failed batch"; query.purpose = "verify transaction rollback"
  #expect(try await context.execute(query).records.isEmpty)
}

@Test
func swiftConcurrentNativeBatchesReuseContextWithoutSharingIntent() async throws {
  let entity = batchEntity(), service = try SQLiteDataService(path: ":memory:")
  let audit = BatchAudit(), sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "concurrent batches", entities: [entity]))
  @Sendable func run(_ first: Int64, label: String) async throws -> [MutationResult] {
    try await context.execute(MutationBatchRequest(mutations: [
      Mutation(kind: .create, entity: entity, values: ["id": .int(first), "name": .string("first")],
        auditReason: "child \(label)"),
      Mutation(kind: .create, entity: entity, values: ["id": .int(first + 1), "name": .string("second")]),
    ], comment: "batch \(label)"))
  }
  async let first = run(301, label: "branch-A")
  async let second = run(401, label: "branch-B")
  let results = try await (first, second)
  #expect(results.0.count == 2 && results.1.count == 2)
  let entries = await sql.snapshot(), events = await audit.snapshot()
  #expect(entries.count == 8 && events.count == 4)
  for event in events {
    let id = try #require(event.entityID?.int64Value)
    let own = id < 400 ? "branch-A" : "branch-B", other = id < 400 ? "branch-B" : "branch-A"
    #expect(event.mutationLineage?.allSatisfy { $0.comment.contains(own) && !$0.comment.contains(other) } == true)
    #expect(event.reason == "batch \(own)")
  }
  #expect(entries.allSatisfy { $0.executionOutcome == "success" })
}
