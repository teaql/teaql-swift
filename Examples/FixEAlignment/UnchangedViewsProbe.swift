import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private enum ViewFault: String, Error, Sendable { case afterWrite, beforeCommit }
private struct ViewEffects: Codable, Equatable, Sendable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
  var fixes = 0, policies = 0, reviews = 0, clockReads = 0
  var positive: Bool { [queries, mutations, begins, commits, rollbacks, audits, fixes, policies, reviews, clockReads].allSatisfy { $0 > 0 } }
}
private actor ViewProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  let service: SQLiteDataService
  private var calls = ViewEffects(), fault: ViewFault?, observed: TeaQLRecord?
  private var injections = 0
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult { calls.queries += 1; return try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    calls.mutations += 1
    let result = try await service.execute(request)
    if fault != nil {
      guard result.affectedRows == 1, let record = result.persistedRecord, record["version"] == .int(2) else {
        throw TeaQLError.execution("Fault must follow an actual SQLite UPDATE and authoritative version-2 readback")
      }
      // The provider returns native property names; ledger diagnostics use
      // canonical model keys. Bind through trusted metadata, not guessed casing.
      var canonical: TeaQLRecord = [:]
      for property in request.mutation.entity.properties {
        if let value = record[property.name] { canonical[property.modelName ?? property.name] = value }
      }
      observed = canonical
      if fault == .afterWrite { fault = nil; injections += 1; throw ViewFault.afterWrite }
    }
    return result
  }
  func beginGraphTransaction() async throws { calls.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws {
    calls.commits += 1
    if fault == .beforeCommit {
      guard observed?["version"] == .int(2) else { throw TeaQLError.execution("COMMIT fault did not observe a real uncommitted write") }
      fault = nil; injections += 1; throw ViewFault.beforeCommit
    }
    try await service.commitGraphTransaction()
  }
  func rollbackGraphTransaction() async throws { calls.rollbacks += 1; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { calls.audits += 1 }
  func reset() { calls = ViewEffects() }
  func arm(_ value: ViewFault) { fault = value; observed = nil; injections = 0 }
  func snapshot() -> ViewEffects { calls }
  func failureEvidence() -> (Int, TeaQLRecord?) { (injections, observed) }
}
private final class ViewCallbacks: MutationPolicyRegistry, MutationPolicy, BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = ViewEffects(), time: Date
  let identity = MutationPolicyIdentity(policyID: "unchanged-views", version: "1", fingerprint: "example")
  init(_ time: Date) { self.time = time }
  func now() -> Date { lock.withLock { calls.clockReads += 1; return time } }
  func setTime(_ value: Date) { lock.withLock { time = value } }
  func fix() { lock.withLock { calls.fixes += 1 } }
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls.policies += 1 }; return self }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { calls.reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func reset() { lock.withLock { calls = ViewEffects() } }
  var snapshot: ViewEffects { lock.withLock { calls } }
}
private struct ViewChecker: EntityChecker {
  let base: any EntityChecker, callbacks: ViewCallbacks
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    callbacks.fix(); return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}

