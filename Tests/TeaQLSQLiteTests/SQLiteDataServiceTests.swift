import Foundation
import TeaQLCore
import TeaQLTestSupport
import Testing

@testable import TeaQLSQLite

private let order = EntityDescriptor(
  name: "CustomerOrder", table: "customer_order",
  properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "orderNumber", column: "order_number", type: .string),
    PropertyDescriptor(name: "orderDate", column: "order_date", type: .date),
    PropertyDescriptor(name: "tenantID", column: "tenant_id", type: .int),
  ])

private func context(
  _ service: SQLiteDataService,
  auditSink: (any AuditSink)? = nil,
  telemetrySink: (any RuntimeTelemetrySink)? = nil
) -> UserContext
{
  UserContext(
    actor: "tester",
    queryExecutor: service,
    mutationExecutor: service,
    requestPolicy: RequestPolicy { query in
      var query = query
      let tenant = TeaQLExpression.equal("tenantID", .int(7))
      query.filter = query.filter.map { .and([tenant, $0]) } ?? tenant
      return query
    },
    auditSink: auditSink,
    telemetrySink: telemetrySink
  )
}

@Test func sqliteCapturesParameterizedSafeExecutionEvidence() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-evidence-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await service.ensureSchema([order])
  let evidence = SQLExecutionEvidenceStore()
  let ctx = context(service, telemetrySink: evidence)

  _ = try await ctx.execute(
    Mutation(
      kind: .create, entity: order,
      values: [
        "id": .int(100), "version": .int(1),
        "orderNumber": .string("secret-customer-value"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ], auditReason: "Seed SQL evidence"))
  var query = SelectQuery(entity: order)
  query.filter = .equal("orderNumber", .string("secret-customer-value"))
  query.comment = "Read SQL evidence fixture"
  query.purpose = "Prove parameterized execution"
  _ = try await ctx.execute(query)

  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.operation == .insert })
  #expect(entries.contains { $0.operation == .select })
  #expect(entries.allSatisfy { !$0.parameterizedSQL.contains("secret-customer-value") })
  #expect(entries.contains { !$0.parameters.isEmpty })
  #expect(entries.contains { $0.resultCount != nil })
  #expect(entries.contains { $0.affectedRows != nil })

  await evidence.enableSelect()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.enableMutation()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.disable()
  #expect(await evidence.snapshot().isEmpty)
}

@Test func sqliteCountsThePolicyFilteredSetWithoutPagination() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-count-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await service.ensureSchema([order])
  for id in 1...3 {
    _ = try await service.execute(
      Mutation(
        kind: .create, entity: order,
        values: [
          "id": .int(Int64(id)), "version": .int(1), "orderNumber": .string("A-\(id)"),
          "orderDate": .date(Date()), "tenantID": .int(id == 3 ? 8 : 7),
        ], auditReason: "Seed count fixture"))
  }
  var query = SelectQuery(entity: order)
  query.offset = 1
  query.limit = 1
  query.comment = "List tenant orders"
  query.purpose = "Verify exact filtered total"
  let ctx = context(service)
  #expect(try await ctx.execute(query).records.count == 1)
  #expect(try await ctx.count(query) == 2)
}

