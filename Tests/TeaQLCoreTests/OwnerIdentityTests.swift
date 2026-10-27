import Foundation
import Testing
@testable import TeaQLCore

@Suite("Unchanged owner identity admission")
struct OwnerIdentityTests {
  @Test(arguments: ["id", "version", "nativeAndLedger", "zeroID", "zeroVersion", "bothZero", "negativeVersion"])
  func aForgedUnchangedReadViewIsNotAStandaloneNoOp(_ route: String) async throws {
    let entity = try forged(route), effects = IdentityEffects(), provider = IdentityProvider()
    let context = try identityContext(provider, effects)
    await rejectAsync { _ = try await entity.auditAs("validate the loaded owner identity").save(context) }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.commands.isEmpty)
    #expect(await provider.begins == 0)
    #expect(await provider.commits == 0)
    #expect(!entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test(arguments: ["id", "version", "zeroVersion"])
  func versionValidationChecksIdentityBeforeItsNoOpBranch(_ route: String) throws {
    let entity = try forged(route)
    reject { _ = try entity.auditAs("admit the complete graph before its clock").validateVersion() }
  }

  @Test(arguments: ["id", "version", "zeroVersion"])
  func preflightChecksIdentityBeforeItsNoOpBranch(_ route: String) throws {
    let entity = try forged(route), effects = IdentityEffects(), provider = IdentityProvider()
    reject { try entity.auditAs("admit an unchanged graph owner").preflight(identityContext(provider, effects)) }
    #expect(effects.counts == [0, 0, 0])
  }

  @Test(arguments: ["id", "version"])
  func executionBridgeAlsoRejectsAnUnchangedForgedOwner(_ route: String) async throws {
    let entity = try forged(route), effects = IdentityEffects(), provider = IdentityProvider()
    let context = try identityContext(provider, effects)
    await rejectAsync {
      _ = try await context.executeGraphSave(comment: "an explicit session cannot authorize identity drift") { context, session in
        try await entity.auditAs("retain loaded provenance").saveInGraph(context, session: session,
          scope: session.scope(key: entity.teaqlEntityKey))
      }
    }
    #expect(effects.counts == [0, 0, 1])
    #expect(await provider.commands.isEmpty)
    #expect(await provider.commits == 0)
    #expect(await provider.rollbacks == 1)
  }

  @Test(arguments: ["id", "version"])
  func aDirtyChildCannotAuthorizeItsForgedUnmodifiedOwner(_ route: String) async throws {
    let owner = try forged(route), child = try IdentityEntity(id: 2, root: owner.teaqlEntityRoot)
    child.teaqlEntityRoot.set(child.teaqlEntityKey, field: "name", value: .string("child secret intention"))
    let effects = IdentityEffects(), provider = IdentityProvider(), context = try identityContext(provider, effects)
    await rejectAsync { _ = try await saveGraph(owner: owner, child: child, context: context) }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.commands.isEmpty)
    #expect(await provider.begins == 0)
    #expect(await provider.commits == 0)
    #expect(child.teaqlEntityRoot.change(child.teaqlEntityKey)["name"] == .string("child secret intention"))
  }

  @Test func anUnchangedOldReadViewRemainsANoOpAfterTheLedgerAdvances() async throws {
    let entity = try IdentityEntity(), effects = IdentityEffects(), provider = IdentityProvider()
    try entity.teaqlEntityRoot.acceptCommittedVersion(entity.teaqlEntityKey, version: 2)
    let context = try identityContext(provider, effects), audited = entity.auditAs("retain a harmless old read view")
    #expect(try !audited.validateVersion()); try audited.preflight(context)
    let same = try await audited.save(context)
    #expect(same.id == 1 && same.version == 1)
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.commands.isEmpty)
    #expect(await provider.begins == 0)
  }

  @Test func anUnmodifiedPartialOwnerCanSaveItsModifiedCompleteChild() async throws {
    let owner = try IdentityEntity(partial: true), child = try IdentityEntity(id: 2, root: owner.teaqlEntityRoot)
    child.teaqlEntityRoot.set(child.teaqlEntityKey, field: "name", value: .string("modified child"))
    let effects = IdentityEffects(), provider = IdentityProvider(), context = try identityContext(provider, effects)
    let saved = try await saveGraph(owner: owner, child: child, context: context)
    #expect(saved.version == 2 && saved.toRecord()["name"] == .string("modified child"))
    #expect(effects.counts == [1, 1, 1])
    #expect(await provider.commands.count == 1)
    #expect(await provider.commands.first?.id == .int(2))
    #expect(await provider.commits == 1)
    #expect(!owner.teaqlEntityRoot.hasPending(owner.teaqlEntityKey))
  }

  @Test func aDirtyOldReadViewStillCannotBorrowTheLedgerVersion() async throws {
    let entity = try IdentityEntity(), effects = IdentityEffects(), provider = IdentityProvider()
    try entity.teaqlEntityRoot.acceptCommittedVersion(entity.teaqlEntityKey, version: 2)
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("dirty old secret"))
    let context = try identityContext(provider, effects)
    await rejectAsync { _ = try await entity.auditAs("do not rebase a dirty old snapshot").save(context) }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.commands.isEmpty)
    #expect(entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test func aNewEntityWithoutLoadedProvenanceStillCreatesNormally() async throws {
    let entity = try IdentityEntity(id: 0, version: 0), effects = IdentityEffects(), provider = IdentityProvider()
    entity.teaqlEntityRoot.markAsNew(entity.teaqlEntityKey)
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("new entity"))
    let saved = try await entity.auditAs("create without claiming a loaded identity").save(identityContext(provider, effects))
    #expect(saved.id == 3 && saved.version == 1)
    #expect(effects.counts == [1, 1, 1])
    #expect(await provider.commands.first?.kind == .create)
    #expect(await provider.commits == 1)
  }
}