/// All business preparation uses generated Q/E/audited saves. Provider faults
/// delegate to real SQLite first; the independent CSQLite oracle is read-only.
enum UnchangedViewsProbe {
  static let cases = ["sparse-null-forward", "complete-independent-other", "empty-reverse", "rollback-after-write", "rollback-before-commit"]
  private static func require(_ condition: Bool, _ message: String) throws { if !condition { throw TeaQLError.execution(message) } }
  private static func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private static func object(_ value: PurchaseOrder) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
      throw TeaQLError.execution("Expected an entity JSON view")
    }
    return result
  }
  private static func missing<T>(_ read: () throws -> T) throws {
    do { _ = try read() } catch is TeaQLCore.TeaQLNotLoadedError { return }
    throw TeaQLError.execution("The unchanged view unexpectedly widened a NotLoaded field")
  }
  private static func emit<T: Encodable>(_ name: String, _ value: T) throws {
    FileHandle.standardOutput.write(Data(("\n" + name + "=" + (try json(value)) + "\n").utf8))
  }
  static func verify(path: String) async throws {
    var failures: [String] = []
    for name in cases {
      do { try await verifyCase(path: path + "." + name + ".sqlite", name: name) }
      catch {
        let message = "\(name): \(String(reflecting: type(of: error))): \(error)"
        try emit("SWIFT_UNCHANGED_VIEW_FAILURE", message); failures.append(message)
      }
    }
    try require(failures.isEmpty, failures.joined(separator: "\n"))
  }
  private static func verifyCase(path: String, name: String) async throws {
    let initial = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let module = GeneratedRuntimeModule.module, service = try SQLiteDataService(path: path)
    let provider = ViewProvider(service), callbacks = ViewCallbacks(initial)
    var runtime = TeaQLRuntime(); try runtime.install(module)
    var checkers: [String: any EntityChecker] = [:]
    for entity in ["Tenant", "PurchaseOrder", "OrderItem"] {
      guard let base = runtime.checker(named: entity) else { throw TeaQLError.execution("Missing generated Checker") }
      checkers[entity] = ViewChecker(base: base, callbacks: callbacks)
    }
    try runtime.install(RuntimeModule(name: "Observed unchanged views", entities: module.entities, checkers: checkers))
    let schema = UserContext(runtime: runtime, actor: "unchanged-view-schema", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, businessClock: FixedBusinessClock(initial))
    try await schema.ensureSchema(module)
    let context = UserContext(runtime: runtime, actor: "unchanged-view-example", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, auditSink: provider,
      mutationPolicyRegistry: callbacks, businessClock: callbacks)
    await provider.reset(); callbacks.reset()
    let previous = try await Q.purchaseOrders().limit(3).comment("Determine the retained unchanged-view round")
      .purpose("Run twice without resetting this scenario database").executeForList(context).count
    try require(previous == 0 || previous == 1, "Unexpected unchanged-view round boundary")
    let round = previous + 1, first = initial.addingTimeInterval(Double(previous) * 86_400), second = first.addingTimeInterval(7_200)
    callbacks.setTime(first)
    func counts() async -> ViewEffects {
      var result = await provider.snapshot(); let c = callbacks.snapshot
      result.fixes = c.fixes; result.policies = c.policies; result.reviews = c.reviews; result.clockReads = c.clockReads; return result
    }
    func reset() async { await provider.reset(); callbacks.reset() }
    var seed = try Q.purchaseOrders().comment("Prepare the unchanged-view scenario")
      .purpose("Verify loaded geometry and rollback retry through generated APIs").newEntity(context)
    seed.updateContactPhone("5550800"); seed.updateInternalNote(nil)
    let saved = try await seed.auditAs("Create the unchanged-view fixture").save(context)
    try await provider.beginGraphTransaction(); try await provider.rollbackGraphTransaction()
    let calibration = await counts(); try require(calibration.positive, "Every side-effect observer must be calibrated")
    let sparse = name == "sparse-null-forward"
    var request = sparse ? Q.purchaseOrdersWithMinimalFields().selectContactPhone().selectInternalNote() : Q.purchaseOrders()
    if name == "empty-reverse" {
      request = request.selectOrderItemListWith(Q.orderItemsWithMinimalFields().limit(1).comment("Load the explicitly empty reverse list"))
    } else {
      request = request.selectTenantWith(Q.tenantsWithMinimalFields().limit(1).comment("Load a sparse forward edge"))
    }
    let rows = try await request.withIdIs(saved.id).limit(1).comment("Load the original bounded unchanged view")
      .purpose("Retain selected null and explicit relation geometry across graph saves").executeForList(context)
    guard var row = rows.first else { throw TeaQLError.execution("Missing unchanged-view fixture") }
    let ledger = row.teaqlEntityRoot, key = row.teaqlEntityKey
    func geometry(_ value: PurchaseOrder) throws -> String {
      let object = try object(value)
      try require(try E.purchaseOrder(value).internalNote().eval() == nil && object["internalNote"] is NSNull, "Selected null lost its loaded presence")
      if sparse { try missing { try E.purchaseOrder(value).createTime().eval() }; try require(object["createTime"] == nil, "Sparse JSON widened") }
      if name == "empty-reverse" {
        try require(try E.purchaseOrder(value).orderItemList().size().eval() == 0, "The selected reverse list is not empty")
        try require((object["orderItemList"] as? [Any])?.isEmpty == true, "Selected empty reverse list disappeared from JSON")
      } else {
        try require(try E.purchaseOrder(value).tenantId().eval() == 1 && E.purchaseOrder(value).tenant().id().eval() == 1, "Loaded forward edge lost identity")
        try missing { try E.purchaseOrder(value).tenant().name().eval() }
      }
      let shape: [String: Any] = ["keys": object.keys.sorted(), "tenant": object["tenant"] ?? NSNull(), "children": object["orderItemList"] ?? NSNull()]
      return String(decoding: try JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys]), as: UTF8.self)
    }
    let beforeGeometry = try geometry(row), beforeJSON = try json(row), beforeStorage = try physical(path)
    try require(row.version == 1 && ledger.originalVersion(key) == 1, "Wrong original optimistic baseline")
    var other: PurchaseOrder?
    if name == "complete-independent-other" {
      let copies = try await Q.purchaseOrders().withIdIs(saved.id).limit(1).comment("Load an independently editable view")
        .purpose("A no-op must not drain another view's mutation ledger").executeForList(context)
      guard var value = copies.first else { throw TeaQLError.execution("Missing independent view") }
      try require(value.teaqlEntityRoot !== ledger, "Independent view shares a mutable ledger")
      value.updateInternalNote("another view remains pending"); other = value
    }
    let otherPending = other.map { $0.teaqlEntityRoot.change($0.teaqlEntityKey) }
    callbacks.setTime(second)
    let rollback = name.hasPrefix("rollback-")
    var denied: ViewEffects?, accepted: ViewEffects?, retainedIntent: TeaQLRecord?, observedWrite: TeaQLRecord?, injections = 0
    if !rollback {
      row.updateContactPhone("5550899"); row.updateContactPhone("5550800"); await reset()
      let result = try await row.auditAs("Save a restored field without refreshing its selected view").save(context)
      let effects = await counts(); try require(effects == ViewEffects(), "A no-op crossed a calibrated side-effect boundary")
      try require(try json(result) == beforeJSON && geometry(result) == beforeGeometry, "No-op changed the selected view")
      try require(result.version == 1 && ledger.originalVersion(key) == 1 && result.teaqlEntityRoot === ledger && !ledger.hasPending(key), "No-op changed ownership or original version")
      try require(other.map { $0.teaqlEntityRoot.change($0.teaqlEntityKey) } == otherPending, "No-op consumed another view's intent")
      try require(try physical(path) == beforeStorage, "No-op changed persisted data")
      denied = effects
    } else {
      row.updateContactPhone("5550801")
      let fault: ViewFault = name == "rollback-after-write" ? .afterWrite : .beforeCommit
      await provider.arm(fault); await reset(); var rejected = false
      do { _ = try await row.auditAs("Roll back the real SQLite write and preserve retry intent").save(context) }
      catch let failure as ViewFault { rejected = failure == fault }
      try require(rejected, "The exact injected transaction failure was not propagated")
      let effects = await counts(), evidence = await provider.failureEvidence()
      try require(evidence.0 == 1 && evidence.1?["version"] == .int(2) && evidence.1?["contact_phone"] == .string("5550801"), "Failure did not follow real uncommitted readback")
      try require(effects.mutations == 1 && effects.begins == 1 && effects.rollbacks == 1 && effects.audits == 0
        && effects.commits == (fault == .beforeCommit ? 1 : 0), "Failed write committed or delivered an audit")
      try require(try physical(path) == beforeStorage && geometry(row) == beforeGeometry, "Rollback lost persisted state or selected view geometry")
      try require(row.version == 1 && ledger.originalVersion(key) == 1 && row.teaqlEntityRoot === ledger, "Rollback lost original version or ledger")
      let intent = ledger.change(key)
      try require(intent["contact_phone"] == .string("5550801") && intent["update_time"] == .timestamp(Int64(second.timeIntervalSince1970 * 1_000)), "Rollback lost business or managed Fix intent")
      denied = effects; retainedIntent = intent; observedWrite = evidence.1; injections = evidence.0
      await reset()
      let result = try await row.auditAs("Retry the same Swift value and ledger without requerying").save(context)
      let success = await counts()
      try require(success == ViewEffects(queries: 0, mutations: 1, begins: 1, commits: 1, rollbacks: 0, audits: 1, fixes: 1, policies: 1, reviews: 1, clockReads: 1), "Retry performed extra work or missed normal commit governance")
      try require(result.version == 2 && result.teaqlEntityRoot === ledger && ledger.originalVersion(key) == 2 && !ledger.hasPending(key), "Retry did not accept only the committed version")
      try require(try E.purchaseOrder(result).contactPhone().eval() == "5550801" && E.purchaseOrder(result).createTime().eval() == first && E.purchaseOrder(result).updateTime().eval() == second, "Retry did not return authoritative Business Clock state")
      accepted = success
    }
    struct Observation: Encodable {
      let scenario: String, round: Int, id: Int64, passed = true, rollback: Bool
      let calibration: ViewEffects, denied: ViewEffects?, accepted: ViewEffects?
      let injections: Int, observedWrite: TeaQLRecord?, retainedIntent: TeaQLRecord?
      let geometryRetained = true, selectedNullRetained = true, independentIntentRetained = true
      let sameLedger = true, sameValueRetried: Bool, originalVersionRetained = true
      let physical: String
    }
    try emit("SWIFT_UNCHANGED_VIEW_CASE", Observation(scenario: name, round: round, id: saved.id, rollback: rollback,
      calibration: calibration, denied: denied, accepted: accepted, injections: injections, observedWrite: observedWrite,
      retainedIntent: retainedIntent, sameValueRetried: rollback, physical: try physical(path)))
  }
  private static func physical(_ path: String) throws -> String {
    var database: OpaquePointer?
    try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Cannot open the independent readonly view oracle")
    defer { sqlite3_close(database) }; var rows: [[String: String?]] = []
    var statement: OpaquePointer?
    try require(sqlite3_prepare_v2(database, "SELECT id,version,contact_phone,internal_note,create_time,update_time FROM purchase_order_data ORDER BY id", -1, &statement, nil) == SQLITE_OK, "Cannot prepare readonly view oracle")
    defer { sqlite3_finalize(statement) }
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      var value: [String: String?] = [:]
      for index in 0..<sqlite3_column_count(statement) {
        let field = String(cString: sqlite3_column_name(statement, index))
        value[field] = sqlite3_column_type(statement, index) == SQLITE_NULL ? .some(nil) : .some(String(cString: sqlite3_column_text(statement, index)))
      }
      rows.append(value); status = sqlite3_step(statement)
    }
    try require(status == SQLITE_DONE, "Readonly view oracle failed")
    return try json(rows)
  }
}
