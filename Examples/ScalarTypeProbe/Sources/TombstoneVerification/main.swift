// Application-owned. Generated Q/E and audited Save are the business APIs.
// CSQLite is restricted to an injected trigger and a read-only physical oracle.
import CSQLite
import Foundation
import GeneratedTeaQL
import TeaQLCore
import TeaQLSQLite

private enum TombstoneFault: Error, Sendable { case beforeCommit }
private struct TombstoneEffects: Codable, Equatable, Sendable {
  var queries = 0, mutations = 0, begins = 0, commits = 0, rollbacks = 0, audits = 0
}
private actor TombstoneProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  let service: SQLiteDataService
  private var calls = TombstoneEffects(), events: [AuditEvent] = []
  private var failCommit = false, auditCountAtFailure = 0
  private var last: MutationResult?
  init(_ service: SQLiteDataService) { self.service = service }
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    calls.queries += 1; return try await service.execute(request)
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    calls.mutations += 1; let result = try await service.execute(request); last = result; return result
  }
  func beginGraphTransaction() async throws { calls.begins += 1; try await service.beginGraphTransaction() }
  func commitGraphTransaction() async throws {
    calls.commits += 1
    if failCommit {
      failCommit = false
      guard last?.persistedRecord?["version"] == .int(-42), events.count == auditCountAtFailure else {
        throw TeaQLError.execution("Commit fault must follow actual readback and precede committed audit")
      }
      throw TombstoneFault.beforeCommit
    }
    try await service.commitGraphTransaction()
  }
  func rollbackGraphTransaction() async throws { calls.rollbacks += 1; try await service.rollbackGraphTransaction() }
  func record(_ event: AuditEvent) { calls.audits += 1; events.append(event) }
  func snapshot() -> TombstoneEffects { calls }
  func recorded() -> [AuditEvent] { events }
  func lastResult() -> MutationResult? { last }
  func armCommitFailure() { failCommit = true; auditCountAtFailure = events.count; last = nil }
}
private struct TombstoneCallbacks: Equatable { var clocks = 0, resolves = 0, reviews = 0 }
private final class TombstonePolicyClock: BusinessClock, MutationPolicyRegistry, MutationPolicy, @unchecked Sendable {
  private let lock = NSLock(); private var calls = TombstoneCallbacks()
  let identity = MutationPolicyIdentity(policyID: "tombstone-example", version: "1", fingerprint: "controlled-SQLite")
  let time = Date(timeIntervalSince1970: 1_961_662_530)
  func now() -> Date { lock.withLock { calls.clocks += 1 }; return time }
  func resolve(requestKey: String) -> (any MutationPolicy)? { lock.withLock { calls.resolves += 1 }; return self }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { calls.reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  var snapshot: TombstoneCallbacks { lock.withLock { calls } }
}
private struct TombstonePhysical: Equatable {
  let version: Int64, name: String, optional: String?, date: String, datetime: Int64, audits: Int64
}

@main enum TombstoneVerification {
  private static let cases = ["ordinary", "trigger", "commit-retry", "provider-commit", "provider-rollback-retry", "provider-roles"]
  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TeaQLError.execution(message) }
  }
  private static func emit(_ record: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("SWIFT_TOMBSTONE=" + String(decoding: data, as: UTF8.self))
  }
  private static func connection(_ path: String, writable: Bool = false, body: (OpaquePointer) throws -> Void) throws {
    var db: OpaquePointer?
    let flags = writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }; throw TeaQLError.execution("Cannot open the owned tombstone oracle")
    }
    defer { sqlite3_close(db) }; try body(db)
  }
  private static func physical(_ path: String, id: Int64) throws -> TombstonePhysical {
    var row: TombstonePhysical?
    try connection(path) { db in
      var statement: OpaquePointer?
      let sql = "SELECT version,required_string,optional_string,required_date,required_datetime,(SELECT COUNT(*) FROM teaql_row_audit_event) FROM scalar_type_probe_data WHERE id=?"
      try require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Cannot prepare the read-only oracle")
      defer { sqlite3_finalize(statement) }
      try require(sqlite3_bind_int64(statement, 1, id) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW, "Physical row missing")
      func text(_ n: Int32) -> String { String(cString: sqlite3_column_text(statement, n)) }
      row = TombstonePhysical(version: sqlite3_column_int64(statement, 0), name: text(1),
        optional: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : text(2), date: text(3),
        datetime: sqlite3_column_int64(statement, 4), audits: sqlite3_column_int64(statement, 5))
    }
    guard let row else { throw TeaQLError.execution("Physical oracle returned nothing") }; return row
  }
  private static func trigger(_ path: String, id: Int64) throws {
    try require(id > 0, "Trigger must target one real test row")
    try connection(path, writable: true) { db in
      let sql = "CREATE TRIGGER tombstone_\(id) AFTER UPDATE OF version ON scalar_type_probe_data WHEN NEW.id=\(id) AND NEW.version<0 AND OLD.version>0 BEGIN UPDATE scalar_type_probe_data SET version=NEW.version-40,required_string='DB-TOMBSTONE-'||NEW.id,optional_string=NULL,required_date='2040-02-29',required_datetime=2214137716000 WHERE id=NEW.id; END"
      try require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "Cannot inject the owned SQLite trigger")
    }
  }
  private static func make(_ context: UserContext, name: String) throws -> ScalarTypeProbe {
    var row = try Q.scalarTypeProbes().comment("Prepare one tombstone fixture").purpose("Verify authoritative deletion").newEntity(context)
    row.updateTypePlatform(1); row.updateRequiredString(name); row.updateOptionalString("before deletion")
    row.updateRequiredBoolean(true); row.updateRequiredInteger(7); row.updateRequiredLong(8); row.updateRequiredDecimal(Decimal(string: "3.50")!)
    row.updateRequiredFloat(1.25); row.updateRequiredDouble(2.5); row.updateRequiredDate(Date(timeIntervalSince1970: 1_709_164_800))
    row.updateRequiredTime("12:30:00"); row.updateRequiredDatetime(Date(timeIntervalSince1970: 1_792_499_400)); return row
  }
  private static func load(_ context: UserContext, id: Int64) async throws -> ScalarTypeProbe? {
    try await Q.scalarTypeProbes().withIdIs(id).limit(1).comment("Reload the exact tombstone fixture")
      .purpose("Verify ordinary generated Q/E visibility").executeForList(context).first
  }
  private static func checkResult(_ result: MutationResult, version: Int64) throws {
    try require(result.affectedRows == 1 && result.persistedRecord?["version"] == .int(version), "Native readback is not authoritative")
    try require(result.generatedValues["version"] == .int(version),
      "generatedValues.version contradicts authoritative persistedRecord: \(String(describing: result.generatedValues["version"])) != \(version)")
  }
  private static func one(_ kind: String, round: Int, path: String, service: SQLiteDataService, runtime: TeaQLRuntime) async throws {
    let provider = TombstoneProvider(service), callbacks = TombstonePolicyClock()
    let context = UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 },
      auditSink: provider, querySQLLogEnabled: false, mutationSQLLogEnabled: false, mutationPolicyRegistry: callbacks, businessClock: callbacks)
    let name = "swift-tombstone-\(round)-\(kind)-" + UUID().uuidString
    let seed = try make(context, name: name), saved = try await seed.auditAs("Seed an existing deletion fixture").save(context)
    guard var row = try await load(context, id: saved.id) else { throw TeaQLError.execution("Generated fixture not loaded") }
    try require(row.version == 1 && saved.id > 0, "Seed identity/version missing")
    let triggered = kind != "ordinary", expected: Int64 = triggered ? -42 : -2
    if triggered { try trigger(path, id: row.id) }
    let before = try physical(path, id: row.id), auditsBefore = await provider.recorded().count
    let key = row.teaqlEntityKey
    var rolledBack = false, nativeConsistency: MutationResult?
    let native = kind.hasPrefix("provider-") && kind != "provider-roles"
    if native {
      let mutation = Mutation(kind: .delete, entity: ScalarTypeProbe.descriptor, id: .int(row.id), expectedVersion: 1,
        auditReason: "Explicit native provider transaction, not a caller-owned generated Save")
      do {
        try await service.beginGraphTransaction(); let first = try await service.execute(mutation)
        try require(first.persistedRecord?["version"] == .int(expected), "Native transaction did not read the trigger value")
        try require(try physical(path, id: row.id) == before, "Uncommitted native write escaped its transaction")
        if kind == "provider-rollback-retry" {
          try await service.rollbackGraphTransaction(); rolledBack = true
          try require(try physical(path, id: row.id) == before, "Native rollback changed durable data/audit")
          try await service.beginGraphTransaction(); nativeConsistency = try await service.execute(mutation)
        } else { nativeConsistency = first }
        try await service.commitGraphTransaction()
      } catch { try? await service.rollbackGraphTransaction(); throw error }
      try require(await provider.recorded().count == auditsBefore, "Native SPI must not manufacture a Context audit")
    } else {
      let effectsBeforeMark = await provider.snapshot(), callbacksBeforeMark = callbacks.snapshot
      row.markForDeletion()
      try require(await provider.snapshot() == effectsBeforeMark && callbacks.snapshot == callbacksBeforeMark, "MarkForDeletion performed I/O")
      if kind == "commit-retry" {
        await provider.armCommitFailure()
        do { _ = try await row.auditAs("Roll back before physical commit").save(context); throw TeaQLError.execution("Injected commit unexpectedly succeeded") }
        catch TombstoneFault.beforeCommit { rolledBack = true }
        try require(try physical(path, id: row.id) == before, "Failed commit changed durable data/audit")
        try require(row.version == 1 && row.requiredString == name && row.optionalString == "before deletion", "Failed commit changed the caller value")
        try require(row.teaqlEntityRoot.isDeleted(key) && row.teaqlEntityRoot.originalVersion(key) == 1, "Failed commit lost deletion intent or original version")
        try require(await provider.recorded().count == auditsBefore, "Rollback delivered committed audit")
      }
      // No second mark: this must consume the retained original deletion intent.
      let deleted = try await row.auditAs("Save the authoritative tombstone").save(context)
      try require(deleted.version == expected, "Generated Save returned a computed tombstone")
      let expectedName = triggered ? "DB-TOMBSTONE-\(row.id)" : name
      try require(try E.scalarTypeProbe(deleted).requiredString().eval() == expectedName, "E missed authoritative text")
      if triggered {
        try require(deleted.isLoaded("optionalString") && (try E.scalarTypeProbe(deleted).optionalString().eval()) == nil, "Loaded null became NotLoaded")
        try require(deleted.requiredDate == Date(timeIntervalSince1970: 2_214_086_400)
          && deleted.requiredDatetime == Date(timeIntervalSince1970: 2_214_137_716), "Typed temporal readback changed")
      }
      try require(await provider.recorded().count == auditsBefore + 1, "Deletion committed audit count changed")
      let effects = await provider.snapshot(), callbackCounts = callbacks.snapshot
      var repeated = deleted; repeated.markForDeletion()
      do { _ = try await repeated.auditAs("Reject repeated deletion before clock policy or provider").save(context); throw TeaQLError.execution("Repeated deletion succeeded") }
      catch let error as MutationVersionError { try require(error.code == .invalidState, "Wrong repeated-deletion admission") }
      try require(await provider.snapshot() == effects && callbacks.snapshot == callbackCounts, "Repeated deletion reached a side-effect boundary")
      nativeConsistency = await provider.lastResult()
    }
    try require(try physical(path, id: row.id).version == expected, "Physical tombstone version is wrong")
    try require(try await load(context, id: row.id) == nil, "Ordinary query exposed a tombstone")
    var returnedVersion = expected, blindRejected = false
    if kind == "provider-roles" {
      let prior = try physical(path, id: row.id)
      do {
        _ = try await service.execute(Mutation(kind: .delete, entity: ScalarTypeProbe.descriptor, id: .int(row.id), auditReason: "Reject a versionless tombstone deletion"))
        throw TeaQLError.execution("A blind deletion API was invented")
      } catch let error as MutationVersionError { try require(error.code == .invalidState, "Wrong versionless admission"); blindRejected = true }
      try require(try physical(path, id: row.id) == prior, "Versionless rejection rewrote the tombstone")
      returnedVersion = 43
      let recovery = try await context.execute(Mutation(kind: .recover, entity: ScalarTypeProbe.descriptor, id: .int(row.id), expectedVersion: expected, auditReason: "Explicit trusted recovery"))
      try checkResult(recovery, version: returnedVersion)
      try require(try await load(context, id: row.id)?.version == returnedVersion, "Recovery did not restore generated Q visibility")
    }
    let stored = try physical(path, id: row.id), auditDelta = await provider.recorded().count - auditsBefore
    try require(stored.version == returnedVersion && stored.name == (triggered ? "DB-TOMBSTONE-\(row.id)" : name), "Storage result changed")
    try require(stored.audits == before.audits + (kind == "provider-roles" ? 2 : 1), "Physical audit rows escaped rollback/commit")
    try require(auditDelta == (native ? 0 : kind == "provider-roles" ? 2 : 1), "Runtime audit confused native provider ownership")
    guard let nativeConsistency else { throw TeaQLError.execution("Native result was not observed") }
    try checkResult(nativeConsistency, version: expected)
    try emit(["case": kind, "passed": true, "round": round, "id": String(row.id), "version": String(returnedVersion),
      "deletedVersion": String(expected), "name": stored.name, "triggered": triggered, "rolledBack": rolledBack,
      "nativeProviderTransaction": native, "blindRejected": blindRejected, "auditDelta": auditDelta,
      "physicalAuditDelta": Int(stored.audits - before.audits), "repeatZeroEffects": !native,
      "nativeGeneratedVersionConsistent": true, "physicalDeleteSupported": false, "callerOwnedGeneratedSaveTransactionSupported": false])
  }
  static func main() async {
    do {
      let env = ProcessInfo.processInfo.environment
      guard let path = env["TEAQL_SWIFT_TOMBSTONE_DB"], let round = env["TEAQL_SWIFT_TOMBSTONE_ROUND"].flatMap(Int.init), [1, 2].contains(round) else {
        throw TeaQLError.execution("Set an explicit retained tombstone database and round 1 or 2")
      }
      let service = try SQLiteDataService(path: path); var runtime = TeaQLRuntime(); try runtime.install(GeneratedRuntimeModule.module)
      let schema = UserContext(runtime: runtime, queryExecutor: service, mutationExecutor: service, requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false)
      try await schema.ensureSchema(GeneratedRuntimeModule.module); try await schema.ensureSchema(GeneratedRuntimeModule.module)
      var failures = 0
      for kind in cases {
        do { try await one(kind, round: round, path: path, service: service, runtime: runtime) }
        catch { failures += 1; try emit(["case": kind, "round": round, "passed": false, "error": String(describing: error)]) }
      }
      try require(failures == 0, "Authoritative tombstone cases failed: \(failures)")
      print("PASS Swift generated authoritative tombstones: 6 cases, round \(round)")
    } catch { print("SWIFT_TOMBSTONE_FAILURE=" + String(describing: error)); exit(1) }
  }
}
