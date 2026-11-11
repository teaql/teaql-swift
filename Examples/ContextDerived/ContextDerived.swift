import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ value: Bool, _ message: String) throws { if !value { throw TeaQLError.execution(message) } }
private final class Observer: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink, @unchecked Sendable {
  let service: SQLiteDataService
  private let lock = NSLock()
  private var providerCalls = 0, auditCalls = 0
  init(_ service: SQLiteDataService) { self.service = service }
  private func call() { lock.withLock { providerCalls += 1 } }
  func execute(_ request: QueryRequest) async throws -> QueryResult { call(); return try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult { call(); return try await service.execute(request) }
  func beginGraphTransaction() async throws { call(); try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { call(); try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { call(); try await service.rollbackGraphTransaction() }
  func nextID(for entity: String, context: UserContext) async throws -> Int64 { call(); return try await service.nextID(for: entity, context: context) }
  func record(_ event: AuditEvent) { lock.withLock { auditCalls += 1 } }
  var counts: (provider: Int, audits: Int) { lock.withLock { (providerCalls, auditCalls) } }
  func reset() { lock.withLock { providerCalls = 0; auditCalls = 0 } }
}
private final class Resolver: ContextFixResolver, @unchecked Sendable {
  private let lock = NSLock()
  private var phase = "A", failToken = false
  private var count = 0, tokenCount = 0, nowCount = 0
  private var normalizedName: String?
  func normalize(to value: String?) { lock.withLock { normalizedName = value } }
  var normalization: String? { lock.withLock { normalizedName } }
  func configure(_ phase: String, fail: Bool = false) { lock.withLock { self.phase = phase; failToken = fail } }
  func reset() { lock.withLock { count = 0 } }
  var calls: Int { lock.withLock { count } }
  var tokens: Int { lock.withLock { tokenCount } }
  var clocks: Int { lock.withLock { nowCount } }
  func resolve(context: UserContext, input: ContextFixInput) throws -> TeaQLValue {
    try lock.withLock {
      count += 1
      if input.function == "now" { nowCount += 1; return .timestamp(Int64(input.now.timeIntervalSince1970 * 1_000)) }
      if input.function == "uniStr" {
        tokenCount += 1; if failToken { throw TeaQLError.execution("PRIVATE_CONTEXT_PROVIDER_SECRET") }
        return .string("token-" + UUID().uuidString)
      }
      return .string(input.function + "-" + phase)
    }
  }
}
private struct Checker: EntityChecker {
  let generated: any EntityChecker
  let resolver: Resolver
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if mutation.kind == .create {
      try ContextFix.apply(context, mutation: &mutation, now: now, field: "source_ip", function: "ip")
      try ContextFix.apply(context, mutation: &mutation, now: now, field: "opened_by", function: "actor")
    }
    try ContextFix.apply(context, mutation: &mutation, now: now, field: "last_ip", function: "ip")
    try ContextFix.apply(context, mutation: &mutation, now: now, field: "changed_by", function: "actor")
    let results = try generated.checkAndFix(context: context, mutation: &mutation, now: now)
    if mutation.kind == .update, mutation.values["name"] == .string("NORMALIZE"), let value = resolver.normalization {
      mutation.values["name"] = .string(value)
    }
    return results
  }
}

@main enum ContextDerived {
  @MainActor static func main() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000), module = GeneratedRuntimeModule.module
    let database = ProcessInfo.processInfo.environment["TEAQL_CONTEXT_FIX_DB"] ?? ":memory:"
    let service = try SQLiteDataService(path: database), observer = Observer(service), resolver = Resolver()
    var runtime = TeaQLRuntime(); try runtime.install(module)
    try runtime.install(RuntimeModule(name: "Application Context metadata", entities: [],
      checkers: ["Entry": Checker(generated: runtime.checker(named: "Entry")!, resolver: resolver)],
      contextFixFields: ["Entry": ["source_ip": .init(create: "ip"), "last_ip": .init(create: "ip", update: "ip"),
        "opened_by": .init(create: "actor"), "changed_by": .init(create: "actor", update: "actor")]]))
    func context(_ time: Date, schema: Bool = false) -> UserContext {
      UserContext(runtime: runtime, actor: "Context example", queryExecutor: schema ? service : observer,
        mutationExecutor: schema ? service : observer, requestPolicy: RequestPolicy { $0 }, auditSink: observer,
        querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: FixedBusinessClock(time), contextFixResolver: resolver)
    }
    let a = context(now); try await context(now, schema: true).ensureSchema(module)
    let suffix = String(UUID().uuidString.prefix(8))
    func new(_ name: String, _ ctx: UserContext) throws -> Entry {
      var entry = try Q.entries().comment("Prepare a Context-bearing subject").purpose("Verify generated audited saves").newEntity(ctx)
      entry.updateCatalog(1); entry.updateName(name); return entry
    }
    func load(_ id: Int64, _ ctx: UserContext) async throws -> Entry {
      let rows = try await Q.entries().withIdIs(id).limit(1).comment("Reload the Context subject")
        .purpose("Verify persisted values through typed E").executeForList(ctx)
      try require(rows.count == 1, "Expected one saved subject"); return rows[0]
    }
    func reject(_ work: () async throws -> Void) async throws -> CheckException {
      do { try await work() } catch let error as CheckException { return error }
      throw TeaQLError.execution("Expected a rejected save")
    }
    func reset() { observer.reset(); resolver.reset() }
    func zero(_ label: String) throws { try require(observer.counts == (0, 0), label + " must not enter provider or audit") }
    let draft = try new("initial-" + suffix, a)
    var loaded = try await draft.auditAs("Create using Context defaults").save(a)
    loaded = try await load(loaded.id, a)
    try require(try E.entry(loaded).bornAt().eval() == now && E.entry(loaded).touchedAt().eval() == now, "Business Clock create defaults")
    try require(try E.entry(loaded).sourceIp().eval() == "ip-A" && E.entry(loaded).openedBy().eval() == "actor-A", "create IP/actor")
    try require(resolver.tokens == 1, "unique create default must run once")
    let version = loaded.version, token = loaded.guardedToken
    resolver.configure("B"); let b = context(now.addingTimeInterval(86_400)); reset()
    for _ in 0..<2 { _ = try await loaded.auditAs("Changed Context must not manufacture an update").save(b) }
    try zero("no-op"); try require(resolver.calls == 0 && loaded.version == version, "no-op Context/version")
    let originalName = loaded.name!
    resolver.normalize(to: originalName); loaded.updateName("NORMALIZE"); reset()
    loaded = try await loaded.auditAs("Normalize the last business edit back to baseline").save(b)
    try zero("normalized business edit")
    try require(loaded.name == originalName && loaded.version == version && loaded.touchedAt == now && loaded.lastIp == "ip-A", "normalized native state")
    let clocksBeforeUpdate = resolver.clocks
    loaded.updateName("updated-" + suffix); reset(); loaded = try await loaded.auditAs("Apply Context alongside a real business edit").save(b)
    try require(observer.counts.audits == 1 && resolver.clocks == clocksBeforeUpdate + 1, "one accepted update / once-only Fix")
    loaded = try await load(loaded.id, b)
    try require(loaded.version == version + 1 && loaded.bornAt == now && loaded.touchedAt == now.addingTimeInterval(86_400), "update Clock/version")
    try require(loaded.sourceIp == "ip-A" && loaded.openedBy == "actor-A" && loaded.lastIp == "ip-B" && loaded.changedBy == "actor-B" && loaded.guardedToken == token, "Context scopes")
    let name = loaded.name; loaded.updateName(String(repeating: "x", count: 300)); resolver.configure("C"); reset()
    let error = try await reject { _ = try await loaded.auditAs("Reject a business edit before any write").save(b) }
    try require(error.violations.contains { $0.location.modelPath == "name" }, "business ObjectLocation"); try zero("failed check")
    loaded.updateName(name); reset(); _ = try await loaded.auditAs("Restore a failed edit without stale Context values").save(b)
    try zero("restored edit"); try require(resolver.calls == 0, "failed Fix must not poison no-op")
    loaded.updateName("retry-" + suffix); loaded = try await loaded.auditAs("Retry corrected intent").save(b)
    loaded = try await load(loaded.id, b); try require(loaded.lastIp == "ip-C", "retry Context")
    let failing = try new("fail-" + suffix, b); resolver.configure("C", fail: true); reset()
    let providerError = try await reject { _ = try await failing.auditAs("Reject failed automatic Context resolution").save(b) }
    try require(providerError.violations.contains { $0.location.modelPath == "guarded_token" }
      && !providerError.description.contains("PRIVATE_CONTEXT_PROVIDER_SECRET"), "safe Context provider location")
    try zero("failed provider"); resolver.configure("C"); _ = try await failing.auditAs("Retry a recovered Context provider").save(b)
    var parent = try Q.catalogs().comment("Prepare a complete graph").purpose("Verify per-entity Context isolation").newEntity(b)
    parent.updateName("graph-" + suffix); parent.entryList = SmartList([try new("first-" + suffix, b), try new("second-" + suffix, b)])
    parent = try await parent.auditAs("Create two Context-bearing children").save(b)
    let parents = try await Q.catalogs().withIdIs(parent.id).selectEntryListWith(Q.entries().orderByIdAscending().limit(10)).limit(1)
      .comment("Load the complete Context graph").purpose("Verify later-child failure and retry").executeForList(b)
    parent = parents[0]; try require(parent.entryList.count == 2, "graph cardinality")
    var first = parent.entryList[0], second = parent.entryList[1]
    let firstName = first.name, parentVersion = parent.version, firstVersion = first.version
    var secondName = second.name, secondVersion = second.version
    resolver.normalize(to: firstName); first.updateName("NORMALIZE"); parent.entryList = SmartList([first, second]); reset()
    parent = try await parent.auditAs("Normalize one child without writing clean relatives").save(b)
    try zero("normalized child-only graph")
    first = parent.entryList[0]; second = parent.entryList[1]
    try require(first.name == firstName && first.version == firstVersion && parent.version == parentVersion, "normalized graph native values")
    first.updateName("NORMALIZE"); second.updateName("real-sibling-" + suffix); parent.entryList = SmartList([first, second]); reset()
    parent = try await parent.auditAs("Save the real sibling, not the normalized child").save(b)
    first = parent.entryList[0]; second = parent.entryList[1]
    try require(observer.counts.audits == 1 && first.name == firstName && first.version == firstVersion
      && parent.version == parentVersion && second.version == secondVersion + 1, "mixed graph writes only the genuine sibling")
    secondName = second.name; secondVersion = second.version
    first.updateName("NORMALIZE"); second.updateName(String(repeating: "x", count: 300)); parent.entryList = SmartList([first, second]); reset()
    let normalizedError = try await reject { _ = try await parent.auditAs("Reject an invalid sibling after a normalized child").save(b) }
    try require(normalizedError.violations.contains { $0.location.instancePath == "/entryList/1/name" }, "normalized graph indexed location")
    try zero("normalized child before failed sibling")
    first.updateName(firstName); second.updateName(secondName); parent.entryList = SmartList([first, second]); reset()
    _ = try await parent.auditAs("Restore a rejected normalized graph").save(b); try zero("restored normalized graph")
    first.updateName("dirty-" + suffix); second.updateName(String(repeating: "x", count: 300)); parent.entryList = SmartList([first, second])
    resolver.configure("D"); reset()
    let graphError = try await reject { _ = try await parent.auditAs("Reject the second child before writing either").save(b) }
    try require(graphError.violations.contains { $0.location.instancePath == "/entryList/1/name" }, "indexed child ObjectLocation"); try zero("invalid graph")
    first.updateName(firstName); second.updateName(secondName); parent.entryList = SmartList([first, second]); reset()
    _ = try await parent.auditAs("Restore failed graph edits").save(b); try zero("graph Context undo")
    try require(resolver.calls == 0, "no stale earlier-sibling automatic values")
    first.updateName("accepted-child-" + suffix); parent.entryList = SmartList([first, second]); reset()
    let saved = try await parent.auditAs("Save only the dirty child").save(b)
    try require(observer.counts.audits == 1 && saved.version == parentVersion, "child-only accepted audit")
    let persisted = try await load(first.id, b), unchanged = try await load(second.id, b)
    try require(persisted.name == "accepted-child-" + suffix && persisted.lastIp == "ip-D" && unchanged.version == secondVersion, "child persisted / sibling unchanged")
    let result: [String: Any] = ["passed":true,"typedQ":true,"typedE":true,"noOpProviderCalls":0,"failedCheckProviderCalls":0,
      "updateAudits":1,"objectLocation":true,"graphRollback":true,"fixOnce":true,"physicalId":persisted.id,
      "physicalName":persisted.name!,"physicalVersion":persisted.version]
    print("SWIFT_CONTEXT_FIX_SQLITE=" + String(decoding: try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self))
  }
}
