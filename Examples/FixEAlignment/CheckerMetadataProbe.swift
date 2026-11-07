import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private struct CheckerEffects: Codable, Sendable, Equatable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}

private actor CheckerProvider: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink {
  // Reservation is infrastructure I/O, not a business query/mutation/audit.
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    try await service.nextID(for: entity, context: context)
  }
  let service: SQLiteDataService
  private var effects = CheckerEffects()
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
  func clear() { effects = CheckerEffects() }
  func snapshot() -> CheckerEffects { effects }
}

private struct SpecializedChecker: EntityChecker {
  let delegate: any EntityChecker
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    try delegate.checkAndFix(context: context, mutation: &mutation, now: now).map {
      CheckResult(ruleID: $0.ruleID, location: $0.location, inputValue: $0.inputValue,
        systemValue: $0.systemValue, message: $0.message, entityType: "ReviewedItem",
        sourceInstancePath: "/order_item_list/0/product~1name~0alias")
    }
  }
}

/// Actual generated Q/E/audited graph saves; no constructed rejection errors.
enum CheckerMetadataProbe {
  private static func require(_ value: Bool, _ message: String) throws {
    if !value { throw TeaQLError.execution(message) }
  }
  static func verify(service: SQLiteDataService, module: RuntimeModule) async throws {
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let provider = CheckerProvider(service)
    let now = ISO8601DateFormatter().date(from: "2032-02-29T10:15:30Z")!
    func makeContext(_ runtime: TeaQLRuntime, locale: TeaQLLocale = .en) -> UserContext {
      UserContext(runtime: runtime, actor: "checker-metadata-example",
        activeRoot: ContextEntityRef(entity: "Tenant", id: .int(1)),
        queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
        auditSink: provider, locale: locale, businessClock: FixedBusinessClock(now))
    }
    var context = makeContext(runtime)
    func owner() async throws -> PurchaseOrder {
      try await Q.purchaseOrders().comment("Prepare a Checker metadata regression")
        .purpose("Verify real generated-save admission before provider entry").newEntity(context)
    }
    var calibration = try await owner(); calibration.updateContactPhone("5550970")
    let good = try await calibration.auditAs("Calibrate successful SQLite and committed audit instrumentation").save(context)
    let effects = await provider.snapshot()
    try require(effects.begins == 1 && effects.mutations == 1 && effects.commits == 1 && effects.audits == 1,
      "Successful persistence did not calibrate the Checker probes")
    struct Observation: Codable {
      let scenario: String, expectedEntityType: String, expectedPath: String, expectedRule: String
      let effects: CheckerEffects, wires: [String: [WireCheckResult]], acceptedID: Int64?
      let failures: [String]
    }
    var observations: [Observation] = [], allFailures: [String] = []
    func invalid(_ scenario: String, type: String, path: String, rule: String,
      _ save: () async throws -> Int64) async throws {
      await provider.clear()
      var violations: [CheckResult] = [], acceptedID: Int64?
      do { acceptedID = try await save() }
      catch let error as CheckException { violations = error.violations }
      let effects = await provider.snapshot()
      var failures: [String] = []
      if acceptedID != nil { failures.append("invalid save reached SQLite") }
      else {
        if effects != CheckerEffects() { failures.append("Checker rejection performed provider/transaction/audit work") }
        if !violations.contains(where: { $0.ruleID == rule && $0.location.modelPath == path }) {
          failures.append("expected rule or canonical indexed path missing")
        }
        for value in violations {
          if value.entityType != type { failures.append("declaring entity type lost") }
          if value.ruleID != "invalid_type", value.message?.contains(value.location.nativePath) != true {
            failures.append("full native path missing from localized message")
          }
          if scenario == "specialized_child", value.sourceInstancePath != "/order_item_list/0/product~1name~0alias" {
            failures.append("original escaped input pointer lost")
          }
        }
      }
      let profiles: [JsonFieldNamingProfile] = [.camelCase, .snakeCase, .pascalCase]
      let wires = Dictionary(uniqueKeysWithValues: profiles.map { profile in
        (profile.rawValue, violations.map { $0.wire(profile: profile) })
      })
      let row = Observation(scenario: scenario, expectedEntityType: type, expectedPath: path,
        expectedRule: rule, effects: effects, wires: wires, acceptedID: acceptedID, failures: failures)
      observations.append(row); allFailures += failures.map { scenario + ": " + $0 }
      print("SWIFT_CHECKER_METADATA_CASE=" + String(decoding: try JSONEncoder().encode(row), as: UTF8.self))
      if let acceptedID {
        let rows = try await Q.purchaseOrders().withIdIs(acceptedID).limit(1)
          .comment("Inspect unexpectedly accepted invalid graph")
          .purpose("Retain a generated Q/E proof of actual persistence").executeForList(context)
        try require(rows.count == 1 && (try E.purchaseOrder(rows[0]).version().eval()) == 1,
          "Unexpected save did not have an authoritative persisted row")
      }
    }
    let missing = try await owner()
    try await invalid("parent_required", type: "PurchaseOrder", path: "contact_phone", rule: "required") {
      try await missing.auditAs("Reject an omitted required phone").save(context).id
    }
    var tooLong = try await owner(); tooLong.updateContactPhone(String(repeating: "x", count: 33))
    try await invalid("parent_length", type: "PurchaseOrder", path: "contact_phone", rule: "max_length") {
      try await tooLong.auditAs("Reject a modeled string length violation").save(context).id
    }
    let loaded = try await Q.purchaseOrders().withIdIs(good.id).limit(1)
      .comment("Load the complete owner before invalid update").purpose("Verify explicit null admission").executeForList(context)
    guard var complete = loaded.first else { throw TeaQLError.execution("Missing Checker calibration row") }
    complete.updateContactPhone(nil)
    try await invalid("update_null", type: "PurchaseOrder", path: "contact_phone", rule: "required") {
      try await complete.auditAs("Reject null for a required scalar").save(context).id
    }
    let projected = try await Q.purchaseOrdersWithMinimalFields().withIdIs(good.id).limit(1)
      .comment("Load an identity-only owner").purpose("Verify complete modified object admission").executeForList(context)
    guard var partial = projected.first else { throw TeaQLError.execution("Missing partial owner") }
    partial.updateContactPhone("5550971")
    try await invalid("partial_owner", type: "PurchaseOrder", path: "tenant", rule: "invalid_type") {
      try await partial.auditAs("Reject a modified incomplete owner").save(context).id
    }
    func badChild(_ scenario: String, product: String?, price: String, rule: String, field: String,
      type: String = "OrderItem") async throws {
      var parent = try await owner(); parent.updateContactPhone("5550973")
      var child = try await Q.orderItems().comment("Prepare an invalid indexed child")
        .purpose("Keep child Checker type and source pointer across graph boundaries").newEntity(context)
      if let product { child.updateProductName(product) }
      child.updateUnitPrice(Decimal(string: price, locale: Locale(identifier: "en_US_POSIX"))!)
      parent.orderItemList.append(child)
      try await invalid(scenario, type: type, path: "order_item_list[0]." + field, rule: rule) {
        try await parent.auditAs("Reject invalid child graph before the first SQLite mutation").save(context).id
      }
    }
    try await badChild("child_required", product: nil, price: "10", rule: "required", field: "product_name")
    try await badChild("child_length", product: String(repeating: "x", count: 81), price: "10", rule: "max_length", field: "product_name")
    try await badChild("child_min", product: "Synthetic Checker Widget", price: "0", rule: "min", field: "unit_price")
    try await badChild("child_max", product: "Synthetic Checker Widget", price: "1000001", rule: "max", field: "unit_price")
    try context.setLocaleCode("zh-CN")
    let localized = try await owner()
    try await invalid("localized_required", type: "PurchaseOrder", path: "contact_phone", rule: "required") {
      try await localized.auditAs("Reject a missing scalar with a localized message").save(context).id
    }
    guard let delegate = runtime.checker(named: "OrderItem") else { throw TeaQLError.execution("Missing generated child Checker") }
    try runtime.install(RuntimeModule(name: "specialized-checker", entities: [],
      checkers: ["OrderItem": SpecializedChecker(delegate: delegate)]))
    context = makeContext(runtime, locale: .zhCN)
    try await badChild("specialized_child", product: nil, price: "10", rule: "required", field: "product_name", type: "ReviewedItem")
    // Fractional values immediately outside the declared Decimal interval must
    // not be rounded to a Double endpoint or skipped because of their value tag.
    for (name, price, rule) in [("zero", "0", "min"), ("fraction_below", "0.009999999999999999999999", "min"),
      ("fraction_above", "1000000.000000000000000001", "max"), ("above", "1000001", "max")] {
      try await badChild("range_" + name, product: "Synthetic Checker Widget", price: price,
        rule: rule, field: "unit_price", type: "ReviewedItem")
    }
    var validBoundIDs: [Int64] = []
    for (name, price) in [("inclusive-minimum", "0.01"), ("inclusive-maximum", "1000000")] {
      var parent = try await owner(); parent.updateContactPhone("5550975")
      var child = try await Q.orderItems().comment("Prepare a valid exact-bound child")
        .purpose("Ensure numeric Checker ranges remain inclusive").newEntity(context)
      child.updateProductName(name); child.updateUnitPrice(Decimal(string: price)!)
      parent.orderItemList.append(child)
      let saved = try await parent.auditAs("Persist an exact inclusive numeric boundary").save(context)
      let rows = try await Q.orderItems().limit(200).comment("Inspect valid exact-bound children")
        .purpose("Verify Decimal persistence using generated Q and E").executeForList(context)
      var matching = 0
      for row in rows where try E.orderItem(row).purchaseOrderId().eval() == saved.id {
        try require(try E.orderItem(row).unitPrice().eval() == Decimal(string: price)!, "Decimal boundary changed on persistence")
        matching += 1
      }
      try require(matching == 1, "Missing persisted inclusive-bound child")
      validBoundIDs.append(saved.id)
    }
    struct Result: Encodable {
      let language = "swift", normalGeneratedSave = true, sameDatabase = true, positiveProviderCalibration = true
      let passed: Bool, observations: [Observation], invalidSaves: Int, wireProjections: Int
      let validBoundIDs: [Int64], failures: [String]
    }
    let result = Result(passed: allFailures.isEmpty, observations: observations, invalidSaves: observations.count,
      wireProjections: observations.reduce(0) { $0 + $1.wires.values.reduce(0) { $0 + $1.count } },
      validBoundIDs: validBoundIDs, failures: allFailures)
    print("SWIFT_CHECKER_METADATA=" + String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    // Emit every observation without a Swift top-level-error crash truncating
    // stdout. verify-local.cjs requires passed=true and returns nonzero for any
    // recorded metadata, range or provider-effect failure.
  }
}
