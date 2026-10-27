import Foundation
import Testing
@testable import TeaQLCore

@Suite("Mutation lifecycle safety")
struct MutationLifecycleTests {
  @Test(arguments: ["update", "delete"])
  func aStaleStructCannotBorrowTheLedgersNewerCommittedVersion(_ operation: String) async throws {
    var entity = try LifecycleEntity(); entity.assign("first save")
    let provider = LifecycleProvider(pause: LifecyclePause()), effects = LifecycleEffects(), clock = LifecycleClock()
    let context = try lifecycleContext(provider, effects: effects, clock: clock)
    let saved = try await AuditedEntity(entity: entity, reason: "commit the first caller snapshot").save(context)
    #expect(saved.version == 2 && entity.version == 1)
    #expect(entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 2)
    let beforeClock = clock.reads
    if operation == "delete" { entity.teaqlEntityRoot.markAsDeleted(entity.teaqlEntityKey) }
    else { entity.assign("stale secret intention") }
    do {
      _ = try await AuditedEntity(entity: entity, reason: "do not rebase an old object implicitly").save(context)
      Issue.record("an old object silently borrowed the committed ledger version")
    } catch let error as TeaQLError {
      #expect(String(describing: error).contains("ENTITY_VERSION_CONFLICT"))
      #expect(!String(describing: error).contains("stale secret intention"))
    }
    #expect(effects.fixes == 1 && effects.reviews == 1 && clock.reads == beforeClock)
    #expect(await provider.commands.count == 1)
    #expect(await provider.commits == 1)
    #expect(await provider.stored["version"] == .int(2))
    #expect(await provider.audits == 1)
    #expect(entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test func theFreshAuthoritativeReturnCanBeSavedAgain() async throws {
    var entity = try LifecycleEntity(); entity.assign("first save")
    let provider = LifecycleProvider(pause: LifecyclePause()), context = try lifecycleContext(provider)
    var saved = try await AuditedEntity(entity: entity, reason: "obtain an authoritative snapshot").save(context)
    saved.assign("second save")
    let next = try await AuditedEntity(entity: saved, reason: "modify the returned current snapshot").save(context)
    #expect(next.version == 3 && next.name == "second save")
    #expect(await provider.commands.map(\.expectedVersion) == [1, 2])
    #expect(await provider.commits == 2)
    #expect(await provider.audits == 2)
  }

  @Test func anUnchangedOldReadViewDoesNotCreateAnotherMutation() async throws {
    var entity = try LifecycleEntity(); entity.assign("first save")
    let provider = LifecycleProvider(pause: LifecyclePause()), effects = LifecycleEffects(), clock = LifecycleClock()
    let context = try lifecycleContext(provider, effects: effects, clock: clock)
    _ = try await AuditedEntity(entity: entity, reason: "commit one snapshot").save(context)
    let beforeClock = clock.reads
    let unchanged = try await AuditedEntity(entity: entity, reason: "keep an unchanged old read view").save(context)
    #expect(unchanged.version == 1 && !entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
    #expect(effects.fixes == 1 && effects.reviews == 1 && clock.reads == beforeClock)
    #expect(await provider.commands.count == 1)
    #expect(await provider.commits == 1)
  }

