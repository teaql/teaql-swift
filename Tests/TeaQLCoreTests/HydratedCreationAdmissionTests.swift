import Foundation
import Testing
@testable import TeaQLCore

private final class HydratedAdmissionCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Int] = [:]
  func add(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
  func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
}
private enum HydratedAdmissionEscape: Error { case provider }
private struct HydratedAdmissionProvider: QueryExecutor, MutationExecutor {
  let calls: HydratedAdmissionCalls
  func execute(_ request: QueryRequest) throws -> QueryResult { calls.add("query"); throw HydratedAdmissionEscape.provider }
  func execute(_ request: MutationRequest) throws -> MutationResult { calls.add("write"); throw HydratedAdmissionEscape.provider }
}
private struct HydratedAdmissionClock: BusinessClock {
  let calls: HydratedAdmissionCalls
  func now() -> Date { calls.add("clock"); return Date(timeIntervalSince1970: 1_800_000_000) }
}
private struct HydratedAdmissionChecker: EntityChecker {
  let calls: HydratedAdmissionCalls
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) -> [CheckResult] { calls.add("checker"); return [] }
}
private struct HydratedAdmissionEntity: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "HydratedAdmission", table: "hydrated_admission_data", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  var id: Int64
  var version: Int64
  var name = "stored"
  var teaqlEntityRoot = EntityRoot()
  var teaqlLoadedSnapshot: LoadedEntitySnapshot?
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id)) }
  init(id: Int64, version: Int64, loaded: Bool, origin: EntitySnapshotOrigin = .hydrated) throws {
    self.id = id; self.version = version
    if loaded {
      try teaqlEntityRoot.setOriginalVersion(teaqlEntityKey, version: version)
      teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: teaqlEntityKey, version: version, record: toRecord(), origin: origin)
    } else { teaqlEntityRoot.markAsNew(teaqlEntityKey) }
  }
  static func from(record: TeaQLRecord) throws -> Self {
    guard case .int(let id) = record["id"], case .int(let version) = record["version"] else { throw HydratedAdmissionEscape.provider }
    return try Self(id: id, version: version, loaded: true)
  }
  func toRecord() -> TeaQLRecord { ["id": .int(id), "version": .int(version), "name": .string(name)] }
  init(from decoder: Decoder) throws { self = try Self.from(record: TeaQLRecord(from: decoder)) }
  func encode(to encoder: Encoder) throws { try toRecord().encode(to: encoder) }
}

