import Foundation
import Testing
import TeaQLCore
import TeaQLSQLite

private actor CommittedGraphAudit: AuditSink {
  private var events: [AuditEvent] = []
  func record(_ event: AuditEvent) { events.append(event) }
  func snapshot() -> [AuditEvent] { events }
}

private actor FailingOnceGraphAudit: AuditSink {
  private var attempts = 0
  func record(_ event: AuditEvent) throws {
    attempts += 1
    if attempts == 1 { throw TeaQLError.execution("injected audit delivery failure") }
  }
  func count() -> Int { attempts }
}

private final class GraphCompletionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var successfulCallbacks = 0, rollbacks = 0
  func completed() { lock.withLock { successfulCallbacks += 1 } }
  func rolledBack() { lock.withLock { rollbacks += 1 } }
  func counts() -> (completed: Int, rolledBack: Int) { lock.withLock { (successfulCallbacks, rollbacks) } }
}

@Test
func swiftGraphRollbackDoesNotEmitCommittedAudits() async throws {
  let root = EntityDescriptor(name: "CustomerOrder", table: "rollback_order", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let absent = EntityDescriptor(name: "Payment", table: "absent_payment", properties: root.properties)
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-graph-rollback-\(UUID()).sqlite").path)
  let audit = CommittedGraphAudit()
  let sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "rollback", entities: [root]))
  do {
    try await context.executeGraphSave(comment: "submit order") { context, session in
      let rootScope = try session.scope(key: EntityKey(entity: root.name, id: .int(100)))
      let childScope = try session.scope(key: EntityKey(entity: absent.name, id: .int(301)),
        localReason: "authorize payment", parent: rootScope)
      _ = try await context.execute(Mutation(kind: .create, entity: root,
        values: ["id": .int(100)], auditReason: "submit order", mutationLineage: rootScope.recover()))
      _ = try await context.execute(Mutation(kind: .create, entity: absent,
        values: ["id": .int(301)], auditReason: "submit order", mutationLineage: childScope.recover()))
    }
    Issue.record("the absent payment table must fail")
  } catch is SQLiteError { }
  #expect(await audit.snapshot().isEmpty)
  var query = SelectQuery(entity: root)
  query.limit = 2; query.comment = "inspect rollback"; query.purpose = "verify atomicity"
  #expect(try await context.execute(query).records.isEmpty)
  let entries = await sql.snapshot().filter { $0.operation != .select }
  #expect(entries.map(\.executionOutcome) == ["success", "failure"])
  #expect(entries.last?.mutationLineage.map(\.name) == ["CustomerOrder", "Payment"])
  #expect(entries.last?.mutationLineage.map(\.entityID) == [.int(100), .int(301)])
}

