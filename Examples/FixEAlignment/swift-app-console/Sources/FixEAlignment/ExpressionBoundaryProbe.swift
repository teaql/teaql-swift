import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct ExpressionEffects: Codable, Equatable, Sendable {
  var queries = 0, rootLookups = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}
private actor ExpressionProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var effects = ExpressionEffects()
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
  func snapshot() -> ExpressionEffects { effects }
}
private struct ExpressionCallbacks: Codable, Equatable { var fixes = 0, policies = 0, reviews = 0 }
private final class ExpressionPolicy: MutationPolicyRegistry, MutationPolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = ExpressionCallbacks()
  let identity = MutationPolicyIdentity(policyID: "expression-example", version: "1", fingerprint: "fixture")
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls.policies += 1 }; return self }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { calls.reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func fix() { lock.withLock { calls.fixes += 1 } }
  var snapshot: ExpressionCallbacks { lock.withLock { calls } }
}
private struct ExpressionChecker: EntityChecker {
  let base: any EntityChecker
  let policy: ExpressionPolicy
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    policy.fix(); return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}

/// Actual generated Q/E/save graphs. Private ledger reads are test instrumentation,
/// not an application API or an alternative persistence implementation.
enum ExpressionBoundaryProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  private static func object<T: Encodable>(_ value: T) throws -> Any {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try JSONSerialization.jsonObject(with: encoder.encode(value))
  }
  private static func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
  }
  private static func missing<T>(_ read: () throws -> T, path: String, attempted: String,
      point: String, index: Int, chain: String, native: String) throws -> [String: Any] {
    do { _ = try read() }
    catch let error as TeaQLCore.TeaQLNotLoadedError {
      let wire = error.toWire()
      let fields = try object(wire) as! [String: Any]
      try require(Set(fields.keys) == Set(["code", "location", "instancePath", "breakPoint", "attemptedLocation",
        "attemptedInstancePath", "breakPointIndex", "originalExpression", "expressionWithBrokenPoint", "suggestedFix"]), "E wire schema changed")
      try require(wire.code == "NOT_LOADED" && wire.instancePath == path && wire.attemptedInstancePath == attempted,
        "Wrong first-missing or full attempted path")
      try require(wire.breakPoint == point && wire.breakPointIndex == index, "Wrong canonical failure position")
      try require(wire.expressionWithBrokenPoint == chain && wire.originalExpression == chain.replacingOccurrences(of: "<broken>", with: ""),
        "Lost a native suffix or terminal")
      try require(chain.components(separatedBy: "<broken>").count == 2, "More than one broken marker")
      let human = "TeaQLNotLoadedError: access_path=\(native) break_point=\(point) — select the missing field or relation expression=\(chain)"
      try require(error.description == human, "Human and machine E diagnostics disagree")
      try require(!(try json(fields)).contains("PRIVATE_SWIFT_E_") && !human.contains("PRIVATE_SWIFT_E_"), "E leaked fallback input")
      return ["wire": fields, "human": human]
    }
    throw TeaQLError.execution("NotLoaded was hidden by an E terminal")
  }
  static func verify(path: String, round: Int) async throws {
    try require(round == 1 || round == 2, "Use an explicit unreset round")
    let time = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let service = try SQLiteDataService(path: path), provider = ExpressionProvider(service), policy = ExpressionPolicy()
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    var checkers: [String: any EntityChecker] = [:]
    for name in ["Tenant", "PurchaseOrder", "OrderItem"] {
      guard let base = runtime.checker(named: name) else { throw TeaQLError.execution("Missing module Checker") }
      checkers[name] = ExpressionChecker(base: base, policy: policy)
    }
    try runtime.install(RuntimeModule(name: "Observed E graph", entities: module.entities, checkers: checkers))
    let schema = UserContext(runtime: runtime, actor: "expression-schema", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, businessClock: FixedBusinessClock(time))
    try await schema.ensureSchema(module)
    let context = UserContext(runtime: runtime, actor: "expression-example", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, auditSink: provider,
      mutationPolicyRegistry: policy, businessClock: FixedBusinessClock(time))
    var draft = try await Q.purchaseOrders().comment("Prepare the bounded expression graph")
      .purpose("Verify generated E failures without implicit work").newEntity(context)
    draft.updateContactPhone("5550960"); draft.updateInternalNote(nil)
    for i in 0..<3 {
      var child = try await Q.orderItems().comment("Prepare an expression item").purpose("Exercise real list indices").newEntity(context)
      child.updateProductName("Expression item \(i)"); child.updateUnitPrice(Decimal(string: "10.00")!)
      draft.orderItemList.append(child)
    }
    var saved = try await draft.auditAs("Create the expression graph").save(context)
    var empty = try await Q.purchaseOrders().comment("Prepare a loaded-empty owner").purpose("Distinguish empty from NotLoaded").newEntity(context)
    empty.updateContactPhone("5550962"); empty.updateInternalNote(nil)
    let savedEmpty = try await empty.auditAs("Create the empty expression control").save(context)
    saved.updateContactPhone("5550961")
    _ = try await saved.auditAs("Calibrate actual update and audit boundaries").save(context)
    try await provider.beginGraphTransaction(); try await provider.rollbackGraphTransaction()
    let fullRows = try await Q.purchaseOrders().withIdIs(saved.id)
      .selectOrderItemListWith(Q.orderItems().limit(10).comment("Load complete selected items"))
      .limit(1).comment("Load the complete E graph").purpose("Keep E inside loaded data").executeForList(context)
    let emptyRows = try await Q.purchaseOrders().withIdIs(savedEmpty.id)
      .selectOrderItemListWith(Q.orderItems().limit(10).comment("Explicitly load the empty list"))
      .limit(1).comment("Load an empty E graph").purpose("Preserve loaded empty semantics").executeForList(context)
    let fkRows = try await Q.purchaseOrders().withIdIs(saved.id).limit(1)
      .comment("Load only scalar foreign-key detail").purpose("Do not invent a fetched relation target").executeForList(context)
    let lateRows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(saved.id)
      .selectTenantWith(Q.tenantsWithMinimalFields().limit(1).comment("Select only target identity"))
      .limit(1).comment("Load an identity-only target").purpose("Put the failure at its missing leaf").executeForList(context)
    let indexedRows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(saved.id)
      .selectOrderItemListWith(Q.orderItemsWithMinimalFields().limit(10).comment("Select only item identities"))
      .limit(1).comment("Load sparse indexed targets").purpose("Preserve numeric index location").executeForList(context)
    try require([fullRows.count, emptyRows.count, fkRows.count, lateRows.count, indexedRows.count].allSatisfy { $0 == 1 }, "Missing E fixture row")
    let full = fullRows[0], loadedEmpty = emptyRows[0], fk = fkRows[0], late = lateRows[0], indexed = indexedRows[0]
    let calibration = await provider.snapshot(), callbackCalibration = policy.snapshot
    let positive = try object(calibration) as! [String: Int], callbacks = try object(callbackCalibration) as! [String: Int]
    try require(positive.values.allSatisfy { $0 > 0 } && callbacks.values.allSatisfy { $0 > 0 }, "Uncalibrated E observer")
    let views = [full, loadedEmpty, fk, late, indexed], roots = views.map(\.teaqlEntityRoot)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(views), pending = views.map { $0.teaqlEntityRoot.change($0.teaqlEntityKey) }
    var names: [String] = []
    func emit(_ name: String, _ value: Any) throws {
      names.append(name)
      print("SWIFT_E_BOUNDARY_CASE=" + (try json(["name": name, "value": value, "round": round, "passed": true])))
    }
    let prefix = "E.purchaseOrder(<root>)"
    try emit("late-leaf", missing({ try E.purchaseOrder(late).tenant().name().eval() }, path: "/tenant/name", attempted: "/tenant/name",
      point: "name", index: 1, chain: prefix + ".tenant().name()<broken>.eval()", native: "tenant.name"))
    try emit("indexed-leaf", missing({ try E.purchaseOrder(indexed).orderItemList().get(2).productName().eval() }, path: "/orderItemList/2/productName", attempted: "/orderItemList/2/productName",
      point: "product_name", index: 2, chain: prefix + ".orderItemList().get(2).productName()<broken>.eval()", native: "orderItemList[2].productName"))
    try emit("first-indexed-leaf", missing({ try E.purchaseOrder(indexed).orderItemList().first().productName().eval() }, path: "/orderItemList/0/productName", attempted: "/orderItemList/0/productName",
      point: "product_name", index: 2, chain: prefix + ".orderItemList().first().productName()<broken>.eval()", native: "orderItemList[0].productName"))
    try require(try E.purchaseOrder(full).internalNote().eval() == nil, "Loaded null became a value")
    try require(try E.purchaseOrder(full).internalNote().isPresent(), "Selected null lost presence")
    try require(try E.purchaseOrder(full).internalNote().orElse("PRIVATE_SWIFT_E_NULL") == "PRIVATE_SWIFT_E_NULL", "Null fallback failed")
    try emit("loaded-null", ["value": NSNull(), "present": true, "fallbackUsed": true])
    try require(try E.purchaseOrder(loadedEmpty).orderItemList().size().eval() == 0, "Empty list size changed")
    try require(try E.purchaseOrder(loadedEmpty).orderItemList().first().productName().eval() == nil, "Empty first value changed")
    try require(try !E.purchaseOrder(loadedEmpty).orderItemList().first().productName().isPresent(), "Empty first became present")
    try emit("loaded-empty", ["size": 0, "value": NSNull(), "present": false])
    for index in [-1, 3] {
      try require(try E.purchaseOrder(full).orderItemList().get(index).productName().eval() == nil, "Out-of-range became a value")
      try require(try !E.purchaseOrder(full).orderItemList().get(index).productName().isPresent(), "Out-of-range became present")
    }
    try emit("out-of-range", ["negativeIndex": -1, "index": 3, "value": NSNull(), "present": false])
    try emit("missing-list-size", missing({ try E.purchaseOrder(fk).orderItemList().size().eval() }, path: "/orderItemList", attempted: "/orderItemList",
      point: "order_item_list", index: 0, chain: prefix + ".orderItemList()<broken>.size().eval()", native: "orderItemList"))
    let missing = E.purchaseOrder(fk).tenant().name()
    let terminals = [
      try self.missing({ try missing.eval() }, path: "/tenant", attempted: "/tenant/name", point: "tenant", index: 0,
        chain: prefix + ".tenant()<broken>.name().eval()", native: "tenant"),
      try self.missing({ try missing.orElse("PRIVATE_SWIFT_E_FALLBACK") }, path: "/tenant", attempted: "/tenant/name", point: "tenant", index: 0,
        chain: prefix + ".tenant()<broken>.name().orElse(<fallback>)", native: "tenant"),
      try self.missing({ try missing.isPresent() }, path: "/tenant", attempted: "/tenant/name", point: "tenant", index: 0,
        chain: prefix + ".tenant()<broken>.name().isPresent()", native: "tenant")]
    try emit("terminals", ["observations": terminals])
    let expression = E.purchaseOrder(fk), left = expression.tenant().name(), right = expression.orderItemList().get(2).productName()
    let leftBefore = try self.missing({ try left.eval() }, path: "/tenant", attempted: "/tenant/name", point: "tenant", index: 0,
      chain: prefix + ".tenant()<broken>.name().eval()", native: "tenant")
    let rightFailure = try self.missing({ try right.eval() }, path: "/orderItemList", attempted: "/orderItemList/2/productName", point: "order_item_list", index: 0,
      chain: prefix + ".orderItemList()<broken>.get(2).productName().eval()", native: "orderItemList")
    let leftAfter = try self.missing({ try left.eval() }, path: "/tenant", attempted: "/tenant/name", point: "tenant", index: 0,
      chain: prefix + ".tenant()<broken>.name().eval()", native: "tenant")
    try require(try json(leftBefore) == json(leftAfter), "A sibling changed the original path")
    try emit("sibling-paths", ["leftBefore": leftBefore, "leftAfter": leftAfter, "right": rightFailure])
    try require(try E.purchaseOrder(fk).tenantId().eval() == 1, "Selected FK identity lost")
    try emit("fk-only-not-loaded", ["fk": 1, "failure": leftAfter])
    try emit("repeated-relation", self.missing({ try E.purchaseOrder(fk).tenant().purchaseOrderList().first().tenant().name().eval() },
      path: "/tenant", attempted: "/tenant/purchaseOrderList/0/tenant/name", point: "tenant", index: 0,
      chain: prefix + ".tenant()<broken>.purchaseOrderList().first().tenant().name().eval()", native: "tenant"))
    let after = try encoder.encode(views), afterPending = views.map { $0.teaqlEntityRoot.change($0.teaqlEntityKey) }
    let effects = await provider.snapshot(), callbackEffects = policy.snapshot
    try require(before == after && pending == afterPending && zip(roots, views.map(\.teaqlEntityRoot)).allSatisfy { $0 === $1 }, "E changed a view or ledger")
    try require(effects == calibration && callbackEffects == callbackCalibration, "E crossed a calibrated side-effect boundary")
    try emit("no-side-effects", ["effects": try object(ExpressionEffects()), "callbacks": try object(ExpressionCallbacks()),
      "calibration": positive, "callbackCalibration": callbacks, "geometryUnchanged": true, "pendingUnchanged": true, "ledgerIdentitiesUnchanged": true])
    print("SWIFT_E_BOUNDARY_RESULT=" + (try json(["language": "swift", "round": round, "passed": true, "cases": names,
      "parentId": saved.id, "emptyParentId": savedEmpty.id, "childIds": full.orderItemList.map(\.id),
      "generatedCases": names.count, "terminalObservations": 3, "nativeLocationCases": 0, "fullDiagnosticContractAccepted": false])))
  }
}
