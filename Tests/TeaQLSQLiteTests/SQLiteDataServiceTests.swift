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

@Test func mutationAcceptsCanonicalModelKeysForCreateAndUpdate() async throws {
  let descriptor = EntityDescriptor(
    name: "School", table: "school_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "schoolType", modelName: "school_type", column: "school_type", type: .int),
      PropertyDescriptor(name: "studentCapacity", modelName: "student_capacity", column: "student_capacity", type: .string),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-model-keys-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "scalar-storage", entities: [descriptor]))
  let created = try await service.execute(Mutation(
    kind: .create, entity: descriptor,
    values: ["school_type": .int(1001), "student_capacity": .string("800")],
    auditReason: "create using KSML keys"))
  let id = created.persistedRecord?["id"] ?? .null
  #expect(created.persistedRecord?["schoolType"] == .int(1001))
  #expect(created.persistedRecord?["studentCapacity"] == .string("800"))
  let updated = try await service.execute(Mutation(
    kind: .update, entity: descriptor, id: id,
    values: ["student_capacity": .string("900")], expectedVersion: 1,
    auditReason: "update using KSML keys"))
  #expect(updated.persistedRecord?["studentCapacity"] == .string("900"))
}

private struct SavedWidget: TeaQLEntity {
  static let descriptor = EntityDescriptor(
    name: "SavedWidget", table: "saved_widget",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "name", type: .string),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
    ])

  var id: Int64 = 0
  var name = ""
  var version: Int64 = 0

  static func from(record: TeaQLRecord) throws -> Self {
    Self(
      id: record["id"]?.int64Value ?? 0,
      name: record["name"]?.stringValue ?? "",
      version: record["version"]?.int64Value ?? 0)
  }

  func toRecord() -> TeaQLRecord {
    ["id": .int(id), "name": .string(name), "version": .int(version)]
  }
}

@Test func auditedCreatePreservesExplicitIDWhenVersionIsNew() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-explicit-id-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "saved-widget", entities: [SavedWidget.descriptor]))
  let saved = try await AuditedEntity(
    entity: SavedWidget(id: 1001, name: "Primary", version: 0),
    reason: "seed model-defined constant").save(context(service))
  #expect(saved.id == 1001)
  #expect(saved.version == 1)
}

@Test func schoolBootstrapIsIdempotentPreservesRootAndReconcilesConstants() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-school-bootstrap-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  let platform = EntityDescriptor(name: "Platform", table: "platform_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let schoolType = EntityDescriptor(name: "SchoolType", table: "school_type_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "name", type: .string),
    PropertyDescriptor(name: "code", type: .string),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
  ])
  let module = RuntimeModule(name: "school", entities: [platform, schoolType],
    rootEntities: [.init(entity: "Platform", id: 1, values: ["name": .string("Campus Learning Platform")])],
    constantEntities: [
      .init(entity: "SchoolType", id: 1001, values: ["name": .string("Primary"), "code": .string("PRIMARY")]),
      .init(entity: "SchoolType", id: 1002, values: ["name": .string("Secondary"), "code": .string("SECONDARY")]),
    ])
  try await context(service).ensureSchema(module)
  _ = try await service.execute(Mutation(kind: .update, entity: platform, id: .int(1),
    values: ["name": .string("Customer Name")], expectedVersion: 1,
    auditReason: "verify root preservation"))
  let changed = RuntimeModule(name: "school", entities: [platform, schoolType],
    rootEntities: module.rootEntities,
    constantEntities: [
      .init(entity: "SchoolType", id: 1001, values: ["name": .string("Primary School"), "code": .string("PRIMARY")]),
      module.constantEntities[1],
    ])
  try await context(service).ensureSchema(changed)
  var rootQuery = SelectQuery(entity: platform); rootQuery.comment = "verify root"; rootQuery.purpose = "bootstrap conformance"
  var constantQuery = SelectQuery(entity: schoolType); constantQuery.comment = "verify constants"; constantQuery.purpose = "bootstrap conformance"
  let roots = try await service.execute(rootQuery)
  let constants = try await service.execute(constantQuery)
  #expect(roots.records.count == 1)
  #expect(roots.records[0]["name"] == .string("Customer Name"))
  #expect(constants.records.count == 2)
  #expect(constants.records.first { $0["id"] == .int(1001) }?["name"] == .string("Primary School"))
  #expect(constants.records.first { $0["id"] == .int(1001) }?["version"] == .int(2))
  #expect(constants.records.first { $0["id"] == .int(1002) }?["version"] == .int(1))
  let created = try await service.execute(Mutation(kind: .create, entity: schoolType,
    values: ["name": .string("Other"), "code": .string("OTHER")], auditReason: "verify ID floor"))
  #expect((created.generatedValues["id"]?.int64Value ?? 0) > 1002)
}

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

