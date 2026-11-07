import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct RootEffects: Codable, Equatable, Sendable {
  var queries = 0, rootLookups = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}
private actor RootProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var effects = RootEffects()
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    effects.queries += 1
    if request.query.entity.name == "Tenant" { effects.rootLookups += 1 }
    return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    effects.mutations += 1; return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { effects.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { effects.commits += 1; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { effects.rollbacks += 1; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { effects.audits += 1 }
  func reset() { effects = RootEffects() }
  func snapshot() -> RootEffects { effects }
}
private struct RootCallbacks: Codable, Equatable { var fixes = 0, policies = 0, reviews = 0 }
private final class RootPolicy: MutationPolicyRegistry, MutationPolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = RootCallbacks()
  let identity = MutationPolicyIdentity(policyID: "partial-root-example", version: "1", fingerprint: "fixture")
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls.policies += 1 }; return self }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { calls.reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func fix() { lock.withLock { calls.fixes += 1 } }
  func reset() { lock.withLock { calls = RootCallbacks() } }
  var snapshot: RootCallbacks { lock.withLock { calls } }
}
private struct RootChecker: EntityChecker {
  let base: any EntityChecker
  let policy: RootPolicy
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    policy.fix(); return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}

/// Complete modified leaf, two untouched sparse ancestors, and a different
/// independently persisted context root. All business writes use generated APIs.
enum PartialRootProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  static func verify(path: String) async throws {
    let t0 = ISO8601DateFormatter().date(from: "2032-04-01T10:15:30Z")!
    let t1 = t0.addingTimeInterval(86_400)
    let module = GeneratedRuntimeModule.module
    let service = try SQLiteDataService(path: path), provider = RootProvider(service), policy = RootPolicy()
    var runtime = TeaQLRuntime(); try runtime.install(module)
    var checkers: [String: any EntityChecker] = [:]
    for name in ["Tenant", "PurchaseOrder", "OrderItem"] {
      guard let base = runtime.checker(named: name) else { throw TeaQLError.execution("Missing generated Checker") }
      checkers[name] = RootChecker(base: base, policy: policy)
    }
    try runtime.install(RuntimeModule(name: "Observed root example", entities: module.entities, checkers: checkers))
    func context(root: Int64, time: Date) -> UserContext {
      UserContext(runtime: runtime, actor: "partial-root-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(root)),
        queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
        auditSink: provider, mutationPolicyRegistry: policy, businessClock: FixedBusinessClock(time))
    }
    let schema = UserContext(runtime: runtime, actor: "partial-root-schema",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      businessClock: FixedBusinessClock(t0))
    try await schema.ensureSchema(module)
    let initial = context(root: 1, time: t0)
    await provider.reset(); policy.reset()
    var other = try await Q.tenants().comment("Prepare an independent persisted root")
      .purpose("Never test ownership against an invented context identity").newEntity(initial)
    other.updateName("Independent partial root")
    let independent = try await other.auditAs("Create the independent active-root control").save(initial)
    try require(independent.id != 1, "The independent root must differ from the bootstrap root")
    var parent = try await Q.purchaseOrders().comment("Prepare the managed partial-ancestor graph")
      .purpose("Use an actual complete child under two sparse ancestors").newEntity(initial)
    parent.updateContactPhone("5550801"); parent.updateInternalNote(nil)
    var child = try await Q.orderItems().comment("Prepare the root-bound leaf")
      .purpose("Preserve the original root outside the mutation delta").newEntity(initial)
    child.updateProductName("Managed partial original"); child.updateUnitPrice(Decimal(string: "10.00")!)
    parent.orderItemList.append(child)
    let saved = try await parent.auditAs("Seed the root-bound graph through generated saves").save(initial)
    let roots = try await Q.tenantsWithMinimalFields().withIdIs(1)
      .selectPurchaseOrderListWith(Q.purchaseOrdersWithMinimalFields().withIdIs(saved.id)
        .selectOrderItemListWith(Q.orderItems().limit(1).comment("Load every scalar of the changed leaf"))
        .limit(1).comment("Keep the unchanged middle ancestor sparse"))
      .limit(1).comment("Load the sparse root above the selected leaf")
      .purpose("Validate root ownership without widening the loaded graph").executeForList(initial)
    guard var graph = roots.first else { throw TeaQLError.execution("Missing selected root") }
    try require(graph.purchaseOrderList.count == 1 && graph.purchaseOrderList[0].orderItemList.count == 1,
      "The bounded graph must contain exactly the prepared leaf")
    let leafID = try E.tenant(graph).purchaseOrderList().first().orderItemList().first().id().eval()!
    try require(try E.tenant(graph).purchaseOrderList().first().orderItemList().first().tenantId().eval() == 1,
      "The complete leaf must retain its original root")
    // Positively calibrate rollback without causing a business mutation.
    try await provider.beginGraphTransaction(); try await provider.rollbackGraphTransaction()
    let calibration = await provider.snapshot(), callbackCalibration = policy.snapshot
    try require(calibration.queries > 0 && calibration.rootLookups > 0 && calibration.mutations == 3
      && calibration.begins == 3 && calibration.commits == 2 && calibration.rollbacks == 1 && calibration.audits == 3
      && callbackCalibration.fixes == 3 && callbackCalibration.policies > 0 && callbackCalibration.reviews == 2,
      "All ten provider and callback boundaries must be positively calibrated")
    graph.purchaseOrderList[0].orderItemList[0].updateProductName("Managed partial retry")
    let leaf = graph.purchaseOrderList[0].orderItemList[0], ledger = leaf.teaqlEntityRoot, key = leaf.teaqlEntityKey
    let pending = ledger.change(key), beforeView = try json(graph), beforeStorage = try physical(path)
    try require(pending["product_name"] == .string("Managed partial retry") && pending["tenant"] == nil,
      "Ownership must be checked from the loaded original, not only the delta")
    struct Denial: Encodable {
      let attempt: Int, effects: RootEffects, callbacks: RootCallbacks
      let rejected: Bool, intentRetained: Bool, sparseViewUnchanged: Bool, storageUnchanged: Bool
      let violations: [WireCheckResult]
    }
    var denials: [Denial] = []
    for attempt in 1...2 {
      await provider.reset(); policy.reset()
      var rejected = false, violations: [WireCheckResult] = []
      do { _ = try await graph.auditAs("Reject the loaded leaf under another active root").save(context(root: independent.id, time: t1)) }
      catch let error as CheckException { rejected = true; violations = error.violations.map { $0.wire() } }
      let effects = await provider.snapshot(), callbacks = policy.snapshot
      let denial = Denial(attempt: attempt, effects: effects, callbacks: callbacks, rejected: rejected,
        intentRetained: ledger.change(key) == pending, sparseViewUnchanged: try json(graph) == beforeView,
        storageUnchanged: try physical(path) == beforeStorage, violations: violations)
      print("CORE_SWIFT_PARTIAL_ROOT_DENIAL=" + (try json(denial)))
      try require(rejected, "Wrong-context leaf save was not rejected by Checker")
      try require(effects == RootEffects() && callbacks == RootCallbacks(), "Root rejection crossed a calibrated side-effect boundary")
      try require(denial.intentRetained && denial.sparseViewUnchanged && denial.storageUnchanged,
        "Rejected root admission changed pending intent, loaded view or physical storage")
      try require(!violations.isEmpty && violations.allSatisfy { $0.ruleId == "context_root_mismatch"
        && $0.entityType == "OrderItem" && $0.instancePath == "/purchaseOrderList/0/orderItemList/0/tenant" },
        "Root rejection lost the declaring entity or full selected ancestry")
      denials.append(denial)
    }
    await provider.reset(); policy.reset()
    _ = try await graph.auditAs("Retry the unchanged pending graph with its original context").save(context(root: 1, time: t1))
    let acceptedEffects = await provider.snapshot(), acceptedCallbacks = policy.snapshot
    try require(acceptedEffects == RootEffects(queries: 0, rootLookups: 0, mutations: 1, begins: 1, commits: 1, rollbacks: 0, audits: 1)
      && acceptedCallbacks == RootCallbacks(fixes: 1, policies: 1, reviews: 1), "Retry must update only the complete leaf")
    try require(!ledger.hasPending(key), "Successful retry did not clear the committed leaf intent")
    struct Result: Encodable {
      let language = "swift", passed = true
      let orderID: Int64, leafID: Int64, otherRootID: Int64
      let calibration: RootEffects, callbackCalibration: RootCallbacks, denials: [Denial]
      let acceptedEffects: RootEffects, acceptedCallbacks: RootCallbacks
      let sameGraphRetry = true, intentClearedAfterCommit = true, generatedImplementationsModified = false
    }
    print("CORE_SWIFT_PARTIAL_ROOT_RESULT=" + (try json(Result(orderID: saved.id, leafID: leafID, otherRootID: independent.id,
      calibration: calibration, callbackCalibration: callbackCalibration, denials: denials,
      acceptedEffects: acceptedEffects, acceptedCallbacks: acceptedCallbacks))))
  }
  private static func physical(_ path: String) throws -> String {
    var database: OpaquePointer?
    try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Read-only oracle could not open")
    defer { sqlite3_close(database) }
    var result: [String: [[String: String?]]] = [:]
    for table in ["tenant_data", "purchase_order_data", "order_item_data", "teaql_id_space"] {
      var statement: OpaquePointer?
      let order = table == "teaql_id_space" ? "type_name" : "id"
      try require(sqlite3_prepare_v2(database, "SELECT * FROM " + table + " ORDER BY " + order, -1, &statement, nil) == SQLITE_OK, "Oracle SELECT failed")
      defer { sqlite3_finalize(statement) }
      var rows: [[String: String?]] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        try require(status == SQLITE_ROW, "Oracle reader failed")
        var row: [String: String?] = [:]
        for index in 0..<sqlite3_column_count(statement) {
          let name = String(cString: sqlite3_column_name(statement, index))
          row[name] = sqlite3_column_type(statement, index) == SQLITE_NULL ? .some(nil) : .some(String(cString: sqlite3_column_text(statement, index)))
        }
        rows.append(row)
      }
      result[table] = rows
    }
    return try json(result)
  }
}