  @Test(arguments: ["native", "nativeAndLedger", "identity"])
  func aMutableNativeFieldCannotReplaceTheImmutableLoadedIdentity(_ route: String) async throws {
    var entity = try LifecycleEntity()
    if route == "identity" { entity.id = 2 }
    else { entity.version = 2 }
    if route == "nativeAndLedger" { try entity.teaqlEntityRoot.acceptCommittedVersion(entity.teaqlEntityKey, version: 2) }
    entity.assign("unverified secret snapshot")
    let provider = LifecycleProvider(pause: LifecyclePause()), effects = LifecycleEffects(), clock = LifecycleClock()
    let context = try lifecycleContext(provider, effects: effects, clock: clock)
    do {
      _ = try await AuditedEntity(entity: entity, reason: "retain immutable loaded identity").save(context)
      Issue.record("mutable identity fields replaced loaded provenance")
    } catch let error as TeaQLError {
      #expect(String(describing: error).contains("ENTITY_VERSION_CONFLICT"))
      #expect(!String(describing: error).contains("unverified secret snapshot"))
    }
    #expect(effects.fixes == 0 && effects.reviews == 0 && clock.reads == 0)
    #expect(await provider.commands.isEmpty)
    #expect(await provider.commits == 0)
    #expect(entity.teaqlEntityRoot.hasPending(entity.teaqlEntityKey))
  }