@Test func sqliteIDSpaceIsSharedAcrossRuntimeInstances() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-id-space-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let first = try SQLiteDataService(path: path)
  let second = try SQLiteDataService(path: path)
  try await context(first).ensureSchema(RuntimeModule(name: "saved-widget-first", entities: [SavedWidget.descriptor]))

  let initial = try await first.execute(Mutation(
    kind: .create, entity: SavedWidget.descriptor,
    values: ["name": .string("first")], auditReason: "allocate first ID"))
  let continued = try await second.execute(Mutation(
    kind: .create, entity: SavedWidget.descriptor,
    values: ["name": .string("second")], auditReason: "allocate next ID"))
  #expect(initial.generatedValues["id"] == .int(1))
  #expect(continued.generatedValues["id"] == .int(2))
  try await first.ensureIDFloor(typeName: "SeededWidget", floor: 1001)
  let seededDescriptor = EntityDescriptor(
    name: "SeededWidget", table: "seeded_widget",
    properties: SavedWidget.descriptor.properties)
  try await context(first).ensureSchema(RuntimeModule(name: "seeded-widget", entities: [seededDescriptor]))
  let seeded = try await second.execute(Mutation(
    kind: .create, entity: seededDescriptor,
    values: ["name": .string("after seed")], auditReason: "verify bootstrap floor"))
  #expect(seeded.generatedValues["id"] == .int(1002))

  let ids = try await withThrowingTaskGroup(of: Int64.self) { group in
    for index in 0..<20 {
      let service = index.isMultiple(of: 2) ? first : second
      group.addTask {
        let result = try await service.execute(Mutation(
          kind: .create, entity: SavedWidget.descriptor,
          values: ["name": .string("widget-\(index)")],
          auditReason: "verify concurrent ID allocation"))
        return result.generatedValues["id"]?.int64Value ?? -1
      }
    }
    var values: [Int64] = []
    for try await value in group { values.append(value) }
    return values.sorted()
  }
  #expect(ids == Array(3...22))
}

@Test func auditedLifecycleReturnsAuthoritativeTypedEntity() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-save-result-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "saved-widget-delete", entities: [SavedWidget.descriptor]))
  let context = context(service)

  var widget = SavedWidget(name: "created")
  let created = try await widget.auditAs("create widget").save(context)
  #expect(created.id > 0)
  #expect(created.version == 1)
  #expect(created.name == "created")
  #expect(widget.id == 0)

  widget = created
  widget.name = "updated"
  let updated = try await widget.auditAs("update widget").save(context)
  #expect(updated.id == created.id)
  #expect(updated.version == 2)
  #expect(updated.name == "updated")

  let deleted = try await updated.auditAs("delete widget").delete(context)
  #expect(deleted.id == created.id)
  #expect(deleted.version == -3)
  #expect(deleted.name == "updated")
}

@Test func sqliteCapturesParameterizedSafeExecutionEvidence() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-evidence-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-relations", entities: [order]))
  let evidence = SQLExecutionEvidenceStore()
  let context = context(service, telemetrySink: evidence)

  _ = try await context.execute(
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
  _ = try await context.execute(query)

  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.operation == .insert })
  #expect(entries.contains { $0.operation == .select })
  #expect(entries.allSatisfy { !$0.parameterizedSQL.contains("secret-customer-value") })
  #expect(entries.contains { !$0.parameters.isEmpty })
  #expect(entries.contains { $0.debugSQL.contains("'secret-customer-value'") })
  #expect(entries.contains { $0.resultCount != nil })
  #expect(entries.contains { $0.affectedRows != nil })

  await evidence.enableSelect()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.enableMutation()
  #expect(await evidence.snapshot().isEmpty)
  await evidence.disable()
  #expect(await evidence.snapshot().isEmpty)
}

