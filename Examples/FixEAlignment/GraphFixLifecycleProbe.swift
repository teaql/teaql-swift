import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private enum LifecycleFault: Error, Sendable { case afterChildWrite }
private struct LifecycleEffects: Codable, Equatable, Sendable {
  var queries = 0, parentWrites = 0, childWrites = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}
private final class LifecycleProvider: QueryExecutor, GraphTransactionExecutor, AuditSink, @unchecked Sendable {
  let service: SQLiteDataService
  private let lock = NSLock()
  private var calls = LifecycleEffects(), fault = false, cancel = false
  private var observedChild: TeaQLRecord?
  private var callback: (@Sendable () -> Void)?
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    lock.withLock { calls.queries += 1 }; return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    lock.withLock {
      if request.mutation.entity.name == "PurchaseOrder" { calls.parentWrites += 1 }
      if request.mutation.entity.name == "OrderItem" { calls.childWrites += 1 }
    }
    let result = try await service.execute(request)
    if request.mutation.entity.name == "OrderItem" {
      let action = lock.withLock { () -> (Bool, Bool, (@Sendable () -> Void)?) in
        observedChild = result.persistedRecord
        let result = (fault, cancel, callback); fault = false; cancel = false; callback = nil; return result
      }
      action.2?()
      if action.0 { throw LifecycleFault.afterChildWrite }
      if action.1 { withUnsafeCurrentTask { $0?.cancel() } }
    }
    return result
  }
  func beginGraphTransaction() async throws { lock.withLock { calls.begins += 1 }; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { lock.withLock { calls.commits += 1 }; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { lock.withLock { calls.rollbacks += 1 }; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { lock.withLock { calls.audits += 1 } }
  var snapshot: LifecycleEffects { lock.withLock { calls } }
  var childReadback: TeaQLRecord? { lock.withLock { observedChild } }
  func reset() { lock.withLock { calls = LifecycleEffects(); observedChild = nil } }
  func arm(failure: Bool = false, cancellation: Bool = false, callback: (@Sendable () -> Void)? = nil) {
    lock.withLock { fault = failure; cancel = cancellation; self.callback = callback }
  }
}
private final class LifecycleClock: BusinessClock, @unchecked Sendable {
  let base: Date
  private let lock = NSLock()
  private var reads = 0
  init(_ base: Date) { self.base = base }
  func now() -> Date { lock.withLock { defer { reads += 1 }; return base.addingTimeInterval(Double(reads)) } }
  var calls: Int { lock.withLock { reads } }
}
private struct LifecycleVisit: Codable, Sendable {
  let entity: String, before: LifecycleEffects, after: LifecycleEffects
  let millis: Int64
}
private final class LifecycleVisits: @unchecked Sendable {
  private let lock = NSLock()
  private var rows: [LifecycleVisit] = []
  func add(_ row: LifecycleVisit) { lock.withLock { rows.append(row) } }
  func reset() { lock.withLock { rows = [] } }
  var values: [LifecycleVisit] { lock.withLock { rows } }
}
private struct LifecycleChecker: EntityChecker {
  let original: any EntityChecker, provider: LifecycleProvider, visits: LifecycleVisits
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    let before = provider.snapshot
    defer { visits.add(LifecycleVisit(entity: mutation.entity.name, before: before, after: provider.snapshot,
      millis: Int64(now.timeIntervalSince1970 * 1000))) }
    if mutation.entity.name == "OrderItem", case .decimal(let value) = mutation.values["unit_price"] {
      mutation.values["unit_price"] = .decimal(value + Decimal(string: "0.01")!)
    }
    return try original.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}
private final class LifecyclePolicy: MutationPolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0, callback: (@Sendable () -> Void)?
  let identity = MutationPolicyIdentity(policyID: "swift-graph-lifecycle", version: "1", fingerprint: "generated-save-example")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    let action = lock.withLock { count += 1; return callback }; action?()
    return MutationPolicyDecision(verdict: .allow)
  }
  func arm(_ value: (@Sendable () -> Void)?) { lock.withLock { callback = value } }
  func reset() { lock.withLock { count = 0 } }
  var calls: Int { lock.withLock { count } }
}