  @Test(arguments: ["id", "version", "entity", "kind", "table", "privacy", "actor", "category", "lineage", "provenance"])
  func fieldFixCannotReplaceTheMutationEnvelope(_ field: String) async throws {
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause), effects = LifecycleEffects(replacement: field)
    let context = try lifecycleContext(provider, effects: effects)
    do {
      _ = try await context.execute(Mutation(kind: .update, entity: LifecycleEntity.descriptor, id: .int(1),
        values: ["name": .string("submitted")], expectedVersion: 1, auditReason: "retain the original mutation envelope"))
      Issue.record("field Fix retargeted \(field)")
    } catch let error as CheckException {
      #expect(error.violations.contains { $0.ruleID == "invalid_type" })
      #expect(error.violations.allSatisfy { $0.entityType == LifecycleEntity.descriptor.name })
    }
    #expect(effects.fixes == 1 && effects.reviews == 0)
    #expect(await provider.commands.isEmpty)
    #expect(await provider.audits == 0)
  }

  @Test func ordinaryFieldFixStillExecutesOnceWithTrustedMetadata() async throws {
    let provider = LifecycleProvider(pause: LifecyclePause()), effects = LifecycleEffects(replacement: "value")
    let context = try lifecycleContext(provider, effects: effects)
    let result = try await context.execute(Mutation(kind: .update, entity: LifecycleEntity.descriptor, id: .int(1),
      values: ["name": .string("submitted")], expectedVersion: 1, auditReason: "allow an ordinary field repair"))
    #expect(result.persistedRecord?["name"] == .string("fixed"))
    #expect(effects.fixes == 1 && effects.reviews == 1)
    let command = await provider.commands.first
    #expect(command?.actor == "trusted-actor" && command?.auditCategory == "trusted-category")
  }

  @Test func aRequestOwnedReasonSurvivesAFieldFixWithoutRejectingTheWrite() async throws {
    let provider = LifecycleProvider(pause: LifecyclePause()), effects = LifecycleEffects(replacement: "reason")
    let context = try lifecycleContext(provider, effects: effects)
    _ = try await context.execute(Mutation(kind: .update, entity: LifecycleEntity.descriptor, id: .int(1),
      values: ["name": .string("submitted")], expectedVersion: 1, auditReason: "the caller owns this reason"))
    #expect(effects.fixes == 1 && effects.reviews == 1)
    #expect(await provider.commands.first?.auditReason == "the caller owns this reason")
    #expect(await provider.audits == 1)
  }

  @Test func editDuringProviderRollsBackAndTheSameObjectRetriesTheNewerIntent() async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .write)
    let context = try lifecycleContext(provider)
    let original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "save the original caller intention").save(context) }
    await pause.waitUntilArrived()
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("newer"))
    await pause.release()
    do { _ = try await saving.value; Issue.record("provider-window edit was committed and cleared") }
    catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(await provider.stored["name"] == .string("original"))
    #expect(await provider.rollbacks == 1)
    #expect(await provider.audits == 0)
    #expect(entity.teaqlEntityRoot.change(entity.teaqlEntityKey)["name"] == .string("newer"))
    #expect(entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 1)
    let retried = try await AuditedEntity(entity: entity, reason: "retry the preserved newer intention").save(context)
    #expect(retried.name == "newer" && retried.version == 2)
    #expect(await provider.stored["name"] == .string("newer"))
    #expect(await provider.commits == 1)
    #expect(await provider.audits == 1)
  }

  @Test func editDuringCommitIsPreservedAndReportedAsAlreadyCommitted() async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .commit)
    let context = try lifecycleContext(provider), original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "preserve the commit-window edit").save(context) }
    await pause.waitUntilArrived()
    entity.teaqlEntityRoot.set(entity.teaqlEntityKey, field: "name", value: .string("newer"))
    await pause.release()
    do { _ = try await saving.value; Issue.record("commit cleanup silently removed the newer edit") }
    catch let error as GraphCommittedError {
      #expect(error.committed && error.causes.count == 1)
      let cause = try #require(error.causes.first as? EntityCommitStateConflict)
      #expect(cause.code == "ENTITY_PENDING_CHANGED_AFTER_COMMIT" && cause.committedVersion == 2)
      #expect(cause.originalKey == entity.teaqlEntityKey && cause.persistedKey == entity.teaqlEntityKey)
      #expect(!cause.description.contains("newer") && !cause.description.contains("submitted"))
    }
    #expect(await provider.stored["name"] == .string("submitted"))
    #expect(await provider.stored["version"] == .int(2))
    #expect(await provider.commits == 1)
    #expect(await provider.rollbacks == 0)
    #expect(await provider.audits == 1)
    #expect(entity.teaqlEntityRoot.change(entity.teaqlEntityKey)["name"] == .string("newer"))
    #expect(entity.teaqlEntityRoot.originalVersion(entity.teaqlEntityKey) == 1)
  }

  @Test(arguments: ["reason", "trace"])
  func laterResponsibilityMetadataSurvivesCommitCleanup(_ field: String) async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    entity.teaqlEntityRoot.setLocalAuditReason(entity.teaqlEntityKey, reason: "original reason")
    let nextTrace = try TraceScopeToken(key: entity.teaqlEntityKey, reason: "next intention").recover()
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .commit)
    let context = try lifecycleContext(provider), original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "protect responsibility metadata").save(context) }
    await pause.waitUntilArrived()
    if field == "reason" { entity.teaqlEntityRoot.setLocalAuditReason(entity.teaqlEntityKey, reason: "next intention") }
    else {
      entity.teaqlEntityRoot.setTraceChain(entity.teaqlEntityKey, chain: nextTrace)
    }
    await pause.release()
    do { _ = try await saving.value; Issue.record("commit cleanup silently removed responsibility metadata") }
    catch let error as GraphCommittedError { #expect(error.committed) }
    if field == "reason" { #expect(entity.teaqlEntityRoot.localAuditReason(entity.teaqlEntityKey) == "next intention") }
    else {
      let fallback = try TraceScopeToken(key: entity.teaqlEntityKey, reason: "fallback")
      #expect(entity.teaqlEntityRoot.traceChain(entity.teaqlEntityKey, fallback: fallback).last?.comment == "next intention")
    }
    #expect(await provider.audits == 1)
  }

  @Test func cancellationAfterUncooperativeProviderRollsBack() async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .write)
    let context = try lifecycleContext(provider), original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "cancel before graph commit").save(context) }
    await pause.waitUntilArrived(); saving.cancel(); await pause.release()
    do { _ = try await saving.value; Issue.record("cancelled graph committed after provider ignored cancellation") }
    catch is CancellationError { }
    #expect(await provider.stored["version"] == .int(1))
    #expect(await provider.rollbacks == 1)
    #expect(await provider.audits == 0)
    #expect(entity.teaqlEntityRoot.change(entity.teaqlEntityKey)["name"] == .string("submitted"))
  }

  @Test func cancellationDuringCompletedCommitDoesNotPretendRollbackOccurred() async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .commit)
    let context = try lifecycleContext(provider), original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "report an uninterruptible successful commit").save(context) }
    await pause.waitUntilArrived(); saving.cancel(); await pause.release()
    let saved = try await saving.value
    #expect(saved.version == 2)
    #expect(await provider.commits == 1)
    #expect(await provider.rollbacks == 0)
    #expect(await provider.audits == 1)
  }

  @Test func committedStandaloneWriteDoesNotBecomeAFakeCancellationFailure() async throws {
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .write)
    let context = try lifecycleContext(provider)
    let saving = Task { try await context.execute(Mutation(kind: .update, entity: LifecycleEntity.descriptor, id: .int(1),
      values: ["name": .string("submitted")], expectedVersion: 1, auditReason: "standalone provider already committed")) }
    await pause.waitUntilArrived(); saving.cancel(); await pause.release()
    let saved = try await saving.value
    #expect(saved.persistedRecord?["version"] == .int(2))
    #expect(await provider.stored["name"] == .string("submitted"))
    #expect(await provider.audits == 1)
  }

  @Test func anUnreachedTypedKeyCanBeEditedWithoutJoiningTheSave() async throws {
    var entity = try LifecycleEntity(); entity.assign("submitted")
    let pause = LifecyclePause(), provider = LifecycleProvider(pause: pause, phase: .write)
    let context = try lifecycleContext(provider), original = entity
    let saving = Task { try await AuditedEntity(entity: original, reason: "save only the reached typed key").save(context) }
    await pause.waitUntilArrived()
    let other = EntityKey(entity: "AnotherType", id: .int(1))
    entity.teaqlEntityRoot.set(other, field: "name", value: .string("independent pending"))
    await pause.release()
    let saved = try await saving.value
    #expect(saved.version == 2)
    #expect(entity.teaqlEntityRoot.change(other)["name"] == .string("independent pending"))
    #expect(await provider.audits == 1)
  }

  @Test func commitCleanupRekeysOnlyItsUnchangedTypedEntry() throws {
    let root = EntityRoot(), original = EntityKey(entity: "LifecycleProbe", id: .int(-1))
    let persisted = EntityKey(entity: "LifecycleProbe", id: .int(7)), other = EntityKey(entity: "OtherType", id: .int(7))
    root.markAsNew(original); root.set(original, field: "name", value: .string("created"))
    root.set(other, field: "name", value: .string("unrelated"))
    let snapshot = root.mutationSnapshot(original)
    try root.completeCommit(original, to: persisted, expected: snapshot, version: 1)
    #expect(!root.hasPending(original) && !root.hasPending(persisted))
    #expect(root.originalVersion(persisted) == 1 && root.originalVersion(original) == nil)
    #expect(root.change(other)["name"] == .string("unrelated"))
  }

  @Test func aChangedNewEntryRetainsItsTemporaryKeyAndExposesTheCommittedKey() throws {
    let root = EntityRoot(), original = EntityKey(entity: "LifecycleProbe", id: .int(-1))
    let persisted = EntityKey(entity: "LifecycleProbe", id: .int(7))
    root.markAsNew(original); root.set(original, field: "name", value: .string("created"))
    let snapshot = root.mutationSnapshot(original)
    root.set(original, field: "name", value: .string("later secret"))
    do {
      try root.completeCommit(original, to: persisted, expected: snapshot, version: 1)
      Issue.record("a new pending intention was cleared")
    } catch let error as EntityCommitStateConflict {
      #expect(error.originalKey == original && error.persistedKey == persisted && error.committedVersion == 1)
      #expect(!error.description.contains("later secret"))
    }
    #expect(root.isNew(original) && root.change(original)["name"] == .string("later secret"))
    #expect(root.originalVersion(persisted) == nil && root.change(persisted).isEmpty)
  }

  @Test(arguments: ["value", "version", "trace", "reason"])
  func commitCleanupCannotEraseAnExistingDestination(_ field: String) throws {
    let root = EntityRoot(), original = EntityKey(entity: "LifecycleProbe", id: .int(-1))
    let persisted = EntityKey(entity: "LifecycleProbe", id: .int(7))
    root.markAsNew(original); root.set(original, field: "name", value: .string("created"))
    switch field {
    case "value": root.set(persisted, field: "name", value: .string("destination"))
    case "version": try root.setOriginalVersion(persisted, version: 1)
    case "trace": root.setTraceChain(persisted, chain: try TraceScopeToken(key: persisted, reason: "destination").recover())
    default: root.setLocalAuditReason(persisted, reason: "destination")
    }
    let before = root.mutationSnapshot(persisted)
    do {
      try root.completeCommit(original, to: persisted, expected: root.mutationSnapshot(original), version: 1)
      Issue.record("commit cleanup erased a destination \(field)")
    } catch is EntityCommitStateConflict { }
    #expect(before.matches(root.mutationSnapshot(persisted)))
    #expect(root.isNew(original) && root.change(original)["name"] == .string("created"))
  }
}