@Test func sqliteCreatesSchemaQueriesAuditsAndRejectsStaleVersion() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await service.ensureSchema([order])
  let appAudit = RecordingAuditSink()
  let ctx = context(service, auditSink: appAudit)

  _ = try await ctx.execute(
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(100), "version": .int(1), "orderNumber": .string("A-100"),
        "orderDate": .date(Date(timeIntervalSince1970: 1_700_000_000)), "tenantID": .int(7),
      ],
      auditReason: "Create order fixture"
    ))
  _ = try await ctx.execute(
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(200), "version": .int(1), "orderNumber": .string("OTHER"),
        "orderDate": .date(Date(timeIntervalSince1970: 1_700_000_000)), "tenantID": .int(8),
      ],
      auditReason: "Create isolated tenant fixture"
    ))

  var query = SelectQuery(entity: order)
  query.comment = "Search tenant orders"
  query.purpose = "Verify tenant isolation"
  let result = try await ctx.execute(query)
  #expect(result.records.count == 1)
  #expect(result.records[0]["id"] == .int(100))
  #expect(result.records[0]["orderDate"]?.dateValue != nil)

  _ = try await ctx.execute(
    Mutation(
      kind: .update,
      entity: order,
      id: .int(100),
      values: ["orderNumber": .string("A-101")],
      expectedVersion: 1,
      auditReason: "Correct order number"
    ))
  await #expect(
    throws: TeaQLError.optimisticLock(entity: "CustomerOrder", id: .int(100), expectedVersion: 1)
  ) {
    try await ctx.execute(
      Mutation(
        kind: .update,
        entity: order,
        id: .int(100),
        values: ["orderNumber": .string("STALE")],
        expectedVersion: 1,
        auditReason: "Attempt stale update"
      ))
  }

  let deleted = try await ctx.execute(
    Mutation(
      kind: .delete,
      entity: order,
      id: .int(100),
      expectedVersion: 2,
      auditReason: "Soft delete order"
    ))
  #expect(deleted.generatedValues["version"] == .int(-3))
  var activeQuery = SelectQuery(entity: order)
  activeQuery.filter = .greaterThanOrEqual("version", .int(1))
  activeQuery.comment = "Read active order"
  activeQuery.purpose = "Verify soft-deleted row is hidden"
  #expect(try await ctx.execute(activeQuery).records.isEmpty)
  var deletedQuery = SelectQuery(entity: order)
  deletedQuery.filter = .lessThanOrEqual("version", .int(-1))
  deletedQuery.comment = "Read deleted order"
  deletedQuery.purpose = "Verify soft-deleted row is retained"
  let deletedRows = try await ctx.execute(deletedQuery).records
  #expect(deletedRows.count == 1)
  #expect(deletedRows[0]["version"] == .int(-3))
  await #expect(
    throws: TeaQLError.optimisticLock(entity: "CustomerOrder", id: .int(100), expectedVersion: 2)
  ) {
    try await ctx.execute(
      Mutation(
        kind: .delete,
        entity: order,
        id: .int(100),
        expectedVersion: 2,
        auditReason: "Attempt stale delete"
      ))
  }
  let audit = try await service.auditEvents()
  #expect(audit.count == 4)
  #expect(audit.last?["reason"] == .string("Soft delete order"))
  #expect(await appAudit.events().count == 4)

  _ = try await service.transaction([
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(300), "version": .int(1), "orderNumber": .string("B-300"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ],
      auditReason: "Create first transaction order"
    ),
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(301), "version": .int(1), "orderNumber": .string("B-301"),
        "orderDate": .date(Date()), "tenantID": .int(7),
      ],
      auditReason: "Create second transaction order"
    ),
  ])
  var transactionQuery = SelectQuery(entity: order)
  transactionQuery.filter = .inList("id", [.int(300), .int(301)])
  transactionQuery.comment = "Read transaction records"
  transactionQuery.purpose = "Verify atomic batch persistence"
  #expect(try await ctx.execute(transactionQuery).records.count == 2)

  await #expect(throws: (any Error).self) {
    try await service.transaction([
      Mutation(
        kind: .create,
        entity: order,
        values: [
          "id": .int(400), "version": .int(1), "orderNumber": .string("ROLLBACK"),
          "orderDate": .date(Date()), "tenantID": .int(7),
        ],
        auditReason: "Begin rollback test"
      ),
      Mutation(
        kind: .create,
        entity: order,
        values: [
          "id": .int(300), "version": .int(1), "orderNumber": .string("DUPLICATE"),
          "orderDate": .date(Date()), "tenantID": .int(7),
        ],
        auditReason: "Trigger rollback test"
      ),
    ])
  }
  var rollbackQuery = SelectQuery(entity: order)
  rollbackQuery.filter = .equal("id", .int(400))
  rollbackQuery.comment = "Read rolled-back record"
  rollbackQuery.purpose = "Verify failed batch rollback"
  #expect(try await ctx.execute(rollbackQuery).records.isEmpty)
}