@Test func sqliteTemporalPreparedAndDebugSQLShareStorageSemantics() async throws {
  let temporal = EntityDescriptor(
    name: "TemporalFixture", table: "temporal_fixture",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "calendarDate", column: "calendar_date", type: .date),
      PropertyDescriptor(name: "localDateTime", column: "local_date_time", type: .localDateTime),
      PropertyDescriptor(name: "instant", column: "instant_ms", type: .timestamp),
      PropertyDescriptor(name: "tenantID", column: "tenant_id", type: .int),
    ])
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-temporal-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "temporal", entities: [temporal]))
  let evidence = SQLExecutionEvidenceStore()
  let context = context(service, telemetrySink: evidence)

  _ = try await context.execute(Mutation(
    kind: .create, entity: temporal,
    values: [
      "id": .int(1), "version": .int(1), "calendarDate": .calendarDate("2024-02-29"),
      "localDateTime": .localDateTime("2026-08-19 09:30:00.123"),
      "instant": .timestamp(1_787_110_200_123), "tenantID": .int(7),
    ], auditReason: "verify temporal SQLite storage"))
  var query = SelectQuery(entity: temporal)
  query.filter = .equal("id", .int(1))
  query.comment = "Read temporal fixture"
  query.purpose = "Verify temporal round trip"
  let result = try await context.execute(query)

  #expect(result.records[0]["calendarDate"] == .calendarDate("2024-02-29"))
  #expect(result.records[0]["localDateTime"] == .localDateTime("2026-08-19 09:30:00.123"))
  #expect(result.records[0]["instant"] == .timestamp(1_787_110_200_123))
  let entries = await evidence.snapshot()
  #expect(entries.contains { $0.debugSQL.contains("'2024-02-29'") })
  #expect(entries.contains { $0.debugSQL.contains("1787110200123") })
}

@Test func sqliteCountsThePolicyFilteredSetWithoutPagination() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-count-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-comments", entities: [order]))
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
  let context = context(service)
  #expect(try await context.execute(query).records.count == 1)
  #expect(try await context.count(query) == 2)
}

@Test func sqliteCreatesSchemaQueriesAuditsAndRejectsStaleVersion() async throws {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-\(UUID().uuidString).db").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  let service = try SQLiteDataService(path: path)
  try await context(service).ensureSchema(RuntimeModule(name: "order-sql-evidence", entities: [order]))
  let appAudit = RecordingAuditSink()
  let context = context(service, auditSink: appAudit)

  _ = try await context.execute(
    Mutation(
      kind: .create,
      entity: order,
      values: [
        "id": .int(100), "version": .int(1), "orderNumber": .string("A-100"),
        "orderDate": .date(Date(timeIntervalSince1970: 1_700_000_000)), "tenantID": .int(7),
      ],
      auditReason: "Create order fixture"
    ))
  _ = try await context.execute(
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
  let result = try await context.execute(query)
  #expect(result.records.count == 1)
  #expect(result.records[0]["id"] == .int(100))
  #expect(result.records[0]["orderDate"]?.dateValue != nil)

  _ = try await context.execute(
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
    try await context.execute(
      Mutation(
        kind: .update,
        entity: order,
        id: .int(100),
        values: ["orderNumber": .string("STALE")],
        expectedVersion: 1,
        auditReason: "Attempt stale update"
      ))
  }

  let deleted = try await context.execute(
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
  #expect(try await context.execute(activeQuery).records.isEmpty)
  var deletedQuery = SelectQuery(entity: order)
  deletedQuery.filter = .lessThanOrEqual("version", .int(-1))
  deletedQuery.comment = "Read deleted order"
  deletedQuery.purpose = "Verify soft-deleted row is retained"
  let deletedRows = try await context.execute(deletedQuery).records
  #expect(deletedRows.count == 1)
  #expect(deletedRows[0]["version"] == .int(-3))
  await #expect(
    throws: TeaQLError.optimisticLock(entity: "CustomerOrder", id: .int(100), expectedVersion: 2)
  ) {
    try await context.execute(
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
  #expect(try await context.execute(transactionQuery).records.count == 2)

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
  #expect(try await context.execute(rollbackQuery).records.isEmpty)
}