private actor LifecyclePause {
  private var arrived = false, released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var resume: CheckedContinuation<Void, Never>?
  func checkpoint() async {
    arrived = true; let ready = waiters; waiters = []; for waiter in ready { waiter.resume() }
    if !released { await withCheckedContinuation { resume = $0 } }
  }
  func waitUntilArrived() async {
    if !arrived { await withCheckedContinuation { waiters.append($0) } }
  }
  func release() { released = true; resume?.resume(); resume = nil }
}

private actor LifecycleProvider: QueryExecutor, GraphTransactionExecutor, AuditSink {
  enum Phase: Sendable { case none, write, commit }
  let pause: LifecyclePause, phase: Phase
  private(set) var stored: TeaQLRecord = ["id": .int(1), "version": .int(1), "name": .string("original")]
  private var transaction: TeaQLRecord?
  private(set) var commits = 0, rollbacks = 0, audits = 0
  private(set) var commands: [Mutation] = []
  init(pause: LifecyclePause, phase: Phase = .none) { self.pause = pause; self.phase = phase }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [stored], backend: "controlled-lifecycle-oracle") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    let mutation = request.mutation; commands.append(mutation)
    var row = (transaction ?? stored).merging(mutation.values) { _, new in new }
    row["id"] = mutation.id ?? .int(1)
    row["version"] = .int(try MutationVersion.next(for: mutation.kind, original: mutation.expectedVersion))
    if transaction != nil { transaction = row } else { stored = row }
    if phase == .write && commands.count == 1 { await pause.checkpoint() }
    return MutationResult(affectedRows: 1, persistedRecord: row)
  }
  func beginGraphTransaction() async throws { transaction = stored }
  func commitGraphTransaction() async throws {
    if phase == .commit && commits == 0 { await pause.checkpoint() }
    if let transaction { stored = transaction }; transaction = nil; commits += 1
  }
  func rollbackGraphTransaction() async throws { transaction = nil; rollbacks += 1 }
  func record(_ event: AuditEvent) { audits += 1 }
}

