import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct BoundaryEffects: Codable, Sendable, Equatable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}
private actor BoundaryProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  let service: SQLiteDataService
  private var effects = BoundaryEffects()
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    effects.queries += 1; return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    effects.mutations += 1; return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { effects.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { effects.commits += 1; try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { effects.rollbacks += 1; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { effects.audits += 1 }
  func reset() { effects = BoundaryEffects() }
  func snapshot() -> BoundaryEffects { effects }
}
private struct BoundaryCallbacks: Codable, Sendable, Equatable { var checkers = 0, policies = 0, reviews = 0 }
private final class BoundaryPolicy: MutationPolicyRegistry, MutationPolicy, @unchecked Sendable {
  enum Fix { case none, requiredNull, minZero, repair }
  private let lock = NSLock()
  private var callbacks = BoundaryCallbacks(), fix = Fix.none
  private let deny: Bool
  init(deny: Bool = false) { self.deny = deny }
  let identity = MutationPolicyIdentity(policyID: "checker-boundary-example", version: "1", fingerprint: "fixture")
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { callbacks.policies += 1 }; return self }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { callbacks.reviews += 1 }
    if deny { return MutationPolicyDecision(verdict: .deny, code: "BOOTSTRAP_DENIED", message: "synthetic customer decision") }
    return MutationPolicyDecision(verdict: .allow)
  }
  func check() -> Fix { lock.withLock { callbacks.checkers += 1; return fix } }
  func set(_ value: Fix) { lock.withLock { fix = value } }
  func reset() { lock.withLock { callbacks = BoundaryCallbacks() } }
  var snapshot: BoundaryCallbacks { lock.withLock { callbacks } }
}
private struct BoundaryChecker: EntityChecker {
  let base: any EntityChecker, policy: BoundaryPolicy
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    let mode = policy.check()
    guard now == ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")! else {
      throw TeaQLError.execution("Checker did not receive the fixed Business Clock")
    }
    if mutation.entity.name == "OrderItem" {
      switch mode {
      case .none: break
      case .requiredNull: mutation.values["product_name"] = .null
      case .minZero: mutation.values["unit_price"] = .decimal(0)
      case .repair:
        mutation.values["product_name"] = .string("Fixed child")
        mutation.values["unit_price"] = .decimal(Decimal(string: "12.34")!)
      }
    }
    return try base.checkAndFix(context: context, mutation: &mutation, now: now)
  }
}

