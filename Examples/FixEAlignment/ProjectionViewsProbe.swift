import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct ProjectionEffects: Codable, Equatable, Sendable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0, policies = 0
  static func - (a: Self, b: Self) -> Self {
    Self(queries: a.queries-b.queries, mutations: a.mutations-b.mutations,
      begins: a.begins-b.begins, commits: a.commits-b.commits,
      rollbacks: a.rollbacks-b.rollbacks, audits: a.audits-b.audits, policies: a.policies-b.policies)
  }
}
private actor ProjectionProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  let service: SQLiteDataService
  private var calls = ProjectionEffects()
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
  func snapshot() -> ProjectionEffects { calls }
}
private final class ProjectionPolicies: MutationPolicyRegistry, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls += 1 }; return nil }
  var count: Int { lock.withLock { calls } }
}
private final class ProjectionClock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.withLock { value } }
  func set(_ value: Date) { lock.withLock { self.value = value } }
}

/// Ordinary generated Q/E/audited saves, not custom application hydration.
enum ProjectionViewsProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
    else { throw TeaQLError.execution("Expected a generated object JSON view") }
    return result
  }
  private static func missing<T>(_ read: () throws -> T) throws {
    do { _ = try read() }
    catch is TeaQLCore.TeaQLNotLoadedError { return }
    throw TeaQLError.execution("An explicitly sparse projection was widened")
  }
  static func verify(path: String) async throws {
    let initial = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let service = try SQLiteDataService(path: path), provider = ProjectionProvider(service)
    let policies = ProjectionPolicies(), clock = ProjectionClock(initial)
    let schema = UserContext(runtime: runtime, actor: "projection-schema",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, businessClock: clock)
    try await schema.ensureSchema(module)
    let context = UserContext(runtime: runtime, actor: "projection-example",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      auditSink: provider, mutationPolicyRegistry: policies, businessClock: clock)
    let previous = try await Q.purchaseOrders().limit(7).comment("Determine the retained projection round")
      .purpose("Run twice without resetting the projection database").executeForList(context).count
    try require(previous == 0 || previous == 3, "Unexpected projection database round boundary")
    let round = previous / 3 + 1, first = initial.addingTimeInterval(Double(previous / 3) * 86_400)
    let second = first.addingTimeInterval(7_200); clock.set(first)
    func counts() async -> ProjectionEffects {
      var result = await provider.snapshot(); result.policies = policies.count; return result
    }
    func seed() async throws -> PurchaseOrder {
      var row = try Q.purchaseOrders().comment("Prepare an independent query-view fixture")
        .purpose("Verify projection boundaries and independent mutation ledgers").newEntity(context)
      row.updateContactPhone("5550700"); row.updateInternalNote(nil)
      let before = await counts()
      let saved = try await row.auditAs("Create the projection fixture through generated mutation").save(context)
      let effects = await counts() - before
      try require(effects.mutations == 1 && effects.begins == 1 && effects.commits == 1
        && effects.rollbacks == 0 && effects.audits == 1 && effects.policies > 0,
        "Real generated creation must calibrate every mutation observer")
      return saved
    }
    func full(_ id: Int64) async throws -> PurchaseOrder {
      let rows = try await Q.purchaseOrders().withIdIs(id).limit(1)
        .comment("Load a complete independent order view").purpose("Compare explicit views of one stored identity")
        .executeForList(context)
      try require(rows.count == 1, "Missing complete projection fixture"); return rows[0]
    }
    func report(_ name: String, _ row: PurchaseOrder, _ facts: [String: Any]) throws {
      let payload: [String: Any] = ["round": round, "case": name, "orderId": String(row.id), "passed": true, "facts": facts]
      print("SWIFT_PROJECTION_VIEW_CASE=" + String(decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), as: UTF8.self))
    }

    let one = try await seed()
    let sparseRows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(one.id).limit(1)
      .comment("Retain an explicitly sparse order view").purpose("A later complete query must not widen it")
      .executeForList(context)
    try require(sparseRows.count == 1, "Missing sparse projection fixture")
    let sparse = sparseRows[0], sparseJSON = try json(sparse), wide = try await full(one.id)
    let beforeReads = await counts()
    try require(sparse.id == wide.id && sparse.teaqlEntityRoot !== wide.teaqlEntityRoot,
      "Separate queries must retain separate mutable projection ledgers")
    try missing { try E.purchaseOrder(sparse).contactPhone().eval() }
    try missing { try E.purchaseOrder(sparse).internalNote().eval() }
    try require(try json(sparse) == sparseJSON, "Complete query changed an earlier sparse JSON view")
    let sparseObject = try object(sparse), wideObject = try object(wide)
    try require(sparseObject["contactPhone"] == nil && sparseObject["internalNote"] == nil,
      "Sparse JSON exposes an unselected scalar")
    try require(try E.purchaseOrder(wide).internalNote().eval() == nil && wideObject["internalNote"] is NSNull,
      "Selected null became NotLoaded or disappeared from JSON")
    try require(await counts() == beforeReads && sparse.teaqlEntityRoot.snapshot().isEmpty
      && wide.teaqlEntityRoot.snapshot().isEmpty, "Hydration or E/JSON performed implicit work")
    try require(try E.purchaseOrder(sparse).version().eval() == 1 && E.purchaseOrder(wide).version().eval() == 1,
      "Read changed optimistic identity")
    try report("independent-query-projection-boundary", one, ["sameIdentity": true, "separateViews": true,
      "sparseJsonUnchanged": true, "sparseJsonOmitsFields": true, "wideNullIsLoaded": true,
      "implicitProviderCalls": 0, "hydrationDirtyKeys": 0, "version": 1])

    let two = try await seed()
    var left = try await full(two.id), other = try await full(two.id)
    try require(left.teaqlEntityRoot !== other.teaqlEntityRoot, "Independent views share a mutable ledger")
    left.updateContactPhone("5550701"); other.updateInternalNote("pending-other-view")
    let key = other.teaqlEntityKey, ledger = other.teaqlEntityRoot
    try require(left.teaqlEntityRoot.change(left.teaqlEntityKey) == ["contact_phone": .string("5550701")]
      && ledger.change(key) == ["internal_note": .string("pending-other-view")], "Pending edits leaked between views")
    clock.set(second)
    _ = try await left.auditAs("Save only the first independent view").save(context)
    let stored = try await full(two.id)
    try require(try E.purchaseOrder(stored).contactPhone().eval() == "5550701"
      && E.purchaseOrder(stored).internalNote().eval() == nil && E.purchaseOrder(stored).version().eval() == 2,
      "Saving one view persisted another view's pending edit")
    try require(try E.purchaseOrder(other).version().eval() == 1 && ledger.originalVersion(key) == 1
      && ledger.change(key)["internal_note"] == .string("pending-other-view"), "Save changed another view's pending edit or version")
    let beforeReject = await counts()
    var errorType: String?, message: String?
    do { _ = try await other.auditAs("Reject a stale independent view without losing pending intent").save(context) }
    catch { errorType = String(reflecting: type(of: error)); message = String(describing: error) }
    let effects = await counts() - beforeReject
    struct Rejection: Encodable { let round: Int, orderId: String, errorType: String?, message: String?, effects: ProjectionEffects }
    print("SWIFT_STALE_VIEW_OBSERVATION=" + (try json(Rejection(round: round, orderId: String(two.id), errorType: errorType, message: message, effects: effects))))
    try require(errorType != nil, "A stale independent view was accepted")
    try require(effects.begins == 1 && effects.mutations == 1 && effects.rollbacks == 1
      && effects.commits == 0 && effects.audits == 0 && effects.queries == 0, "Stale save committed, audited or performed unrelated work")
    let pending = ledger.change(key)
    struct Pending: Encodable { let round: Int, keys: [String], values: TeaQLRecord }
    print("SWIFT_PENDING_VIEW_OBSERVATION=" + (try json(Pending(round: round, keys: pending.keys.sorted(), values: pending))))
    try require(try E.purchaseOrder(other).version().eval() == 1 && ledger.originalVersion(key) == 1
      && pending["internal_note"] == .string("pending-other-view"), "Rejection lost intent or changed its original version")
    let derived = pending.keys.filter { $0 != "internal_note" }.sorted()
    try require(derived == ["update_time"] && pending["update_time"] == .timestamp(Int64(second.timeIntervalSince1970 * 1_000)),
      "Only the exact managed BusinessClock Fix may be added to pending intent")
    try report("same-identity-independent-mutation-ledgers", two, ["separateViews": true, "otherPendingEditRetained": true,
      "noCrossViewWrite": true, "staleException": errorType!, "storedVersion": 2, "otherVersion": 1,
      "derivedFixFields": derived, "rejectionRolledBack": true, "commitAuditsOnRejection": 0])

    clock.set(first)
    let three = try await seed()
    let roots = try await Q.tenantsWithMinimalFields().withIdIs(1)
      .selectPurchaseOrderListWith(Q.purchaseOrdersWithMinimalFields().withIdIs(three.id)
        .selectTenantWith(Q.tenants().limit(1).comment("Load the full nested alias of the sparse root"))
        .limit(1).comment("Load one parent between two views of the root identity"))
      .limit(1).comment("Keep sparse root and complete nested alias independent")
      .purpose("One query must preserve each explicit projection boundary").executeForList(context)
    try require(roots.count == 1, "Missing repeated-identity projection root")
    let root = roots[0], beforeNested = await counts(), e = E.tenant(root)
    try require(try e.id().eval() == e.purchaseOrderList().first().tenant().id().eval(), "The repeated identity is not the same persisted root")
    try missing { try e.name().eval() }
    try require(try e.purchaseOrderList().first().tenant().name().eval() == "Tenant Name", "Full nested alias lost its name")
    let rootJSON = try object(root), orders = rootJSON["purchaseOrderList"] as? [[String: Any]]
    let nested = orders?.first?["tenant"] as? [String: Any]
    try require(rootJSON["name"] == nil && nested?["name"] as? String == "Tenant Name", "JSON merged two distinct projection boundaries")
    try require(await counts() == beforeNested, "Nested E/JSON caused hidden provider work")
    try report("intra-query-repeated-identity-projection-boundary", three, ["sameIdentity": true,
      "sparseRootNameNotLoaded": true, "nestedTargetNameLoaded": true, "jsonRespectsBothViews": true, "implicitProviderCalls": 0])
  }
}