private final class LifecycleEffects: @unchecked Sendable, EntityChecker, MutationPolicy {
  private let lock = NSLock(); private var checked = 0, reviewed = 0
  let replacement: String?
  init(replacement: String? = nil) { self.replacement = replacement }
  var fixes: Int { lock.withLock { checked } }
  var reviews: Int { lock.withLock { reviewed } }
  let identity = MutationPolicyIdentity(policyID: "lifecycle", version: "1", fingerprint: "controlled")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { reviewed += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { checked += 1 }
    switch replacement {
    case "id": mutation.id = .int(2)
    case "version": mutation.expectedVersion = 2
    case "value": mutation.values["name"] = .string("fixed")
    case "actor": mutation.actor = "forged-actor"
    case "category": mutation.auditCategory = "forged-category"
    case "reason": mutation.auditReason = "forged responsibility"
    case "lineage": mutation.mutationLineage = try TraceScopeToken(key: EntityKey(entity: "Forged", id: .int(99)), reason: "forged lineage").recover()
    case "provenance": mutation.loadedValues = ["name": .string("forged provenance")]
    case "entity", "kind", "table", "privacy":
      let original = mutation.entity
      let descriptor = EntityDescriptor(name: replacement == "entity" ? "OtherType" : original.name,
        table: replacement == "table" ? "other_table" : original.table, properties: original.properties,
        auditMaskFields: replacement == "privacy" ? [] : original.auditMaskFields ?? [])
      mutation = Mutation(kind: replacement == "kind" ? .create : mutation.kind, entity: descriptor,
        id: mutation.id, values: mutation.values, expectedVersion: mutation.expectedVersion,
        auditReason: mutation.auditReason, actor: mutation.actor, auditCategory: mutation.auditCategory,
        mutationLineage: mutation.mutationLineage)
    default: break
    }
    return []
  }
}
private final class LifecycleClock: @unchecked Sendable, BusinessClock {
  private let lock = NSLock(); private var count = 0
  var reads: Int { lock.withLock { count } }
  func now() -> Date { lock.withLock { count += 1; return Date(timeIntervalSince1970: 1_792_488_600.125) } }
}

