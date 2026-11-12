import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private func require(_ condition: Bool, _ reason: String) throws {
  if !condition { throw TeaQLError.execution(reason) }
}
private func emit(_ marker: String, _ value: [String: Any]) throws {
  print(marker + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
}
private final class Observer: QueryExecutor, GraphTransactionExecutor, InternalIDGenerator, AuditSink, @unchecked Sendable {
  let service: SQLiteDataService
  private let lock = NSLock()
  private var calls = 0, writes = 0, audits = 0
  init(_ service: SQLiteDataService) { self.service = service }
  private func call() { lock.withLock { calls += 1 } }
  func execute(_ request: QueryRequest) async throws -> QueryResult { call(); return try await service.execute(request) }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    lock.withLock { calls += 1; writes += 1 }; return try await service.execute(request)
  }
  func beginGraphTransaction() async throws { call(); try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws { call(); try await service.commitGraphTransaction() }
  func rollbackGraphTransaction() async throws { call(); try await service.rollbackGraphTransaction() }
  func nextID(for entity: String, context: UserContext) async throws -> Int64 {
    call(); return try await service.nextID(for: entity, context: context)
  }
  func record(_ event: AuditEvent) { lock.withLock { audits += 1 } }
  var counts: (calls: Int, writes: Int, audits: Int) { lock.withLock { (calls, writes, audits) } }
  func reset() { lock.withLock { calls = 0; writes = 0; audits = 0 } }
}
private final class Clock: BusinessClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  func now() -> Date { lock.withLock { value } }
  func set(_ value: Date) { lock.withLock { self.value = value } }
}
private final class RendererCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  func called() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
}

