import Foundation
import Testing
@testable import TeaQLCore

@Suite("Immutable prepared graph mutations")
struct PreparedMutationSnapshotTests {
  private func descriptor(_ name: String = "PreparedProbe", table: String = "prepared_probe") -> EntityDescriptor {
    EntityDescriptor(name: name, table: table, properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "value", type: .double),
    ])
  }

  private func command(_ entity: EntityDescriptor) -> Mutation {
    Mutation(kind: .update, entity: entity, id: .int(1), values: ["value": .double(1)],
      expectedVersion: 1, auditReason: "execute the exact reviewed mutation")
  }

  private func context(_ provider: SnapshotProvider, entities: [EntityDescriptor],
    checkers: [String: any EntityChecker], policy: SnapshotPolicy) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "prepared-snapshot-fixture", entities: entities, checkers: checkers))
    return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy })
  }

  @Test func batchFixRunsOnceAndProviderReceivesExactlyTheReviewedValue() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix(), plans = SnapshotPlans()
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { plans.add($0) })
    let results = try await context.execute(MutationBatchRequest(mutations: [command(entity)], comment: "freeze one batch operation"))
    #expect(fix.count == 1)
    #expect(plans.values.flatMap(\.operations).map { $0.changedValues["value"] } == [.double(7.5)])
    #expect(results.first?.persistedRecord?["value"] == .double(7.5))
    #expect(await provider.writes.map { $0.values["value"] } == [.double(7.5)])
  }

  @Test func typedLedgerIdentityDoesNotAuthorizeChangedFieldsTargetsVersionsOrMetadata() async throws {
    for route in 0..<5 {
      let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix()
      let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in })
      let original = command(entity), key = EntityKey(entity: entity.name, id: .int(1))
      var changed = original
      switch route {
      case 0: changed.values["value"] = .double(999)
      case 1: changed.id = .int(2)
      case 2: changed.expectedVersion = 2
      case 3: changed.values.removeValue(forKey: "value")
      default: changed = Mutation(kind: .update, entity: descriptor(table: "other_storage"), id: .int(1),
        values: original.values, expectedVersion: 1, auditReason: original.auditReason)
      }
      let proposal = changed
      do {
        try await context.executeGraphSave(comment: "reject a changed reviewed operation", preparing: { context, _ in
          _ = try context.preflightMutation(original, ledgerKey: key)
        }) { context, _ in _ = try await context.execute(proposal, ledgerRoot: nil, ledgerKey: key) }
        Issue.record("changed operation reached the provider, route \(route)")
      } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
      #expect(await provider.writes.isEmpty)
      #expect(fix.count == 1)
    }
  }

  @Test func policyCannotMutateTheCallerLedgerBehindItsReviewedSnapshot() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix(), ledger = EntityRoot()
    let key = EntityKey(entity: entity.name, id: .int(1)); ledger.set(key, field: "value", value: .double(1))
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in
      ledger.set(key, field: "value", value: .double(999))
    })
    let original = command(entity)
    do {
      try await context.executeGraphSave(comment: "retain a newer caller edit", preparing: { context, _ in
        _ = try context.preflightMutation(original, ledgerRoot: ledger, ledgerKey: key)
      }) { context, _ in _ = try await context.execute(original, ledgerRoot: ledger, ledgerKey: key) }
      Issue.record("policy changed a captured ledger without rejection")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(await provider.writes.isEmpty)
    #expect(await provider.begins == 0)
    #expect(ledger.change(key)["value"] == .double(999))
    #expect(fix.count == 1)
  }

  @Test func deniedPolicyDoesNotPublishTheFixIntoThePendingLedger() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix(), ledger = EntityRoot()
    let key = EntityKey(entity: entity.name, id: .int(1)); ledger.set(key, field: "value", value: .double(1))
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in
      throw MutationPolicyError.denied(code: "DENIED", message: "keep the caller input")
    })
    let original = command(entity)
    do {
      try await context.executeGraphSave(comment: "deny a fixed graph", preparing: { context, _ in
        _ = try context.preflightMutation(original, ledgerRoot: ledger, ledgerKey: key)
      }) { _, _ in Issue.record("denied graph reached execution") }
      Issue.record("denied policy was ignored")
    } catch let error as MutationPolicyError { #expect(error == .denied(code: "DENIED", message: "keep the caller input")) }
    #expect(ledger.change(key)["value"] == .double(1))
    #expect(await provider.begins == 0)
    #expect(fix.count == 1)
  }

  @Test func aPreparedMutationCannotBeConsumedTwiceOrRefixedForASecondAttempt() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix()
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in })
    let original = command(entity)
    do {
      try await context.executeGraphSave(comment: "one snapshot is one operation", preparing: { context, _ in
        _ = try context.preflightMutation(original)
      }) { context, _ in
        _ = try await context.execute(original)
        _ = try await context.execute(original)
      }
      Issue.record("snapshot executed twice")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(fix.count == 1)
    #expect(await provider.writes.count == 1)
    #expect(await provider.commits == 0)
    #expect(await provider.rollbacks == 1)
  }

  @Test func equalIDsOfDifferentEntityTypesKeepSeparatePreparedSnapshots() async throws {
    let first = descriptor("First"), second = descriptor("Second"), provider = SnapshotProvider()
    let firstFix = SnapshotCounterFix(), secondFix = SnapshotCounterFix(base: 90.5), ledger = EntityRoot()
    let context = try context(provider, entities: [first, second], checkers: [first.name: firstFix, second.name: secondFix],
      policy: SnapshotPolicy { _ in })
    let a = command(first), b = command(second), ka = EntityKey(entity: first.name, id: .int(1)), kb = EntityKey(entity: second.name, id: .int(1))
    try await context.executeGraphSave(comment: "retain type qualified snapshot identities", preparing: { context, _ in
      _ = try context.preflightMutation(a, ledgerRoot: ledger, ledgerKey: ka)
      _ = try context.preflightMutation(b, ledgerRoot: ledger, ledgerKey: kb)
    }) { context, _ in
      _ = try await context.execute(a, ledgerRoot: ledger, ledgerKey: ka)
      _ = try await context.execute(b, ledgerRoot: ledger, ledgerKey: kb)
    }
    #expect(firstFix.count == 1 && secondFix.count == 1)
    #expect(await provider.writes.map { $0.values["value"] } == [.double(7.5), .double(91.5)])
  }

  @Test func aFiniteFixCanRepairANonreflexiveNaNSubmissionOnce() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix()
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in })
    var original = command(entity); original.values["value"] = .double(.nan)
    let results = try await context.execute(MutationBatchRequest(mutations: [original], comment: "repair a submitted NaN once"))
    #expect(fix.count == 1)
    #expect(results.first?.persistedRecord?["value"] == .double(7.5))
  }

  @Test func aFixCannotReplaceTheLoadedIdentityOrOptimisticVersion() async throws {
    for field in ["id", "version"] {
      let entity = descriptor(), provider = SnapshotProvider()
      let context = try context(provider, entities: [entity], checkers: [entity.name: SnapshotIdentityFix(field: field)], policy: SnapshotPolicy { _ in })
      do {
        _ = try await context.execute(MutationBatchRequest(mutations: [command(entity)], comment: "retain the original mutation identity"))
        Issue.record("Fix replaced the loaded \(field)")
      } catch let error as CheckException {
        #expect(error.violations.contains { $0.ruleID == "invalid_type" && $0.location.modelPath == field })
      }
      #expect(await provider.begins == 0)
      #expect(await provider.writes.isEmpty)
    }
  }

  @Test func aLedgerKeyCannotBlessAnUnreviewedForeignKeyAssignment() async throws {
    let entity = EntityDescriptor(name: "Child", table: "child", properties: [
      PropertyDescriptor(name: "parent", type: .int, nullable: true, isRelation: true),
    ]), provider = SnapshotProvider()
    let context = try context(provider, entities: [entity], checkers: [:], policy: SnapshotPolicy { _ in })
    let original = Mutation(kind: .create, entity: entity, values: ["parent": .null], auditReason: "retain the reviewed parent")
    let changed = Mutation(kind: .create, entity: entity, values: ["parent": .int(1)], auditReason: original.auditReason)
    let key = EntityKey(entity: entity.name, id: .int(-1))
    do {
      try await context.executeGraphSave(comment: "reject an unproven FK assignment", preparing: { context, _ in
        _ = try context.preflightMutation(original, ledgerKey: key)
      }) { context, _ in _ = try await context.execute(changed, ledgerRoot: nil, ledgerKey: key) }
      Issue.record("ledger identity hid a changed FK")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(await provider.writes.isEmpty)
  }

  @Test func theReturnedPreflightValueExecutesWithoutASecondFix() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix()
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { _ in })
    let original = command(entity)
    let result = try await context.executeGraphSave(comment: "consume the explicit preflight result") { context, _ in
      let fixed = try context.preflightMutation(original)
      return try await context.execute(fixed)
    }
    #expect(fix.count == 1)
    #expect(result.persistedRecord?["value"] == .double(7.5))
  }

  @Test func executionCannotMixPartsOfTheOriginalAndFixedRecords() async throws {
    let base = descriptor(), entity = EntityDescriptor(name: base.name, table: base.table,
      properties: base.properties + [PropertyDescriptor(name: "note", type: .string)])
    let provider = SnapshotProvider(), context = try context(provider, entities: [entity],
      checkers: [entity.name: SnapshotMultiFieldFix()], policy: SnapshotPolicy { _ in })
    var original = command(entity); original.values["note"] = .string("original")
    let submitted = original
    do {
      try await context.executeGraphSave(comment: "reject a mixed execution payload") { context, _ in
        var fixed = try context.preflightMutation(submitted)
        fixed.values["note"] = .string("original")
        _ = try await context.execute(fixed)
      }
      Issue.record("partially restored fields bypassed the complete reviewed snapshot")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(await provider.writes.isEmpty)
  }

  @Test func reusingOneContextStartsANewFixAndPolicySnapshotForEachGraph() async throws {
    let entity = descriptor(), provider = SnapshotProvider(), fix = SnapshotCounterFix(), plans = SnapshotPlans()
    let context = try context(provider, entities: [entity], checkers: [entity.name: fix], policy: SnapshotPolicy { plans.add($0) })
    for id in [Int64(1), 2] {
      var original = command(entity); original.id = .int(id)
      _ = try await context.execute(MutationBatchRequest(mutations: [original], comment: "save an independent graph"))
    }
    #expect(fix.count == 2 && plans.values.count == 2)
    #expect(plans.values.flatMap(\.operations).map(\.entityID) == [.int(1), .int(2)])
    #expect(await provider.writes.map { $0.values["value"] } == [.double(7.5), .double(8.5)])
    #expect(await provider.commits == 2)
  }
}