private func lifecycleContext(_ provider: LifecycleProvider, effects: LifecycleEffects = LifecycleEffects(),
  clock: any BusinessClock = SystemBusinessClock()) throws -> UserContext {
  var runtime = TeaQLRuntime()
  try runtime.install(RuntimeModule(name: "lifecycle fixture", entities: [LifecycleEntity.descriptor],
    checkers: [LifecycleEntity.descriptor.name: effects]))
  return UserContext(runtime: runtime, actor: "trusted-actor", auditCategory: "trusted-category",
    queryExecutor: provider, mutationExecutor: provider, requestPolicy: RequestPolicy { $0 }, auditSink: provider,
    mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in effects }, businessClock: clock)
}
private struct LifecycleEntity: TeaQLMutationRootedEntity {
  static let descriptor = EntityDescriptor(name: "LifecycleProbe", table: "lifecycle_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true), PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ], auditMaskFields: ["name"])
  var id: Int64 = 1, version: Int64 = 1
  var name = "original"
  let teaqlEntityRoot: EntityRoot
  let teaqlLoadedSnapshot: LoadedEntitySnapshot?
  var teaqlEntityKey: EntityKey { EntityKey(entity: Self.descriptor.name, id: .int(id)) }
  init(record: TeaQLRecord = ["id": .int(1), "version": .int(1), "name": .string("original")]) throws {
    id = record["id"]?.int64Value ?? 1; version = record["version"]?.int64Value ?? 1
    name = record["name"]?.stringValue ?? "missing"
    teaqlEntityRoot = EntityRoot()
    let key = EntityKey(entity: Self.descriptor.name, id: .int(id))
    try teaqlEntityRoot.setOriginalVersion(key, version: version)
    teaqlLoadedSnapshot = LoadedEntitySnapshots().capture(key: key, version: version, record: record)
  }
  mutating func assign(_ value: String) { name = value; teaqlEntityRoot.set(teaqlEntityKey, field: "name", value: .string(value)) }
  func toRecord() -> TeaQLRecord { ["id": .int(id), "version": .int(version), "name": .string(name)] }
  static func from(record: TeaQLRecord) throws -> Self {
    try Self(record: record)
  }
  init(from decoder: any Decoder) throws { throw TeaQLError.execution("handwritten native lifecycle fixture has no wire API") }
  func encode(to encoder: any Encoder) throws { throw TeaQLError.execution("handwritten native lifecycle fixture has no wire API") }
}
