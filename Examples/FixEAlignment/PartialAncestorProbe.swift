import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct PartialEffects: Codable, Sendable, Equatable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}

private actor PartialProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var effects = PartialEffects()
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
  func clear() { effects = PartialEffects() }
  func snapshot() -> PartialEffects { effects }
}

private final class PartialPolicies: MutationPolicyRegistry, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls += 1 }; return nil }
  func clear() { lock.withLock { calls = 0 } }
  func snapshot() -> Int { lock.withLock { calls } }
}

/// Application-owned integration test; generated implementations stay untouched.
enum PartialAncestorProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }

  static func verify(path: String) async throws {
    let first = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    let second = first.addingTimeInterval(24 * 3600)
    let module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let service = try SQLiteDataService(path: path), provider = PartialProvider(service), policies = PartialPolicies()
    func context(at time: Date) -> UserContext {
      UserContext(runtime: runtime, actor: "partial-ancestor-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
        queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
        auditSink: provider, mutationPolicyRegistry: policies, businessClock: FixedBusinessClock(time))
    }
    // Keep the package-only schema capability on the real provider. The
    // execution observer deliberately wraps only public Query/Mutation APIs.
    let schemaContext = UserContext(runtime: runtime, actor: "partial-ancestor-schema",
      activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
      queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 },
      businessClock: FixedBusinessClock(first))
    try await schemaContext.ensureSchema(module)
    let initial = context(at: first)
    await provider.clear(); policies.clear()
    var parent = try await Q.purchaseOrders().comment("Prepare the partial-ancestor fixture")
      .purpose("Validate only modified business objects for graph saves").newEntity(initial)
    parent.updateContactPhone("5550600"); parent.updateInternalNote(nil)
    var child = try await Q.orderItems().comment("Prepare one complete leaf")
      .purpose("Use generated relations and audited graph save").newEntity(initial)
    child.updateProductName("Partial graph original"); child.updateUnitPrice(Decimal(string: "10.00")!)
    parent.orderItemList.append(child)
    let saved = try await parent.auditAs("Create the partial-ancestor graph").save(initial)
    let calibration = await provider.snapshot(), calibrationPolicies = policies.snapshot()
    try require(calibration.begins == 1 && calibration.commits == 1 && calibration.rollbacks == 0
      && calibration.mutations == 2 && calibration.audits == 2 && calibrationPolicies > 0,
      "Actual generated creation must calibrate every provider, policy and audit observer")
    let parentID = saved.id
    let seeded = try await Q.purchaseOrders().withIdIs(parentID)
      .selectOrderItemListWith(Q.orderItems().limit(1).comment("Read the persisted fixture leaf"))
      .limit(1).comment("Read the saved graph identity").purpose("Never infer a child ID from allocation order")
      .executeForList(initial)
    guard let persisted = seeded.first, let childID = try E.purchaseOrder(persisted).orderItemList().first().id().eval()
    else { throw TeaQLError.execution("No actual persisted leaf identity") }
    func load(_ complete: Bool) async throws -> Tenant {
      let leaf = (complete ? Q.orderItems() : Q.orderItemsWithMinimalFields()).withIdIs(childID)
        .limit(1).comment(complete ? "Load every scalar of the modified leaf" : "Load an incomplete modified leaf")
      let roots = try await Q.tenantsWithMinimalFields().withIdIs(1)
        .selectPurchaseOrderListWith(Q.purchaseOrdersWithMinimalFields().withIdIs(parentID)
          .selectOrderItemListWith(leaf).limit(1).comment("Keep the untouched parent partial"))
        .limit(1).comment("Load two untouched partial ancestors above one leaf")
        .purpose("Exercise Q E JSON and graph mutation in one bounded example").executeForList(initial)
      guard let root = roots.first else { throw TeaQLError.execution("No selected root") }
      try require(try E.tenant(root).purchaseOrderList().size().eval() == 1, "Selected parent disappeared")
      try require(try E.tenant(root).purchaseOrderList().first().orderItemList().size().eval() == 1, "Selected grandchild disappeared")
      return root
    }
    var graph = try await load(true)
    let emptyRows = try await Q.purchaseOrdersWithMinimalFields().withIdIs(parentID)
      .selectOrderItemListWith(Q.orderItemsWithMinimalFields().withIdIs(0).limit(1).comment("Explicitly select an empty child list"))
      .limit(1).comment("Distinguish selected empty from unselected reverse relations")
      .purpose("Native JSON preserves availability without implicit queries").executeForList(initial)
    guard let empty = emptyRows.first else { throw TeaQLError.execution("Missing empty-list owner") }
    let queryCalibration = await provider.snapshot().queries
    try require(queryCalibration > 0, "Real generated Q must calibrate the query observer")
    await provider.clear(); policies.clear()
    func missing<T>(_ read: () throws -> T, at pointer: String) throws {
      do { _ = try read() }
      catch let error as TeaQLCore.TeaQLNotLoadedError {
        try require(error.toWire().instancePath == pointer, "Wrong missing-field path"); return
      }
      throw TeaQLError.execution("Missing fixed field became loaded null")
    }
    try missing({ try E.tenant(graph).name().eval() }, at: "/name")
    try missing({ try E.tenant(graph).purchaseOrderList().first().contactPhone().eval() }, at: "/purchaseOrderList/0/contactPhone")
    try require(try E.tenant(graph).purchaseOrderList().first().orderItemList().first().unitPrice().eval() == Decimal(string: "10.00")!, "Complete leaf lost its Decimal")
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard let json = try JSONSerialization.jsonObject(with: encoder.encode(graph)) as? [String: Any],
      let orders = json["purchaseOrderList"] as? [[String: Any]], let order = orders.first,
      let leaves = order["orderItemList"] as? [[String: Any]] else { throw TeaQLError.execution("JSON lost selected nested lists") }
    try require(json["name"] == nil && json["orderItemList"] == nil && orders.count == 1
      && order["contactPhone"] == nil && leaves.count == 1, "JSON fabricated unselected fields or lost selected children")
    guard let emptyJSON = try JSONSerialization.jsonObject(with: encoder.encode(empty)) as? [String: Any],
      let emptyList = emptyJSON["orderItemList"] as? [Any] else { throw TeaQLError.execution("JSON lost a selected empty list") }
    try require(emptyList.isEmpty, "Selected empty list is not empty")
    let guardEffects = await provider.snapshot(), guardPolicies = policies.snapshot()
    try require(guardEffects == PartialEffects() && guardPolicies == 0, "E or JSON performed implicit work")
    let idSpaceBefore = try physical(path, table: "teaql_id_space")
    graph.purchaseOrderList[0].orderItemList[0].updateProductName("Partial graph updated")
    _ = try await graph.auditAs("Save the complete modified leaf through untouched partial ancestors").save(context(at: second))
    let saveEffects = await provider.snapshot(), savePolicies = policies.snapshot()
    try require(saveEffects.begins == 1 && saveEffects.commits == 1 && saveEffects.rollbacks == 0
      && saveEffects.mutations == 1 && saveEffects.audits == 1 && savePolicies > 0, "Saving one leaf performed unrelated work")
    try require(try physical(path, table: "teaql_id_space") == idSpaceBefore, "Updating a persisted leaf allocated an ID")
    let stored = try physical(path)
    var partial = try await load(false)
    partial.purchaseOrderList[0].orderItemList[0].updateProductName("Rejected partial leaf")
    let leaf = partial.purchaseOrderList[0].orderItemList[0]
    let ledger = leaf.teaqlEntityRoot, key = leaf.teaqlEntityKey, pending = ledger.change(key)
    try require(pending["product_name"] == .string("Rejected partial leaf"), "The generated setter did not register real pending intent")
    var rejections: [[WireCheckResult]] = [], rejectionEffects: [PartialEffects] = [], rejectionPolicies: [Int] = []
    for _ in 0..<2 {
      await provider.clear(); policies.clear()
      do {
        _ = try await partial.auditAs("Reject the incomplete modified leaf before provider entry").save(context(at: second))
        throw TeaQLError.execution("Incomplete modified leaf was accepted")
      } catch let error as CheckException {
        let wire = error.violations.map { $0.wire() }
        try require(!wire.isEmpty && wire.allSatisfy { $0.ruleId == "invalid_type" && $0.entityType == "OrderItem"
          && $0.instancePath.hasPrefix("/purchaseOrderList/0/orderItemList/0/") }, "Lost modified-leaf diagnostic ancestry")
        rejections.append(wire)
      }
      let effects = await provider.snapshot(), policyCount = policies.snapshot()
      try require(effects == PartialEffects() && policyCount == 0, "Rejected leaf entered provider, transaction, policy or audit")
      try require(ledger.change(key) == pending, "Rejection changed pending mutation intent")
      try require(try physical(path) == stored && physical(path, table: "teaql_id_space") == idSpaceBefore, "Rejected mutation changed physical data or ID space")
      rejectionEffects.append(effects); rejectionPolicies.append(policyCount)
    }
    struct Result: Encodable {
      let language = "swift", passed = true, cases = ["partial-ancestor-guards-and-JSON-no-I/O",
        "complete-leaf-saved-through-two-untouched-partial-ancestors", "partial-leaf-rejected-twice-before-provider-with-intent-retained"]
      let orderId: Int64, leafId: Int64
      let ancestorVersions = [1, 1], leafVersion = 2
      let calibration: PartialEffects, calibrationPolicies: Int, guardEffects: PartialEffects, guardPolicies: Int
      let queryCalibration: Int
      let saveEffects: PartialEffects, savePolicies: Int
      let rejections: [[WireCheckResult]], rejectionEffects: [PartialEffects], rejectionPolicies: [Int]
      let intentRetained = true, selectedEmptySerialized = true, unselectedListOmitted = true
      let idSpaceUnchanged = true, generatedImplementationsModified = false
    }
    print("CORE_SWIFT_PARTIAL_ANCESTORS_RESULT=" + String(decoding: try encoder.encode(Result(orderId: parentID, leafId: childID,
      calibration: calibration, calibrationPolicies: calibrationPolicies, guardEffects: guardEffects, guardPolicies: guardPolicies, queryCalibration: queryCalibration,
      saveEffects: saveEffects, savePolicies: savePolicies, rejections: rejections, rejectionEffects: rejectionEffects,
      rejectionPolicies: rejectionPolicies)), as: UTF8.self))
  }

  /// A separate read-only SQLite connection; never a fake application Query.
  private static func physical(_ path: String, table: String? = nil) throws -> String {
    var database: OpaquePointer?
    try require(sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "Read-only physical oracle could not open")
    defer { sqlite3_close(database) }
    var result: [String: [[String: String?]]] = [:]
    for name in table.map({ [$0] }) ?? ["tenant_data", "purchase_order_data", "order_item_data"] {
      try require(["tenant_data", "purchase_order_data", "order_item_data", "teaql_id_space"].contains(name), "Unrecognized oracle table")
      var statement: OpaquePointer?
      let order = name == "teaql_id_space" ? "type_name" : "id"
      try require(sqlite3_prepare_v2(database, "SELECT * FROM " + name + " ORDER BY " + order, -1, &statement, nil) == SQLITE_OK, "Physical SELECT failed")
      defer { sqlite3_finalize(statement) }
      var rows: [[String: String?]] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        try require(status == SQLITE_ROW, "Physical reader failed")
        var row: [String: String?] = [:]
        for index in 0..<sqlite3_column_count(statement) {
          let key = String(cString: sqlite3_column_name(statement, index))
          row[key] = sqlite3_column_type(statement, index) == SQLITE_NULL ? .some(nil) : .some(String(cString: sqlite3_column_text(statement, index)))
        }
        rows.append(row)
      }
      result[name] = rows
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(result), as: UTF8.self)
  }
}