/// Explicit native composition, not a substitute for the generated graph gate.
@Test(arguments: [false, true])
func swiftNativeGraphLineageIsPerItemAndCommittedOnly(failCommit: Bool) async throws {
  func descriptor(_ name: String) -> EntityDescriptor {
    EntityDescriptor(name: name, table: "native_\(name.lowercased())", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ])
  }
  let entities = ["CustomerOrder", "OrderItem", "Payment", "PaymentAttempt", "Shipment"].map(descriptor)
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-native-graph-\(UUID()).sqlite").path)
  let audit = CommittedGraphAudit()
  let sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "graph", entities: entities))
  _ = try await context.execute(Mutation(kind: .create, entity: entities[1],
    values: ["id": .int(202), "name": .string("unavailable")], auditReason: "seed pending deletion"))
  let oldEvents = await audit.snapshot().count
  await sql.enableAll()
  do {
    try await context.executeGraphSave(comment: "submit order") { context, session in
      let root = try session.scope(key: EntityKey(entity: entities[0].name, id: .int(100)))
      let payment = try session.scope(key: EntityKey(entity: entities[2].name, id: .int(301)),
        localReason: "authorize payment", parent: root)
      let shipment = try session.scope(key: EntityKey(entity: entities[4].name, id: .int(501)),
        localReason: "dispatch shipment", parent: root)
      let deleted = try session.scope(key: EntityKey(entity: entities[1].name, id: .int(202)),
        localReason: "remove unavailable item", parent: root)
      let nodes: [(Int, Int64, TraceScopeToken)] = [
        (0, 100, root), (1, 201, root), (2, 301, payment), (3, 401, payment), (4, 501, shipment), (1, 202, deleted),
      ]
      let mutations = nodes.enumerated().map { index, value in
        Mutation(kind: index == 5 ? .delete : .create, entity: entities[value.0],
          id: index == 5 ? .int(value.1) : nil,
          values: index == 5 ? [:] : ["id": .int(value.1), "name": .string("node")],
          expectedVersion: index == 5 ? 1 : nil,
          auditReason: session.intent.comment, mutationLineage: value.2.recover())
      }
      for mutation in mutations { _ = try context.preflightMutation(mutation) }
      for mutation in mutations {
        _ = try await context.execute(mutation)
        #expect(await audit.snapshot().count == oldEvents)
      }
      if failCommit { throw TeaQLError.execution("injected failure before commit") }
    }
    #expect(!failCommit)
  } catch { #expect(failCommit) }
  let events = Array(await audit.snapshot().dropFirst(oldEvents))
  #expect(events.count == (failCommit ? 0 : 6))
  let entries = await sql.snapshot()
  #expect(entries.count == 6)
  let expected = [["CustomerOrder"], ["CustomerOrder"], ["CustomerOrder", "Payment"],
    ["CustomerOrder", "Payment"], ["CustomerOrder", "Shipment"], ["CustomerOrder", "OrderItem"]]
  for (index, entry) in entries.enumerated() {
    #expect(entry.mutationLineage.map(\.name) == expected[index])
    #expect(entry.tracePath.first?.name == "CustomerOrder")
    #expect(entry.tracePath.filter { $0.kind == "entity" }.first?.name
      == ["CustomerOrder", "OrderItem", "Payment", "PaymentAttempt", "Shipment", "OrderItem"][index])
    #expect(entry.tracePath.allSatisfy { !["auditReason", "comment", "purpose"].contains($0.kind) })
    if !failCommit { #expect(events[index].mutationLineage == entry.mutationLineage) }
  }
}

@Test
func swiftLateAssignedIDIsPresentInPhysicalAndCommittedLineage() async throws {
  let payment = EntityDescriptor(name: "Payment", table: "late_payment", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-late-graph-\(UUID()).sqlite").path)
  let audit = CommittedGraphAudit(); let sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "late", entities: [payment]))
  try await context.executeGraphSave(comment: "authorize payment") { context, session in
    let scope = try session.scope(key: EntityKey(entity: "Payment", id: .int(-1)))
    _ = try await context.execute(Mutation(kind: .create, entity: payment,
      auditReason: session.intent.comment, mutationLineage: scope.recover()))
  }
  let events = await audit.snapshot(); let entries = await sql.snapshot()
  #expect(events.count == 1 && entries.count == 1)
  #expect(events.first?.entityID == .int(1))
  #expect(events.first?.mutationLineage?.first?.entityID == .int(1))
  #expect(entries.first?.mutationLineage.first?.entityID == .int(1))
}

@Test
func swiftNativeConcurrentGraphsReuseContextWithoutSharingScopes() async throws {
  let properties = [PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true)]
  let order = EntityDescriptor(name: "CustomerOrder", table: "concurrent_order", properties: properties)
  let payment = EntityDescriptor(name: "Payment", table: "concurrent_payment", properties: properties)
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-concurrent-graph-\(UUID()).sqlite").path)
  let audit = CommittedGraphAudit(); let sql = SQLExecutionEvidenceStore()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit, telemetrySink: sql,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "concurrent", entities: [order, payment]))
  @Sendable func run(_ id: Int64, _ label: String) async throws {
    try await context.executeGraphSave(comment: "submit \(label)") { context, session in
      let root = try session.scope(key: EntityKey(entity: "CustomerOrder", id: .int(id)))
      let child = try session.scope(key: EntityKey(entity: "Payment", id: .int(id)),
        localReason: "authorize \(label)", parent: root)
      _ = try await context.execute(Mutation(kind: .create, entity: order,
        values: ["id": .int(id)], auditReason: session.intent.comment, mutationLineage: root.recover()))
      await Task.yield()
      _ = try await context.execute(Mutation(kind: .create, entity: payment,
        values: ["id": .int(id)], auditReason: session.intent.comment, mutationLineage: child.recover()))
    }
  }
  async let first: Void = run(1, "graph-A")
  async let second: Void = run(2, "graph-B")
  _ = try await (first, second)
  let events = await audit.snapshot(); let entries = await sql.snapshot()
  #expect(events.count == 4 && entries.count == 4)
  for event in events {
    let id = try #require(event.entityID?.int64Value)
    let own = id == 1 ? "graph-A" : "graph-B"
    let other = id == 1 ? "graph-B" : "graph-A"
    let lineage = try #require(event.mutationLineage)
    #expect(lineage.allSatisfy { $0.comment.contains(own) && !$0.comment.contains(other) })
    #expect(lineage.map(\.name) == (event.entity == "Payment" ? ["CustomerOrder", "Payment"] : ["CustomerOrder"]))
    #expect(lineage.allSatisfy { $0.entityID == .int(id) })
  }
}