@main enum AutomaticNaturalMessages {
  @MainActor static func main() async throws {
    let service = try SQLiteDataService(path: ProcessInfo.processInfo.environment["TEAQL_NATURAL_MESSAGES_DB"] ?? ":memory:")
    let observer = Observer(service), module = GeneratedRuntimeModule.module
    var runtime = TeaQLRuntime(); try runtime.install(module)
    let firstTime = Date(timeIntervalSince1970: 1_700_000_000), secondTime = firstTime.addingTimeInterval(3600)
    let clock = Clock(firstTime)
    // Schema execution stays on Context; the provider's package-only schema SPI is not exposed here.
    let schemaContext = UserContext(runtime: runtime, actor: "Natural example", queryExecutor: service, mutationExecutor: service,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: clock)
    try await schemaContext.ensureSchema(module); try await schemaContext.ensureSchema(module)
    let roots = try await Q.catalogs().limit(1).comment("Find the provisioned validation root")
      .purpose("Verify generated schema bootstrap").executeForList(schemaContext)
    try require(roots.count == 1, "Exactly one generated root must be provisioned")
    let rootID = roots[0].id
    var context = UserContext(runtime: runtime, actor: "Natural example", activeRoot: ContextEntityRef(entity: "Catalog", id: .int(rootID)),
      queryExecutor: observer, mutationExecutor: observer, requestPolicy: RequestPolicy { $0 }, auditSink: observer,
      querySQLLogEnabled: false, mutationSQLLogEnabled: false, businessClock: clock, internalIDGenerator: observer)
    for name in ["first", "second"] {
      var entry = try Q.entries().comment("Prepare an entry").purpose("Build the bounded validation graph").newEntity(context)
      entry.updateCatalog(rootID); entry.updateName(name)
      _ = try await entry.auditAs("Create an entry with generated audited Save").save(context)
    }
    func load() async throws -> Catalog {
      let rows = try await Q.catalogs().withIdIs(rootID)
        .selectEntryListWith(Q.entries().orderByIdDescending().limit(2).comment("Load the latest validation entries"))
        .limit(1).comment("Load the unchanged root and its bounded child graph")
        .purpose("Verify indexed messages through generated Q and E").executeForList(context)
      try require(rows.count == 1 && rows[0].entryList.count == 2, "Expected one root and two selected entries")
      return rows[0]
    }
    var parent = try await load(), other = parent.entryList[0], child = parent.entryList[1]
    try require(try E.entry(other).name().eval() == "second" && E.entry(child).name().eval() == "first", "Q/E preserve selected order")
    let parentVersion = parent.version, otherVersion = other.version, childVersion = child.version
    let previousTime = try E.entry(child).updateTime().eval()
    try require(previousTime == firstTime, "Generated create/update fields use Business Clock")
    clock.set(secondTime); observer.reset()
    var missingAuditRejected = false
    do { _ = try await parent.auditAs(" ").save(context) }
    catch let error as RequestIntentError {
      try require(error.code == "REQUEST_COMMENT_REQUIRED", "Typed audit intent error")
      missingAuditRejected = true
    }
    try require(missingAuditRejected && observer.counts.calls == 0 && observer.counts.audits == 0, "Blank audit must reject before I/O")
    let secret = String(repeating: "e\u{301}", count: 101)
    try require(secret.count == 101 && secret.unicodeScalars.count == 202, "Measure graphemes, not scalars or mask length")
    var responses = 0
    func reject(_ expected: String) async throws {
      parent.entryList = SmartList([other, child])
      var failure: CheckException?
      do { _ = try await parent.auditAs("Reject invalid input before SQL or committed audit").save(context) }
      catch let error as CheckException { failure = error }
      guard let failure, failure.violations.count == 1 else { throw TeaQLError.execution("Original generated Checker must reject one field") }
      let value = failure.violations[0]
      try require(value.ruleID == "required" || value.ruleID == "max_length", "Original validation rule")
      try require(value.entityType == "Entry" && value.location.modelPath == "entry_list[1].name"
        && value.location.instancePath == "/entryList/1/name", "Declaring type and canonical/wire paths")
      try require(value.message == expected, "Complete natural message at the actual selected position")
      try require(observer.counts.calls == 0 && observer.counts.audits == 0, "Rejection has no provider/transaction/audit effects")
      try require(parent.version == parentVersion && other.version == otherVersion && child.version == childVersion, "Rejected versions unchanged")
      try require(try E.entry(child).updateTime().eval() == previousTime, "Rejected automatic Context values roll back")
      let data = try JSONEncoder().encode(value.wire())
      try require(!failure.description.contains(secret) && !String(decoding: data, as: UTF8.self).contains(secret), "Private value cannot enter diagnostics")
      print("SWIFT_NATURAL_CHECKER_RESPONSE=" + String(decoding: data, as: UTF8.self)); responses += 1
    }
    other.updateName("changed"); child.updateName(nil)
    try await reject("The name of the 2nd entry is required.")
    try context.setLocaleCode("zh-CN")
    try await reject("请填写第2项明细的名称。")
    try context.setLocaleCode("en"); child.updateName(secret)
    try await reject("The name of the 2nd entry must not exceed 100 grapheme clusters; its current length is 101.")
    let renderer = RendererCalls()
    context.installCheckerMessageRenderer { request in
      guard request.arguments["input_len"] == "101", request.arguments["input"] != secret else {
        throw TeaQLError.execution("Renderer must receive safe values and original measurement")
      }
      renderer.called(); return CheckerMessageOutput("Private " + secret)
    }
    try await reject("Private [REDACTED]")
    try require(renderer.count == 1, "Graph relocation must not call customer rendering twice")
    other.updateName("second"); child.updateName("first"); parent.entryList = SmartList([other, child]); observer.reset()
    _ = try await parent.auditAs("Do not persist Context-only assignments").save(context)
    try require(observer.counts.calls == 0 && observer.counts.audits == 0, "Restored caller intent is a no-op")
    child.updateName("accepted"); parent.entryList = SmartList([other, child])
    parent = try await parent.auditAs("Save only the corrected second child").save(context)
    try require(observer.counts.writes == 1 && observer.counts.audits == 1, "Only the corrected child writes and audits")
    let loaded = try await load(), corrected = loaded.entryList[1]
    try require(try E.entry(corrected).name().eval() == "accepted" && E.entry(corrected).updateTime().eval() == secondTime,
      "Generated Q/E verify the saved value and injected time")
    try require(loaded.version == parentVersion && loaded.entryList[0].version == otherVersion && corrected.version == childVersion + 1,
      "Unchanged parent and sibling retain their versions")
    try emit("SWIFT_NATURAL_SQLITE=", ["passed": true, "typedQ": true, "typedE": true, "automaticMetadata": true,
      "originalGeneratedChecker": true, "unchangedParent": true, "missingAuditRejected": missingAuditRejected, "responses": responses,
      "customerRendererCalls": renderer.count, "failedCheckProviderCalls": 0, "correctedWrites": 1, "correctedAudits": 1,
      "originalLength": 101, "unicodeScalars": 202, "parentId": loaded.id, "firstId": loaded.entryList[0].id,
      "secondId": corrected.id, "parentVersion": parentVersion, "firstVersion": otherVersion, "secondVersion": corrected.version])
  }
}