/// Generated public Q/E and audited save are the business APIs. Provider seams
/// observe real SQLite writes and inject faults only after a child was written.
enum GraphFixLifecycleProbe {
  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TeaQLError.execution(message) }
  }
  private static func emit<T: Encodable>(_ marker: String, _ row: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(row)
    FileHandle.standardOutput.write(Data(("\n" + marker + "=" + String(decoding: bytes, as: UTF8.self) + "\n").utf8))
  }
  static func verify(path: String, round: Int) async throws {
    try require([1, 2].contains(round), "An explicit unreset graph lifecycle round is required")
    let service = try SQLiteDataService(path: path), provider = LifecycleProvider(service)
    let visits = LifecycleVisits(), policy = LifecyclePolicy(), module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let schema = UserContext(runtime: runtime, actor: "swift-graph-schema",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)), queryExecutor: service,
      mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      businessClock: FixedBusinessClock(Date(timeIntervalSince1970: 2_145_916_800)))
    try await schema.ensureSchema(module)
    var checkers: [String: any EntityChecker] = [:]
    for name in ["Tenant", "PurchaseOrder", "OrderItem"] {
      guard let original = runtime.checker(named: name) else { throw TeaQLError.execution("Missing generated Checker") }
      checkers[name] = LifecycleChecker(original: original, provider: provider, visits: visits)
    }
    try runtime.install(RuntimeModule(name: "Graph lifecycle observations", entities: [], checkers: checkers))
    func context(_ clock: any BusinessClock) -> UserContext {
      UserContext(runtime: runtime, actor: "swift-graph-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)), queryExecutor: provider,
        mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, auditSink: provider,
        mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy }, businessClock: clock)
    }
    let preparation = context(FixedBusinessClock(Date(timeIntervalSince1970: 2_145_916_800)))
    var ordinal = 0, emitted = 0
    func begin() -> (UserContext, LifecycleClock) {
      ordinal += 1; provider.reset(); visits.reset(); policy.reset()
      let clock = LifecycleClock(Date(timeIntervalSince1970: 2_145_916_800 + Double(round * 3600 + ordinal * 60)))
      return (context(clock), clock)
    }
    func newGraph(_ label: String, valid: Bool = true) throws -> PurchaseOrder {
      var parent = try Q.purchaseOrders().comment("Prepare a graph lifecycle parent")
        .purpose("Verify generated graph transaction boundaries").newEntity(preparation)
      parent.updateContactPhone("5550811"); parent.updateInternalNote(nil)
      var child = try Q.orderItems().comment("Prepare a graph lifecycle child")
        .purpose("Verify duplicate references and non-idempotent customer Fix").newEntity(preparation)
      if valid { child.updateProductName(label + "-" + String(round)) }
      child.updateUnitPrice(Decimal(string: "10.00")!)
      parent.orderItemList.append(child); parent.orderItemList.append(child)
      return parent
    }
    func reload(_ id: Int64) async throws -> PurchaseOrder {
      let rows = try await Q.purchaseOrders().withIdIs(id)
        .selectOrderItemListWith(Q.orderItems().limit(10)).limit(1)
        .comment("Reload the complete saved graph").purpose("Verify E values and optimistic versions")
        .executeForList(preparation)
      try require(rows.count == 1, "Missing graph parent"); return rows[0]
    }
    func check(_ parent: PurchaseOrder, price: String, parentVersion: Int64, childVersion: Int64) async throws {
      let persisted = try await reload(parent.id)
      try require(persisted.version == parentVersion && persisted.orderItemList.count == 1, "Persisted graph cardinality/version mismatch")
      let child = persisted.orderItemList[0]
      try require(child.version == childVersion && (try E.orderItem(child).unitPrice().eval()) == Decimal(string: price)
        && (try E.orderItem(child).purchaseOrderId().eval()) == parent.id, "Persisted customer Fix/FK mismatch")
    }
    struct Observation: Encodable {
      let name: String, round: Int, passed: Bool, clockReads: Int, millis: Int64
      let visits: [LifecycleVisit], effects: LifecycleEffects, policyCalls: Int
      let error: String?
    }
    func observe(_ name: String, _ clock: LifecycleClock, expectedVisits: Int = 2,
      condition: Bool, error: (any Error)? = nil) throws {
      let rows = visits.values, time = Int64(clock.base.timeIntervalSince1970 * 1000)
      let once = rows.count == expectedVisits && rows.allSatisfy { $0.millis == time && $0.before == LifecycleEffects() && $0.after == LifecycleEffects() }
      let row = Observation(name: name, round: round, passed: condition && once && clock.calls == 1,
        clockReads: clock.calls, millis: time, visits: rows, effects: provider.snapshot,
        policyCalls: policy.calls, error: error.map { String(reflecting: type(of: $0)) + ": " + String(describing: $0) })
      try emit("SWIFT_GRAPH_LIFECYCLE_CASE", row); try require(row.passed, "Graph lifecycle case failed: " + name); emitted += 1
    }
    func expected(_ parents: Int, _ children: Int, committed: Bool = true) -> LifecycleEffects {
      LifecycleEffects(queries: 0, parentWrites: parents, childWrites: children, begins: 1,
        commits: committed ? 1 : 0, rollbacks: committed ? 0 : 1, audits: committed ? parents + children : 0)
    }
    func failed(_ value: PurchaseOrder, _ context: UserContext) async throws -> any Error {
      let task = Task { try await value.auditAs("Attempt a controlled graph failure").save(context) }
      do { _ = try await task.value } catch { return error }
      throw TeaQLError.execution("Controlled graph failure unexpectedly committed")
    }

    var primary = try newGraph("customer-fix")
    var (execution, clock) = begin()
    primary = try await primary.auditAs("Create the repeated-child graph").save(execution)
    try observe("customer-fix-create-duplicate", clock,
      condition: provider.snapshot == expected(1, 1) && policy.calls == 1)
    try require(primary.orderItemList.count == 2 && primary.orderItemList[0].id == primary.orderItemList[1].id,
      "Both returned references must resolve to the same persisted child")
    try await check(primary, price: "10.01", parentVersion: 1, childVersion: 1)

    var loaded = try await reload(primary.id)
    loaded.orderItemList.append(loaded.orderItemList[0])
    loaded.updateContactPhone("5550812"); loaded.orderItemList[0].updateUnitPrice(Decimal(string: "20.00")!)
    (execution, clock) = begin()
    loaded = try await loaded.auditAs("Update through one value copy of a repeated child").save(execution)
    try observe("customer-fix-update-duplicate", clock,
      condition: provider.snapshot == expected(1, 1) && policy.calls == 1)
    try await check(loaded, price: "20.01", parentVersion: 2, childVersion: 2)

    loaded = try await reload(primary.id); loaded.orderItemList.append(loaded.orderItemList[0])
    loaded.orderItemList[0].updateUnitPrice(Decimal(string: "30.00")!)
    (execution, clock) = begin()
    loaded = try await loaded.auditAs("Save only a changed child under an unchanged owner").save(execution)
    try observe("customer-fix-child-only", clock, expectedVisits: 1,
      condition: provider.snapshot == expected(0, 1) && policy.calls == 1)
    try await check(loaded, price: "30.01", parentVersion: 2, childVersion: 3)

    for cancelled in [false, true] {
      let label = cancelled ? "cancel-retry" : "provider-retry", graph = try newGraph(label)
      (execution, clock) = begin(); provider.arm(failure: !cancelled, cancellation: cancelled)
      let error = try await failed(graph, execution)
      try observe(cancelled ? "provider-cancellation" : "provider-write-failure", clock,
        condition: provider.snapshot == expected(1, 1, committed: false) && policy.calls == 1
          && provider.childReadback?["version"] == .int(1) && graph.id == 0
          && (cancelled ? error is CancellationError : error is LifecycleFault), error: error)
      let absent = try await Q.orderItems().withProductNameIs(label + "-" + String(round)).limit(1)
        .comment("Verify the failed real child insert was rolled back")
        .purpose("Do not mistake a thrown error for atomic persistence").executeForList(preparation)
      try require(absent.isEmpty, "Failed child row remained in SQLite")
      (execution, clock) = begin()
      let saved = try await graph.auditAs("Retry the exact same failed object graph").save(execution)
      try observe(cancelled ? "same-graph-cancellation-retry" : "same-graph-provider-retry", clock,
        condition: provider.snapshot == expected(1, 1) && policy.calls == 1)
      try await check(saved, price: "10.01", parentVersion: 1, childVersion: 1)
    }

    var invalid = try newGraph("missing-input", valid: false)
    (execution, clock) = begin(); let missing = try await failed(invalid, execution)
    try observe("missing-child-input-before-io", clock,
      condition: provider.snapshot == LifecycleEffects() && policy.calls == 0 && missing is CheckException, error: missing)
    invalid.orderItemList[0].updateProductName("repaired-input-" + String(round))
    (execution, clock) = begin()
    let repaired = try await invalid.auditAs("Repair and retry the same invalid child").save(execution)
    try observe("same-graph-input-repair", clock, condition: provider.snapshot == expected(1, 1) && policy.calls == 1)
    try await check(repaired, price: "10.01", parentVersion: 1, childVersion: 1)

    for duringWrite in [false, true] {
      loaded = try await reload(primary.id); loaded.orderItemList.append(loaded.orderItemList[0])
      let phone = duringWrite ? "5550819" : "5550818", price = duringWrite ? "50.00" : "40.00"
      loaded.updateContactPhone(phone); loaded.orderItemList[0].updateUnitPrice(Decimal(string: price)!)
      let captured = loaded
      let edit: @Sendable () -> Void = { var changed = captured; changed.updateContactPhone("5550999") }
      (execution, clock) = begin()
      if duringWrite { provider.arm(callback: edit) } else { policy.arm(edit) }
      let error = try await failed(loaded, execution); policy.arm(nil)
      try observe(duringWrite ? "late-provider-edit-rollback" : "late-policy-edit-before-io", clock,
        condition: provider.snapshot == (duringWrite ? expected(1, 1, committed: false) : LifecycleEffects())
          && policy.calls == 1 && error is MutationPolicyError, error: error)
      try require(loaded.teaqlEntityRoot.change(loaded.teaqlEntityKey)["contact_phone"] == .string("5550999"),
        "Rejected save lost the newer customer edit")
      loaded.updateContactPhone(phone); loaded.orderItemList[0].updateUnitPrice(Decimal(string: price)!)
      (execution, clock) = begin()
      let saved = try await loaded.auditAs("Retry after removing a late edit callback").save(execution)
      try observe(duringWrite ? "same-graph-provider-edit-retry" : "same-graph-policy-edit-retry", clock,
        condition: provider.snapshot == expected(1, 1) && policy.calls == 1)
      primary = saved
    }
    try require(emitted == 13, "Every graph lifecycle case must run")
    struct Result: Encodable { let round: Int, cases: Int, passed: Bool }
    try emit("SWIFT_GRAPH_LIFECYCLE_RESULT", Result(round: round, cases: emitted, passed: true))
  }
}