@Test
func swiftPostcommitAuditFailureKeepsCommittedDataAndAttemptsRemainingEvents() async throws {
  let entity = EntityDescriptor(name: "CustomerOrder", table: "audit_delivery_order", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-audit-delivery-\(UUID()).sqlite").path)
  let sink = FailingOnceGraphAudit()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: sink,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "audit delivery", entities: [entity]))
  do {
    try await context.executeGraphSave(comment: "submit order") { context, _ in
      for id in [Int64(1), 2] {
        _ = try await context.execute(Mutation(kind: .create, entity: entity,
          values: ["id": .int(id)], auditReason: "submit order"))
      }
    }
    Issue.record("the failed audit delivery must be reported")
  } catch let failure as GraphCommittedError {
    #expect(failure.committed && failure.causes.count == 1)
  }
  #expect(await sink.count() == 2)
  var query = SelectQuery(entity: entity); query.limit = 3
  query.comment = "inspect committed data"; query.purpose = "avoid replaying an already committed write"
  #expect(try await context.execute(query).records.count == 2)
  // The gate was released even when delivery failed; a later independent root
  // can finish rather than hanging behind a completed invocation.
  try await context.executeGraphSave(comment: "submit next order") { context, _ in
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(3)], auditReason: "submit next order"))
  }
}

@Test
func swiftPostcommitCleanupFailureKeepsDataAndAttemptsOtherCallbacksAndAudit() async throws {
  let entity = EntityDescriptor(name: "CustomerOrder", table: "cleanup_failure_order", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let service = try SQLiteDataService(path: FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-cleanup-failure-\(UUID()).sqlite").path)
  let audit = CommittedGraphAudit(), probe = GraphCompletionProbe()
  let context = UserContext(queryExecutor: service, mutationExecutor: service,
    requestPolicy: RequestPolicy { $0 }, auditSink: audit,
    diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }))
  try await context.ensureSchema(RuntimeModule(name: "cleanup failure", entities: [entity]))
  do {
    try await context.executeGraphSave(comment: "submit first order") { context, session in
      try session.afterCommit { throw TeaQLError.execution("injected ledger cleanup failure") }
      try session.afterCommit { probe.completed() }
      try session.afterRollback { probe.rolledBack() }
      _ = try await context.execute(Mutation(kind: .create, entity: entity,
        values: ["id": .int(1)], auditReason: "submit first order"))
    }
    Issue.record("cleanup failure must report committed state")
  } catch let failure as GraphCommittedError {
    #expect(failure.committed && failure.causes.count == 1)
  }
  #expect(probe.counts().completed == 1 && probe.counts().rolledBack == 0)
  #expect(await audit.snapshot().count == 1)
  var query = SelectQuery(entity: entity); query.limit = 2
  query.comment = "inspect cleanup failure"; query.purpose = "verify committed write is not replayed"
  #expect(try await context.execute(query).records.count == 1)
  try await context.executeGraphSave(comment: "submit independent order") { context, _ in
    _ = try await context.execute(Mutation(kind: .create, entity: entity,
      values: ["id": .int(2)], auditReason: "submit independent order"))
  }
  #expect(try await context.execute(query).records.count == 2)
  #expect(await audit.snapshot().count == 2)
}