@Suite("Hydrated data cannot silently create business entities")
struct HydratedCreationAdmissionTests {
  private func context(_ calls: HydratedAdmissionCalls) throws -> UserContext {
    let provider = HydratedAdmissionProvider(calls: calls)
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "hydrated-admission", entities: [HydratedAdmissionEntity.descriptor],
      checkers: [HydratedAdmissionEntity.descriptor.name: HydratedAdmissionChecker(calls: calls)]))
    return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, querySQLLogEnabled: false, mutationSQLLogEnabled: false,
      businessClock: HydratedAdmissionClock(calls: calls))
  }
  private func unchanged(_ calls: HydratedAdmissionCalls) {
    for key in ["query", "write", "checker", "clock"] { #expect(calls.count(key) == 0, "unexpected callback: \(key)") }
  }
  @Test func changedHydratedZeroVersionRejectsBeforeEveryCustomerCallback() async throws {
    for id in [Int64(0), 77] {
      let calls = HydratedAdmissionCalls(), ctx = try context(calls), entity = try HydratedAdmissionEntity(id: id, version: 0, loaded: true)
      entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("changed"))
      let audited = AuditedEntity(entity: entity, reason: "edit a hydrated input")
      for action in ["validate", "preflight", "save"] {
        do {
          if action == "validate" { _ = try audited.validateVersion() }
          else if action == "preflight" { try audited.preflight(ctx) }
          else { _ = try await audited.save(ctx) }
          Issue.record("hydrated input became create through \(action)")
        } catch { #expect(String(describing: error).hasPrefix("ENTITY_CREATION_CONTEXT_REQUIRED:")) }
      }
      unchanged(calls)
    }
  }
  @Test func addingNewIntentCannotConvertHydratedInputIntoCreation() throws {
    let entity = try HydratedAdmissionEntity(id: 77, version: 0, loaded: true)
    entity.teaqlEntityRoot.markAsNew(entity.teaqlEntityKey)
    do { _ = try AuditedEntity(entity: entity, reason: "invalid promotion").validateVersion(); Issue.record("promoted hydrated input") }
    catch { #expect(String(describing: error).hasPrefix("ENTITY_CREATION_CONTEXT_REQUIRED:")) }
  }
  @Test func untouchedHydratedZeroVersionIsAnInertReadView() async throws {
    let calls = HydratedAdmissionCalls(), ctx = try context(calls), entity = try HydratedAdmissionEntity(id: 77, version: 0, loaded: true)
    let audited = AuditedEntity(entity: entity, reason: "leave an untouched related read view alone")
    #expect(try audited.validateVersion() == false); try audited.preflight(ctx)
    let saved = try await audited.save(ctx); #expect(saved.id == 77 && saved.version == 0); unchanged(calls)
  }
  @Test func ordinaryReservedNewEntityStillReachesChecker() throws {
    let calls = HydratedAdmissionCalls(), ctx = try context(calls), entity = try HydratedAdmissionEntity(id: 41, version: 0, loaded: false)
    let audited = AuditedEntity(entity: entity, reason: "create a managed control")
    #expect(try audited.validateVersion()); try audited.preflight(ctx)
    #expect(calls.count("checker") == 1 && calls.count("clock") > 0); #expect(calls.count("write") == 0)
  }
  @Test func persistedDirtyEntityStillUsesOrdinaryUpdateValidation() throws {
    let calls = HydratedAdmissionCalls(), ctx = try context(calls), entity = try HydratedAdmissionEntity(id: 77, version: 3, loaded: true)
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("changed"))
    let audited = AuditedEntity(entity: entity, reason: "update a persisted control")
    #expect(try audited.validateVersion()); try audited.preflight(ctx); #expect(calls.count("checker") == 1)
  }
  @Test func unchangedPersistedEntityStillDoesNotWrite() async throws {
    let calls = HydratedAdmissionCalls(), ctx = try context(calls), entity = try HydratedAdmissionEntity(id: 77, version: 3, loaded: true)
    #expect(try AuditedEntity(entity: entity, reason: "unchanged control").validateVersion() == false)
    _ = try await AuditedEntity(entity: entity, reason: "unchanged control").save(ctx); unchanged(calls)
  }
  @Test func snapshotSharingKeepsHydrationSeparateFromCreationBaselines() {
    let pool = LoadedEntitySnapshots(), key = EntityKey(entity: "HydratedAdmission", id: .int(77)), record: TeaQLRecord = ["name": .string("same")]
    let loaded = pool.capture(key: key, version: 0, record: record)
    let created = pool.capture(key: key, version: 0, record: record, origin: .creationBaseline)
    #expect(loaded.origin == .hydrated && created.origin == .creationBaseline); #expect(loaded !== created)
    #expect(loaded === pool.capture(key: key, version: 0, record: record))
    #expect(created === pool.capture(key: key, version: 0, record: record, origin: .creationBaseline))
  }
  @Test func aCreationBaselineWithoutNewIntentDoesNotAuthorizeInsert() throws {
    let entity = try HydratedAdmissionEntity(id: 77, version: 0, loaded: true, origin: .creationBaseline)
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("changed"))
    do { _ = try AuditedEntity(entity: entity, reason: "missing creation intent").validateVersion(); Issue.record("snapshot alone authorized creation") }
    catch { #expect(String(describing: error).hasPrefix("ENTITY_CREATION_CONTEXT_REQUIRED:")) }
  }
}