private func forged(_ route: String) throws -> IdentityEntity {
  var entity = try IdentityEntity()
  switch route {
  case "id": entity.id = 2
  case "version", "nativeAndLedger": entity.version = 2
  case "zeroID": entity.id = 0
  case "zeroVersion": entity.version = 0
  case "bothZero": entity.id = 0; entity.version = 0
  case "negativeVersion": entity.version = -1
  default: Issue.record("unknown identity route")
  }
  if route == "nativeAndLedger" { try entity.teaqlEntityRoot.acceptCommittedVersion(entity.teaqlEntityKey, version: 2) }
  return entity
}
private func reject(_ action: () throws -> Void) {
  do { try action(); Issue.record("immutable loaded identity was not rejected") }
  catch let error as TeaQLError {
    #expect(String(describing: error).contains("ENTITY_VERSION_CONFLICT"))
    #expect(!String(describing: error).contains("secret"))
  } catch { Issue.record("unexpected rejection: \(error)") }
}
private func rejectAsync(_ action: () async throws -> Void) async {
  do { try await action(); Issue.record("immutable loaded identity was not rejected") }
  catch let error as TeaQLError {
    #expect(String(describing: error).contains("ENTITY_VERSION_CONFLICT"))
    #expect(!String(describing: error).contains("secret"))
  } catch { Issue.record("unexpected rejection: \(error)") }
}
private func saveGraph(owner: IdentityEntity, child: IdentityEntity, context: UserContext) async throws -> IdentityEntity {
  // Handwritten native calibration of the generator's whole-input admission pass.
  // Real generated Q/E/graph saves are a separate SQLite acceptance gate.
  _ = try owner.auditAs("validate the owner before its child").validateVersion()
  _ = try child.auditAs("validate the changed child").validateVersion()
  return try await context.executeGraphSave(comment: "save a partial owner with a complete dirty child",
    preparing: { context, _ in
      try owner.auditAs("unchanged owner").preflight(context)
      try child.auditAs("changed child").preflight(context)
    }) { context, session in
      _ = try await owner.auditAs("unchanged owner").saveInGraph(context, session: session,
        scope: session.scope(key: owner.teaqlEntityKey))
      return try await child.auditAs("changed child").saveInGraph(context, session: session,
        scope: session.scope(key: child.teaqlEntityKey))
    }
}
private final class IdentityEffects: @unchecked Sendable, EntityChecker, MutationPolicy, BusinessClock {
  private let lock = NSLock(); private var values = [0, 0, 0]
  var counts: [Int] { lock.withLock { values } }
  let identity = MutationPolicyIdentity(policyID: "owner-identity", version: "1", fingerprint: "controlled")
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) -> [CheckResult] {
    lock.withLock { values[0] += 1 }; return []
  }
  func review(context: UserContext, plan: MutationPlan) -> MutationPolicyDecision {
    lock.withLock { values[1] += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func now() -> Date { lock.withLock { values[2] += 1 }; return Date(timeIntervalSince1970: 1_792_488_600) }
}
private actor IdentityProvider: QueryExecutor, GraphTransactionExecutor {
  private(set) var commands: [Mutation] = []
  private(set) var begins = 0, commits = 0, rollbacks = 0
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "owner-identity") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    let mutation = request.mutation; commands.append(mutation)
    var record = mutation.values; record["id"] = mutation.id ?? .int(3)
    record["version"] = .int(try MutationVersion.next(for: mutation.kind, original: mutation.expectedVersion))
    return MutationResult(affectedRows: 1, persistedRecord: record)
  }
  func beginGraphTransaction() { begins += 1 }
  func commitGraphTransaction() { commits += 1 }
  func rollbackGraphTransaction() { rollbacks += 1 }
}
private func identityContext(_ provider: IdentityProvider, _ effects: IdentityEffects) throws -> UserContext {
  var runtime = TeaQLRuntime()
  try runtime.install(RuntimeModule(name: "owner identity fixture", entities: [IdentityEntity.descriptor],
    checkers: [IdentityEntity.descriptor.name: effects]))
  return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
    requestPolicy: RequestPolicy { $0 }, diagnosticSQLLogSink: TextDiagnosticSQLLogSink(writer: { _ in }),
    runtimeTelemetry: NoopRuntimeTelemetry(), mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in effects },
    businessClock: effects)
}
private struct IdentityEntity: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "IdentityProbe", table: "identity_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  var id: Int64, version: Int64
  let teaqlEntityRoot: EntityRoot, teaqlLoadedSnapshot: LoadedEntitySnapshot?
  private let fields: TeaQLRecord
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id)) }
  init(id: Int64 = 1, version: Int64 = 1, partial: Bool = false, root: EntityRoot = EntityRoot()) throws {
    var record: TeaQLRecord = ["id": .int(id), "version": .int(version)]
    if !partial { record["name"] = .string("original") }
    try self.init(record: record, root: root)
  }
  init(record: TeaQLRecord, root: EntityRoot = EntityRoot()) throws {
    id = try #require(record["id"]?.int64Value); version = try #require(record["version"]?.int64Value)
    fields = record; teaqlEntityRoot = root
    let key = EntityKey(entity: Self.descriptor.name, id: .int(id))
    if version == 0 { teaqlLoadedSnapshot = nil }
    else {
      try root.setOriginalVersion(key, version: version)
      teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: key, version: version, record: record)
    }
  }
  func toRecord() -> TeaQLRecord { var record = fields; record["id"] = .int(id); record["version"] = .int(version); return record }
  static func from(record: TeaQLRecord) throws -> Self { try Self(record: record) }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("native owner-identity fixture has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("native owner-identity fixture has no wire API") }
}
