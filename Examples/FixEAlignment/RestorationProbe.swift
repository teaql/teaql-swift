import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct RestorationCalls: Codable, Equatable, Sendable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}

private actor RestorationProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  let service: SQLiteDataService
  private var calls = RestorationCalls()
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    calls.queries += 1; return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    calls.mutations += 1; return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { calls.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { calls.commits += 1; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { calls.rollbacks += 1; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { calls.audits += 1 }
  func reset() { calls = RestorationCalls() }
  func snapshot() -> RestorationCalls { calls }
}

private final class RestorationClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  let time: Date
  private var reads = 0
  init(_ time: Date) { self.time = time }
  func now() -> Date { lock.withLock { reads += 1; return time } }
  func reset() { lock.withLock { reads = 0 } }
  var count: Int { lock.withLock { reads } }
}

private struct RestorationCounts: Codable, Equatable {
  var fixes = 0, resolutions = 0, reviews = 0
}
private final class RestorationPolicy: MutationPolicyRegistry, MutationPolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var counts = RestorationCounts()
  let identity = MutationPolicyIdentity(policyID: "restoration-example", version: "1", fingerprint: "fixture")
  func fix() { lock.withLock { counts.fixes += 1 } }
  func resolve(requestKey: String) -> (any MutationPolicy)? {
    lock.withLock { counts.resolutions += 1 }; return self
  }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { counts.reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func reset() { lock.withLock { counts = RestorationCounts() } }
  var snapshot: RestorationCounts { lock.withLock { counts } }
}
private struct RestorationChecker: EntityChecker {
  let base: any EntityChecker
  let policy: RestorationPolicy
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    policy.fix(); return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}

/// Application-owned contract test. Business writes use generated audited saves;
/// independent SQL below is read-only. No generated implementation is inspected.
enum RestorationProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  static func verify(path: String) async throws {
    let t0 = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let t1 = t0.addingTimeInterval(86_400)
    let service = try SQLiteDataService(path: path), provider = RestorationProvider(service)
    let policy = RestorationPolicy(), clock = RestorationClock(t1)
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    var checkers: [String: any EntityChecker] = [:]
    for name in ["Tenant", "PurchaseOrder", "OrderItem"] {
      guard let base = runtime.checker(named: name) else { throw TeaQLError.execution("Missing generated Checker") }
      checkers[name] = RestorationChecker(base: base, policy: policy)
    }
    try runtime.install(RuntimeModule(name: "counted restoration example", entities: module.entities, checkers: checkers))
    func context(_ executor: any QueryExecutor, _ mutations: any MutationExecutor,
      _ businessClock: any BusinessClock, observed: Bool) -> UserContext {
      UserContext(runtime: runtime, actor: "restoration-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
        queryExecutor: executor, mutationExecutor: mutations, requestPolicy: RequestPolicy { $0 },
        auditSink: observed ? provider : nil, mutationPolicyRegistry: policy, businessClock: businessClock)
    }
    let setup = context(service, service, FixedBusinessClock(t0), observed: false)
    try await setup.ensureSchema(module)
    let initial = context(provider, provider, FixedBusinessClock(t0), observed: true)
    let current = context(provider, provider, clock, observed: true)
    await provider.reset(); policy.reset()
    var parent = try Q.purchaseOrders().comment("Prepare a known persisted restoration baseline")
      .purpose("Verify cancellation without losing real graph edits").newEntity(initial)
    parent.updateContactPhone("5550800"); parent.updateInternalNote(nil)
    var child = try Q.orderItems().comment("Prepare the child used by graph restoration controls")
      .purpose("Calibrate real generated graph writes").newEntity(initial)
    child.updateProductName("Restoration original"); child.updateUnitPrice(Decimal(string: "10.00")!)
    parent.orderItemList.append(child)
    let saved = try await parent.auditAs("Seed the restoration graph through generated mutation APIs").save(initial)
    let calibration = await provider.snapshot(), calibrationPolicy = policy.snapshot
    try require(calibration.mutations == 2 && calibration.begins == 1 && calibration.commits == 1
      && calibration.rollbacks == 0 && calibration.audits == 2 && calibrationPolicy.fixes == 2
      && calibrationPolicy.reviews == 1 && calibrationPolicy.resolutions > 0, "Restoration observers were not calibrated")
    func load(_ withChild: Bool = false) async throws -> PurchaseOrder {
      let request = withChild ? Q.purchaseOrders().selectOrderItemListWith(
        Q.orderItems().limit(1).comment("Load the bounded restoration child")) : Q.purchaseOrders()
      let rows = try await request.withIdIs(saved.id).limit(1)
        .comment("Reload the actual persisted restoration baseline")
        .purpose("Keep each mutation scenario independent").executeForList(current)
      guard let row = rows.first else { throw TeaQLError.execution("Missing restoration fixture") }
      return row
    }
    struct Observation: Encodable {
      let name: String, orderID: Int64, childID: Int64?
      let versionBefore: Int64, versionAfter: Int64
      let physicalBefore: String, physicalAfter: String
      let calls: RestorationCalls, policy: RestorationCounts, clockReads: Int
      let rejected: Bool, intentRetained: Bool, sparseBoundaryRetained: Bool
      let passed = true
    }
    let names = ["typed-known-value", "typed-known-null", "generic-known-value-and-null",
      "same-id-other-type-intent", "restored-field-with-real-edit", "unknown-original-null",
      "clean-sparse-ancestor", "clean-parent-dirty-child", "deletion-not-cancelled"]
    var observations: [Observation] = []
    for name in names {
      var row = try await load(name == "clean-parent-dirty-child")
      let phone = try E.purchaseOrder(row).contactPhone().eval()
      let originalVersion = row.version
      var graph: Tenant?, graphJSON: String?, otherKey: EntityKey?, childID: Int64?
      var expectedMutations = 0
      switch name {
      case "typed-known-null": row.updateInternalNote("temporary"); row.updateInternalNote(nil)
      case "generic-known-value-and-null":
        row.teaqlEntityRoot.set(row.teaqlEntityKey, field: "contact_phone", value: .string("temporary"))
        row.teaqlEntityRoot.set(row.teaqlEntityKey, field: "contact_phone", value: .string(phone!))
        row.teaqlEntityRoot.set(row.teaqlEntityKey, field: "internal_note", value: .string("temporary"))
        row.teaqlEntityRoot.set(row.teaqlEntityKey, field: "internal_note", value: .null)
        try require(row.teaqlEntityRoot.change(row.teaqlEntityKey).count == 2, "Generic normalization was not exercised")
      case "unknown-original-null":
        let rows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(saved.id).limit(1)
          .comment("Leave the original optional field genuinely unknown")
          .purpose("Unknown original null must not cancel explicit intent").executeForList(current)
        guard let partial = rows.first else { throw TeaQLError.execution("Missing sparse fixture") }
        row = partial; row.updateInternalNote(nil)
      case "clean-sparse-ancestor":
        let roots = try await Q.tenantsWithMinimalFields().withIdIs(1)
          .selectPurchaseOrderListWith(Q.purchaseOrders().withIdIs(saved.id).limit(1)
            .comment("Load a complete restorable child behind an untouched partial ancestor"))
          .limit(1).comment("Preserve sparse geometry when the final graph is empty")
          .purpose("A no-op is not a reload").executeForList(current)
        guard var root = roots.first else { throw TeaQLError.execution("Missing sparse graph") }
        root.purchaseOrderList[0].updateContactPhone("temporary")
        root.purchaseOrderList[0].updateContactPhone(phone)
        graphJSON = try json(root); graph = root
      case "deletion-not-cancelled":
        row.updateContactPhone("temporary"); row.updateContactPhone(phone)
        row.teaqlEntityRoot.markAsDeleted(row.teaqlEntityKey); expectedMutations = 1
      default:
        row.updateContactPhone("temporary"); row.updateContactPhone(phone)
        if name == "same-id-other-type-intent" {
          let key = EntityKey(entity: "OrderItem", id: .int(row.id)); otherKey = key
          row.teaqlEntityRoot.set(key, field: "product_name", value: .string("independent pending intention"))
        }
        if name == "restored-field-with-real-edit" { row.updateInternalNote("genuine edit"); expectedMutations = 1 }
        if name == "clean-parent-dirty-child" {
          try require(row.orderItemList.count == 1, "Missing selected child")
          childID = row.orderItemList[0].id
          row.orderItemList[0].updateProductName("Restoration genuine child edit"); expectedMutations = 1
        }
      }
      let before = try physical(path), pending = row.teaqlEntityRoot.change(row.teaqlEntityKey)
      await provider.reset(); policy.reset(); clock.reset()
      var rejected = false, sparse = true, resultVersion = originalVersion
      if let root = graph {
        let result = try await root.auditAs("Save a fully restored graph without widening its sparse ancestor").save(current)
        try require(try json(result) == graphJSON, "No-op changed the selected view geometry")
        do { _ = try E.tenant(result).name().eval(); sparse = false }
        catch is TeaQLCore.TeaQLNotLoadedError { }
        try require(!result.purchaseOrderList[0].teaqlEntityRoot.hasPending(result.purchaseOrderList[0].teaqlEntityKey), "Restored graph child stayed pending")
      } else {
        do {
          let result = try await row.auditAs("Verify the known-baseline restoration contract").save(current)
          resultVersion = result.version
        } catch let error as CheckException where name == "unknown-original-null" {
          rejected = true
          try require(error.violations.contains { $0.ruleID == "invalid_type" }, "Unknown original failed for an unrelated reason")
        }
      }
      let calls = await provider.snapshot(), counts = policy.snapshot, reads = clock.count
      let after = try physical(path)
      let retained = name != "unknown-original-null" || row.teaqlEntityRoot.change(row.teaqlEntityKey) == pending
      if expectedMutations == 0 {
        try require(calls == RestorationCalls() && counts == RestorationCounts() && reads == 0,
          "Restored or rejected graph entered Fix, clock, policy, provider, transaction or audit")
        try require(before == after && resultVersion == originalVersion, "No-op or rejected write changed storage or version")
      } else {
        try require(calls.queries == 0 && calls.mutations == 1 && calls.begins == 1 && calls.commits == 1
          && calls.rollbacks == 0 && calls.audits == 1 && counts.reviews == 1 && counts.resolutions > 0
          && reads == 1 && before != after, "Real remaining operation did not cross the calibrated persistence boundary exactly once")
        if name != "deletion-not-cancelled" { try require(counts.fixes == 1, "Restored parent received an extra Fix") }
      }
      try require(rejected == (name == "unknown-original-null") && retained && sparse, "Lost rejection, intent or load state")
      if let key = otherKey {
        try require(row.teaqlEntityRoot.change(key)["product_name"] == .string("independent pending intention"), "Same-ID different-type intent was drained")
      }
      if name != "unknown-original-null" && graph == nil {
        try require(!row.teaqlEntityRoot.hasPending(row.teaqlEntityKey), "The reached entity's committed/restored intent was not cleared")
      }
      observations.append(Observation(name: name, orderID: row.id, childID: childID,
        versionBefore: originalVersion, versionAfter: resultVersion, physicalBefore: before, physicalAfter: after,
        calls: calls, policy: counts, clockReads: reads, rejected: rejected, intentRetained: retained,
        sparseBoundaryRetained: sparse))
    }
    struct Report: Encodable {
      let language = "swift", passed = true
      let calibration: RestorationCalls, calibrationPolicy: RestorationCounts
      let observations: [Observation]
      let generatedImplementationsModified = false, directBusinessSQLWrites = false
    }
    print("CORE_SWIFT_RESTORATION_RESULT=" + (try json(Report(calibration: calibration,
      calibrationPolicy: calibrationPolicy, observations: observations))))
  }

  private static func physical(_ path: String) throws -> String {
    var database: OpaquePointer?
    try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Cannot open read-only restoration oracle")
    defer { sqlite3_close(database) }
    var result: [String: [[String: String?]]] = [:]
    for table in ["tenant_data", "purchase_order_data", "order_item_data", "teaql_id_space"] {
      var statement: OpaquePointer?
      let order = table == "teaql_id_space" ? "type_name" : "id"
      try require(sqlite3_prepare_v2(database, "SELECT * FROM " + table + " ORDER BY " + order, -1, &statement, nil) == SQLITE_OK, "Cannot prepare physical restoration SELECT")
      defer { sqlite3_finalize(statement) }
      var rows: [[String: String?]] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        try require(status == SQLITE_ROW, "Physical restoration SELECT failed")
        var row: [String: String?] = [:]
        for index in 0..<sqlite3_column_count(statement) {
          let key = String(cString: sqlite3_column_name(statement, index))
          row[key] = sqlite3_column_type(statement, index) == SQLITE_NULL ? .some(nil)
            : .some(String(cString: sqlite3_column_text(statement, index)))
        }
        rows.append(row)
      }
      result[table] = rows
    }
    return try json(result)
  }
}