private struct SnapshotMultiFieldFix: EntityChecker {
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.values["value"] = .double(7.5); mutation.values["note"] = .string("fixed")
    return []
  }
}

private struct SnapshotIdentityFix: EntityChecker {
  let field: String
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    if field == "id" { mutation.id = .int(2) } else { mutation.expectedVersion = 2 }
    return []
  }
}

private final class SnapshotCounterFix: @unchecked Sendable, EntityChecker {
  private let lock = NSLock(); private var calls = 0; private let base: Double
  init(base: Double = 6.5) { self.base = base }
  var count: Int { lock.withLock { calls } }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.values["value"] = .double(lock.withLock { calls += 1; return base + Double(calls) })
    return []
  }
}
private final class SnapshotPlans: @unchecked Sendable {
  private let lock = NSLock(); private var plans: [MutationPlan] = []
  func add(_ value: MutationPlan) { lock.withLock { plans.append(value) } }
  var values: [MutationPlan] { lock.withLock { plans } }
}
private struct SnapshotPolicy: MutationPolicy {
  let inspect: @Sendable (MutationPlan) throws -> Void
  init(_ inspect: @escaping @Sendable (MutationPlan) throws -> Void) { self.inspect = inspect }
  let identity = MutationPolicyIdentity(policyID: "snapshot", version: "1", fingerprint: "local-fixture")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    try inspect(plan); return MutationPolicyDecision(verdict: .allow)
  }
}
private actor SnapshotProvider: QueryExecutor, GraphTransactionExecutor {
  private(set) var begins = 0, commits = 0, rollbacks = 0
  private(set) var writes: [Mutation] = []
  func beginGraphTransaction() async throws { begins += 1 }
  func commitGraphTransaction() async throws { commits += 1 }
  func rollbackGraphTransaction() async throws { rollbacks += 1 }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes.append(request.mutation); return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "snapshot-spy") }
}