/// All business writes use generated Q/E/audited save; CSQLite is a read-only oracle.
enum CheckerBoundaryProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution("Checker boundary: " + message) }
  }
  private static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
  }
  private static func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
  }
  private static func physical(_ path: String, schemaOnly: Bool = false) throws -> String {
    var database: OpaquePointer?
    try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "cannot open the independent oracle")
    defer { sqlite3_close(database) }
    var result: [String: [[String: String?]]] = [:]
    for table in schemaOnly ? ["sqlite_master"] : ["tenant_data", "purchase_order_data", "order_item_data", "teaql_id_space"] {
      var statement: OpaquePointer?
      let order = table == "teaql_id_space" ? "type_name" : table == "sqlite_master" ? "rowid" : "id"
      try require(sqlite3_prepare_v2(database, "SELECT * FROM " + table + " ORDER BY " + order, -1, &statement, nil) == SQLITE_OK,
        "cannot prepare the read-only oracle")
      defer { sqlite3_finalize(statement) }
      var rows: [[String: String?]] = []
      while true {
        let status = sqlite3_step(statement); if status == SQLITE_DONE { break }
        try require(status == SQLITE_ROW, "oracle read failed")
        var row: [String: String?] = [:]
        for i in 0..<sqlite3_column_count(statement) {
          let name = String(cString: sqlite3_column_name(statement, i))
          row[name] = sqlite3_column_type(statement, i) == SQLITE_NULL ? .some(nil) : .some(String(cString: sqlite3_column_text(statement, i)))
        }
        rows.append(row)
      }
      result[table] = rows
    }
    return try json(result)
  }
  static func verify(path: String, round: Int) async throws {
    try require([1, 2].contains(round), "explicit unreset round required")
    let clock = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!, module = GeneratedRuntimeModule.module
    let service = try SQLiteDataService(path: path), provider = BoundaryProvider(service), policy = BoundaryPolicy()
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let names = ["OrderItem", "PurchaseOrder", "Tenant"]
    var wrappers: [String: any EntityChecker] = [:]
    for name in names {
      guard let base = runtime.checker(named: name) else { throw TeaQLError.execution("Missing generated Checker " + name) }
      wrappers[name] = BoundaryChecker(base: base, policy: policy)
    }
    try runtime.install(RuntimeModule(name: "Observed Checker boundaries", entities: [], checkers: wrappers))
    func context(_ runtime: TeaQLRuntime, _ provider: BoundaryProvider, _ policy: BoundaryPolicy) -> UserContext {
      UserContext(runtime: runtime, actor: "checker-boundary-example", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
        queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, auditSink: provider,
        mutationPolicyRegistry: policy, businessClock: FixedBusinessClock(clock))
    }
    let active = context(runtime, provider, policy)
    let schema = UserContext(runtime: runtime, actor: "checker-boundary-schema", activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: policy, businessClock: FixedBusinessClock(clock))
    try await schema.ensureSchema(module)
    var observations: [[String: Any]] = []
    func record(_ name: String, _ details: [String: Any]) throws {
      var row = details; row["case"] = name; row["round"] = round; row["passed"] = true
      observations.append(row); print("SWIFT_CHECKER_BOUNDARY_CASE=" + (try json(row)))
    }
    let deniedService = try SQLiteDataService(path: path + ".bootstrap-denied.sqlite")
    let deniedProvider = BoundaryProvider(deniedService), deniedPolicy = BoundaryPolicy(deny: true)
    var deniedRuntime = TeaQLRuntime(); try deniedRuntime.install(module)
    let deniedContext = UserContext(runtime: deniedRuntime, actor: "denied-bootstrap",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: deniedService, mutationExecutor: deniedService, requestPolicy: RequestPolicy { $0 }, auditSink: deniedProvider,
      mutationPolicyRegistry: deniedPolicy, businessClock: FixedBusinessClock(clock))
    var bootstrapDenied = false
    do { try await deniedContext.ensureSchema(module) }
    catch MutationPolicyError.denied(let code, _) { bootstrapDenied = code == "BOOTSTRAP_DENIED" }
    let deniedRows = try await Q.tenants().limit(1).comment("Check that denied bootstrap did not create root data")
      .purpose("Verify customer policy on the actual generated bootstrap save").executeForList(deniedContext)
    let deniedEffects = await deniedProvider.snapshot(), deniedCallbacks = deniedPolicy.snapshot
    try require(bootstrapDenied && deniedRows.isEmpty && deniedEffects.audits == 0 && deniedCallbacks.reviews > 0,
      "generated bootstrap bypassed the customer's rejecting mutation policy")
    try record("bootstrap-policy-denial", ["code": "BOOTSTRAP_DENIED", "persistedRoots": 0,
      "callbacks": try object(deniedCallbacks), "effects": try object(deniedEffects), "schemaAllowed": true])
    func reset() async { await provider.reset(); policy.reset() }
    func owner(_ phone: String = "5550100") throws -> PurchaseOrder {
      var row = try Q.purchaseOrders().comment("Prepare a generated Checker boundary")
        .purpose("Require modeled admission before provider execution").newEntity(active)
      row.updateContactPhone(phone); return row
    }
    func item(_ valid: Bool = true) throws -> OrderItem {
      var row = try Q.orderItems().comment("Prepare a generated Checker child")
        .purpose("Verify post-Fix values through the normal graph save").newEntity(active)
      if valid { row.updateProductName("Boundary item") }
      row.updateUnitPrice(Decimal(string: valid ? "10.00" : "0")!); return row
    }
    func rejected(_ rule: String, _ location: String, _ entity: String,
      save: () async throws -> Void) async throws -> [CheckResult] {
      let before = try physical(path); await reset(); var violations: [CheckResult] = []
      do { try await save(); throw TeaQLError.execution("Invalid generated save was accepted") }
      catch let error as CheckException { violations = error.violations }
      try require(violations.contains { $0.ruleID == rule && $0.location.modelPath == location && $0.entityType == entity },
        "missing modeled rule, declaring type or exact indexed location: " + location)
      try require(await provider.snapshot() == BoundaryEffects(), "invalid save crossed the provider boundary")
      try require(policy.snapshot.policies == 0 && policy.snapshot.reviews == 0, "invalid save reached mutation policy")
      try require(try physical(path) == before, "invalid save changed data or ID allocation state")
      return violations
    }
    let isolatedService = try SQLiteDataService(path: path + ".no-schema.sqlite")
    let isolatedProvider = BoundaryProvider(isolatedService), isolatedPolicy = BoundaryPolicy()
    var isolatedRuntime = TeaQLRuntime(); try isolatedRuntime.install(module)
    var isolatedWrappers: [String: any EntityChecker] = [:]
    for name in names {
      guard let base = isolatedRuntime.checker(named: name) else { throw TeaQLError.execution("Missing module Checker") }
      isolatedWrappers[name] = BoundaryChecker(base: base, policy: isolatedPolicy)
    }
    try isolatedRuntime.install(RuntimeModule(name: "Schema-free Checker boundaries", entities: [], checkers: isolatedWrappers))
    let isolated = context(isolatedRuntime, isolatedProvider, isolatedPolicy)
    let missing = try Q.purchaseOrders().comment("Prepare omitted required input without schema creation")
      .purpose("Install module Checkers independently of bootstrap or DDL").newEntity(isolated)
    var isolatedRejected = false
    do { _ = try await missing.auditAs("Reject invalid input before provider or schema access").save(isolated) }
    catch let error as CheckException { isolatedRejected = error.violations.contains { $0.ruleID == "required" && $0.location.modelPath == "contact_phone" } }
    try require(isolatedRejected && isolatedPolicy.snapshot.checkers > 0, "module did not install its Checker")
    try require(await isolatedProvider.snapshot() == BoundaryEffects(), "schema-free rejection used its provider")
    try require(try physical(path + ".no-schema.sqlite", schemaOnly: true) == "{\"sqlite_master\":[]}", "schema was unexpectedly created")
    try record("module-checker-without-schema", ["schemaCalled": false, "tables": 0, "providerCalls": 0,
      "installedCheckers": names, "checkerCalls": isolatedPolicy.snapshot.checkers])
    var parent = try owner(); let child = try item(); parent.orderItemList.append(child)
    await reset(); let saved = try await parent.auditAs("Calibrate one complete generated graph transaction").save(active)
    let calibrated = try await Q.purchaseOrders().withIdIs(saved.id).limit(1)
      .comment("Calibrate an actual provider query").purpose("Prove the read observer is active").executeForList(active)
    try require(calibrated.count == 1, "missing calibration graph")
    let positive = await provider.snapshot(), positiveCallbacks = policy.snapshot
    try require(positive.queries > 0 && positive.mutations == 2 && positive.begins == 1 && positive.commits == 1
      && positive.rollbacks == 0 && positive.audits == 2 && positiveCallbacks.checkers == 2
      && positiveCallbacks.policies > 0 && positiveCallbacks.reviews == 1, "positive instrumentation is not calibrated")
    let children = try await Q.orderItems().limit(100).comment("Read the generated calibration child identity")
      .purpose("Never infer a child ID from allocation order").executeForList(active)
    var childID: Int64?
    for row in children where try E.orderItem(row).purchaseOrderId().eval() == saved.id { childID = row.id }
    guard let childID else { throw TeaQLError.execution("Missing persisted calibration child") }
    try record("exact-provider-calibration", ["parentID": saved.id, "childID": childID,
      "effects": try object(positive), "callbacks": try object(positiveCallbacks)])
    let orphan = try item()
    let required = try await rejected("required", "purchase_order", "OrderItem") {
      _ = try await orphan.auditAs("Reject an omitted required parent relation").save(active)
    }
    try record("required-relation", ["wire": try object(required.first { $0.ruleID == "required" && $0.location.modelPath == "purchase_order" }!.wire()),
      "effects": try object(await provider.snapshot()), "callbacks": try object(policy.snapshot)])
    for absent in ["internal_note", "contact_phone", "create_time", "update_time"] {
      var selected = Q.purchaseOrdersWithMinimalFields().withIdIs(saved.id)
        .selectTenantWith(Q.tenantsWithMinimalFields().limit(1).comment("Keep ownership loaded without root business fields"))
      if absent != "internal_note" { selected = selected.selectInternalNote() }
      if absent != "contact_phone" { selected = selected.selectContactPhone() }
      if absent != "create_time" { selected = selected.selectCreateTime() }
      if absent != "update_time" { selected = selected.selectUpdateTime() }
      let roots = try await Q.tenantsWithMinimalFields().withIdIs(1)
        .selectPurchaseOrderListWith(selected.limit(1).comment("Omit only the selected business field"))
        .limit(1).comment("Load an incomplete non-root under an untouched ancestor")
        .purpose("Separate completeness admission from missing root ownership").executeForList(active)
      guard var graph = roots.first, graph.purchaseOrderList.count == 1 else { throw TeaQLError.execution("Missing non-root projection") }
      try require(try E.purchaseOrder(graph.purchaseOrderList[0]).tenantId().eval() == 1, "the root FK must be loaded")
      if absent == "contact_phone" { graph.purchaseOrderList[0].updateInternalNote("Rejected partial change") }
      else { graph.purchaseOrderList[0].updateContactPhone("5550101") }
      let violations = try await rejected("invalid_type", "purchase_order_list[0]." + absent, "PurchaseOrder") {
        _ = try await graph.auditAs("Reject the incomplete modified descendant before SQL").save(active)
      }
      let result = violations.first { $0.ruleID == "invalid_type" && $0.location.modelPath == "purchase_order_list[0]." + absent }!
      try record("nonroot-partial-" + absent, ["loadedRoot": 1, "absentField": absent, "wire": try object(result.wire()),
        "effects": try object(await provider.snapshot()), "callbacks": try object(policy.snapshot)])
    }
    let completeRows = try await Q.purchaseOrders().withIdIs(saved.id)
      .selectTenantWith(Q.tenantsWithMinimalFields().limit(1).comment("Keep the unchanged target partial"))
      .limit(1).comment("Load a complete owner with an untouched sparse target")
      .purpose("Require completeness only for actually modified objects").executeForList(active)
    guard var complete = completeRows.first else { throw TeaQLError.execution("Missing complete owner") }
    var targetNotLoaded = false
    do { _ = try E.purchaseOrder(complete).tenant().name().eval() } catch is TeaQLNotLoadedError { targetNotLoaded = true }
    try require(targetNotLoaded, "target name must remain NotLoaded")
    complete.updateContactPhone("5550102"); await reset()
    let changed = try await complete.auditAs("Save a complete owner without widening an untouched relation").save(active)
    let ownerEffects = await provider.snapshot()
    try require(ownerEffects == BoundaryEffects(queries: 0, mutations: 1, begins: 1, commits: 1, rollbacks: 0, audits: 1)
      && changed.version == 2, "the owner update did not execute exactly once")
    try record("untouched-partial-target", ["parentID": saved.id, "parentVersion": changed.version,
      "effects": try object(ownerEffects), "callbacks": try object(policy.snapshot)])
    for (name, mode, rule, field) in [("required-null", BoundaryPolicy.Fix.requiredNull, "required", "product_name"),
      ("min-zero", BoundaryPolicy.Fix.minZero, "min", "unit_price")] {
      var graph = try owner(); let original = try item(); graph.orderItemList.append(original); policy.set(mode)
      let violations = try await rejected(rule, "order_item_list[0]." + field, "OrderItem") {
        _ = try await graph.auditAs("Validate the customer's actual Fix result before SQL").save(active)
      }
      policy.set(.none)
      try require(try E.orderItem(original).productName().eval() == "Boundary item" && E.orderItem(original).unitPrice().eval() == 10,
        "rejection altered the original business input")
      let result = violations.first { $0.ruleID == rule && $0.location.modelPath == "order_item_list[0]." + field }!
      try record("post-fix-" + name, ["originalInputRetained": true, "wire": try object(result.wire()),
        "effects": try object(await provider.snapshot()), "callbacks": try object(policy.snapshot)])
    }
    var repaired = try owner(); let invalidChild = try item(false)
    try require(invalidChild.teaqlEntityRoot.change(invalidChild.teaqlEntityKey)["product_name"] == nil,
      "repair must start with an omitted required field")
    try require(try E.orderItem(invalidChild).unitPrice().eval() == 0, "repair must start with an invalid price")
    repaired.orderItemList.append(invalidChild); policy.set(.repair); await reset()
    let repairedParent = try await repaired.auditAs("Persist repaired required and range values in one transaction").save(active)
    policy.set(.none); let repairedEffects = await provider.snapshot(), repairedCallbacks = policy.snapshot
    try require(repairedEffects == BoundaryEffects(queries: 0, mutations: 2, begins: 1, commits: 1, rollbacks: 0, audits: 2),
      "repaired graph did not persist exactly once")
    let repairedRows = try await Q.orderItems().limit(100).comment("Read the actual customer-Fix results")
      .purpose("Check exact Decimal persistence through generated Q and E").executeForList(active)
    var repairedChildID: Int64?
    for row in repairedRows where try E.orderItem(row).purchaseOrderId().eval() == repairedParent.id {
      try require(try E.orderItem(row).productName().eval() == "Fixed child" && E.orderItem(row).unitPrice().eval() == Decimal(string: "12.34")!,
        "Fix values did not reach actual storage")
      repairedChildID = row.id
    }
    guard let repairedChildID else { throw TeaQLError.execution("Missing repaired child") }
    try record("post-fix-repair", ["parentID": repairedParent.id, "childID": repairedChildID,
      "originalMissingRequired": true, "originalPrice": "0", "storedName": "Fixed child", "storedPrice": "12.34",
      "effects": try object(repairedEffects), "callbacks": try object(repairedCallbacks)])
    let profiles: [JsonFieldNamingProfile] = [.camelCase, .snakeCase, .pascalCase]
    for (index, profile) in profiles.enumerated() {
      let metadata = try WireEntityMetadata(entityType: "PurchaseOrder", canonicalFields: ["contact_phone"], profile: profile,
        aliases: ["contact_phone": ["legacy/phone~"]]), canonical = metadata.fields["contact_phone"]!.wireName
      let cases: [(String, [(String, TeaQLValue)])] = [
        ("accepted-input-alias", [("legacy/phone~", .null)]),
        ("input-unknown", [("unknown/field~", .string("no"))]),
        ("input-equal-forward", [(canonical, .string("same")), ("legacy/phone~", .string("same"))]),
        ("input-equal-reverse", [("legacy/phone~", .string("same")), (canonical, .string("same"))]),
        ("input-unequal-forward", [(canonical, .string("first")), ("legacy/phone~", .string("second"))]),
        ("input-unequal-reverse", [("legacy/phone~", .string("first")), (canonical, .string("second"))]),
        ("wire-positive-control", [(canonical, .string("55509\(round)\(index)"))]),
      ]
      for (name, fields) in cases {
        let payload = try fields.map { try json($0.0) + ":" + json(object($0.1)) }.joined(separator: ",")
        let submitted = "{\"payload/order\":{" + payload + "}}", before = try physical(path)
        await reset(); var mapperCalls = 0, saveCalls = 0, createdID: Int64?
        var normalized: NormalizedWireInput?, violations: [CheckResult] = [], inputFailure: WireInputError?
        do {
          let envelope = try JSONDecoder().decode([String: TeaQLValue].self, from: Data(submitted.utf8))
          guard let outer = envelope["payload/order"], case .object(let input) = outer else { throw TeaQLError.execution("Missing JSON object") }
          normalized = try normalizeWireInput(input, metadata: metadata, parentPointer: "/payload~1order")
          mapperCalls += 1; var entity = try owner()
          switch normalized!.values["contact_phone"] {
          case .some(.string(let phone)): entity.updateContactPhone(phone)
          case .some(.null): entity.updateContactPhone(nil)
          default: throw TeaQLError.execution("The input allow-list requires a string or null")
          }
          saveCalls += 1; createdID = try await entity.auditAs("Save admitted JSON through the generated input allow-list").save(active).id
        } catch let error as CheckException { violations = error.violations }
        catch let error as WireInputError { inputFailure = error }
        let effects = await provider.snapshot(), callbacks = policy.snapshot
        if name == "accepted-input-alias" {
          try require(createdID == nil && normalized != nil && mapperCalls == 1 && saveCalls == 1 && callbacks.checkers > 0,
            "the declared alias did not reach the real generated Checker")
          let results = retainSubmittedPaths(violations, normalized: normalized!)
          guard let result = results.first(where: { $0.ruleID == "required" && $0.location.modelPath == "contact_phone" }) else {
            throw TeaQLError.execution("Alias null did not retain a required-field violation")
          }
          var wires: [String: Any] = [:]
          for output in profiles {
            let wire = result.wire(profile: output)
            try require(wire.sourceInstancePath == "/payload~1order/legacy~1phone~0" && wire.instancePath == "/" + output.render("contact_phone"),
              "alias provenance or canonical pointer was lost")
            wires[output.rawValue] = try object(wire)
          }
          try require(effects == BoundaryEffects() && callbacks.policies == 0 && callbacks.reviews == 0 && physical(path) == before,
            "invalid alias input changed provider state")
          try record(name, ["profile": profile.rawValue, "wires": wires, "mapperCalls": mapperCalls, "saveCalls": saveCalls,
            "effects": try object(effects), "callbacks": try object(callbacks)])
        } else if name == "wire-positive-control" {
          guard let createdID else { throw TeaQLError.execution("Valid input failed to persist") }
          try require(inputFailure == nil && violations.isEmpty && effects.mutations == 1 && effects.begins == 1 && effects.commits == 1 && effects.audits == 1,
            "valid JSON input did not reach the provider exactly once")
          try record(name, ["profile": profile.rawValue, "id": createdID, "mapperCalls": mapperCalls, "saveCalls": saveCalls,
            "effects": try object(effects), "callbacks": try object(callbacks)])
        } else {
          guard let error = inputFailure else { throw TeaQLError.execution("Unknown/colliding JSON input was accepted") }
          let pointers = name == "input-unknown" ? ["/payload~1order/unknown~1field~0"]
            : ["/payload~1order/" + canonical, "/payload~1order/legacy~1phone~0"]
          try require(error.code == (name == "input-unknown" ? .unknownField : .fieldCollision) && pointers.contains(error.instancePath),
            "input failure did not identify an actual escaped submitted leaf")
          try require(mapperCalls == 0 && saveCalls == 0 && callbacks == BoundaryCallbacks() && effects == BoundaryEffects() && physical(path) == before,
            "input rejection reached mapping, Checker, policy, allocation or save")
          try record(name, ["profile": profile.rawValue, "code": error.code.rawValue, "pointer": error.instancePath,
            "submittedJson": submitted, "dictionaryOrderNotAssumed": true, "mapperCalls": mapperCalls, "saveCalls": saveCalls,
            "effects": try object(effects), "callbacks": try object(callbacks)])
        }
      }
    }
    try require(observations.count == 33, "missing boundary observations")
    print("SWIFT_CHECKER_BOUNDARY_RESULT=" + (try json(["language": "swift", "passed": true, "round": round,
      "observations": observations.count, "physical": try JSONSerialization.jsonObject(with: Data(physical(path).utf8)),
      "objectLocalWireAdapter": true, "recursiveHttpOrTfpAccepted": false])))
  }
}
