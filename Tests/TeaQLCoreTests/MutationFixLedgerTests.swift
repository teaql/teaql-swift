import Foundation
import Testing
@testable import TeaQLCore

@Suite("Canonical Fix publication into graph ledgers")
struct MutationFixLedgerTests {
  private let time = Date(timeIntervalSince1970: 1_961_669_730)
  private func fixture() throws -> (EntityDescriptor, EntityRoot, EntityKey, Mutation) {
    let entity = EntityDescriptor(name: "FixLedgerProbe", table: "fix_ledger_probe", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "contactPhone", modelName: "contact_phone", type: .string),
      PropertyDescriptor(name: "updateTime", modelName: "update_time", type: .timestamp),
    ])
    let ledger = EntityRoot(), key = EntityKey(entity: entity.name, id: .int(1))
    try ledger.setOriginalVersion(key, version: 1)
    ledger.set(key, field: "contact_phone", value: .string("original pending input"))
    let mutation = Mutation(kind: .update, entity: entity, id: .int(1), values: ledger.change(key),
      expectedVersion: 1, auditReason: "verify reviewed Fix publication")
    return (entity, ledger, key, mutation)
  }
  private func context(_ entity: EntityDescriptor, provider: FixLedgerProvider,
    checker: any EntityChecker = FixLedgerChecker(),
    review: @escaping @Sendable (MutationPlan) throws -> Void = { _ in }) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "fix-ledger-test", entities: [entity], checkers: [entity.name: checker]))
    return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in FixLedgerPolicy(review: review) },
      businessClock: FixedBusinessClock(time))
  }

  @Test func approvedFixPublishesCanonicalKeysBeforeProviderWithoutChangingVersionOrCommitting() async throws {
    let (entity, ledger, key, mutation) = try fixture(), provider = FixLedgerProvider()
    let expected = TeaQLValue.timestamp(Int64(time.timeIntervalSince1970 * 1_000))
    let context = try context(entity, provider: provider) { plan in
      #expect(ledger.change(key)["update_time"] == nil)
      #expect(plan.operations.first?.changedValues["update_time"] == expected)
    }
    try await context.executeGraphSave(comment: "publish only an approved Fix", preparing: { context, _ in
      _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
      #expect(ledger.change(key)["update_time"] == nil)
    }) { context, _ in
      #expect(ledger.change(key)["update_time"] == expected)
      _ = try await context.execute(mutation, ledgerRoot: ledger, ledgerKey: key)
    }
    #expect(ledger.change(key) == ["contact_phone": .string("original pending input"), "update_time": expected])
    #expect(ledger.originalVersion(key) == 1)
    #expect(await provider.writes.first?.values["update_time"] == expected)
    #expect(await provider.commits == 1)
  }

  @Test func aDeniedPolicyCannotPublishFixedFields() async throws {
    let (entity, ledger, key, mutation) = try fixture(), provider = FixLedgerProvider()
    let context = try context(entity, provider: provider) { _ in
      throw MutationPolicyError.denied(code: "DENIED", message: "keep original input")
    }
    do {
      try await context.executeGraphSave(comment: "deny this prepared graph", preparing: { context, _ in
        _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
      }) { _, _ in Issue.record("denied graph entered execution") }
      Issue.record("denied policy was ignored")
    } catch let error as MutationPolicyError { #expect(error == .denied(code: "DENIED", message: "keep original input")) }
    #expect(ledger.change(key) == mutation.values)
    #expect(await provider.begins == 0)
  }

  @Test func throwingOrRejectingCheckerCannotPublishPartialFixes() async throws {
    for mode in [FixLedgerChecker.Mode.throwing, .rejecting] {
      let (entity, ledger, key, mutation) = try fixture(), provider = FixLedgerProvider()
      let context = try context(entity, provider: provider, checker: FixLedgerChecker(mode: mode))
      var rejected = false
      do {
        try await context.executeGraphSave(comment: "retain rejected Fix isolation", preparing: { context, _ in
          _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
        }) { _, _ in Issue.record("rejected checker entered execution") }
      } catch { rejected = true }
      #expect(rejected)
      #expect(ledger.change(key) == mutation.values)
      #expect(ledger.originalVersion(key) == 1)
      #expect(await provider.begins == 0)
    }
  }

  @Test func aPolicyEditIsNotOverwrittenByRuntimeFixPublication() async throws {
    let (entity, ledger, key, mutation) = try fixture(), provider = FixLedgerProvider()
    let context = try context(entity, provider: provider) { _ in
      ledger.set(key, field: "contact_phone", value: .string("newer customer edit"))
    }
    do {
      try await context.executeGraphSave(comment: "reject a changed caller ledger", preparing: { context, _ in
        _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
      }) { _, _ in Issue.record("changed ledger entered execution") }
      Issue.record("changed caller ledger was accepted")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(ledger.change(key) == ["contact_phone": .string("newer customer edit")])
    #expect(await provider.begins == 0)
  }

  @Test func aProviderFailureRetainsExactApprovedFixAndOriginalPendingIntent() async throws {
    let (entity, ledger, key, mutation) = try fixture(), provider = FixLedgerProvider(fail: true)
    let context = try context(entity, provider: provider)
    do {
      try await context.executeGraphSave(comment: "retain approved values after provider rejection", preparing: { context, _ in
        _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
      }) { context, _ in _ = try await context.execute(mutation, ledgerRoot: ledger, ledgerKey: key) }
      Issue.record("failed provider was accepted")
    } catch let error as TeaQLError { #expect(error == .execution("simulated provider rejection")) }
    #expect(ledger.change(key) == ["contact_phone": .string("original pending input"),
      "update_time": .timestamp(Int64(time.timeIntervalSince1970 * 1_000))])
    #expect(ledger.originalVersion(key) == 1)
    #expect(await provider.begins == 1)
    #expect(await provider.commits == 0)
    #expect(await provider.rollbacks == 1)
  }

  @Test func writesAfterPublicationStillInvalidateTheReviewedSnapshot() async throws {
    let (entity, ledger, key, mutation) = try fixture()
    let provider = FixLedgerProvider(onWrite: { ledger.set(key, field: "contact_phone", value: .string("later edit")) })
    let context = try context(entity, provider: provider)
    do {
      try await context.executeGraphSave(comment: "guard edits after Fix publication", preparing: { context, _ in
        _ = try context.preflightMutation(mutation, ledgerRoot: ledger, ledgerKey: key)
      }) { context, _ in _ = try await context.execute(mutation, ledgerRoot: ledger, ledgerKey: key) }
      Issue.record("post-publication caller drift was committed")
    } catch let error as MutationPolicyError { #expect(error == .operationOutsideReviewedPlan) }
    #expect(ledger.change(key)["contact_phone"] == .string("later edit"))
    #expect(await provider.commits == 0)
    #expect(await provider.rollbacks == 1)
  }

  @Test func sameNumericIdentityOfAnotherEntityTypeDoesNotReceiveTheFix() throws {
    let (entity, ledger, _, mutation) = try fixture()
    let foreign = EntityKey(entity: "OtherType", id: .int(1))
    try ledger.setOriginalVersion(foreign, version: 9)
    let prepared = PreparedGraphMutations(), state = ledger.mutationSnapshot(foreign)
    var fixed = mutation; fixed.values["update_time"] = .timestamp(42)
    try prepared.record(original: mutation, fixed: fixed, ledger: ledger, ledgerKey: foreign, state: state)
    try prepared.sealAndValidate(); try prepared.publishFixesAfterReview()
    #expect(ledger.change(foreign).isEmpty)
    #expect(ledger.originalVersion(foreign) == 9)
    #expect(entity.name != foreign.entity)
  }

  @Test func publicationCopiesOnlyChangedCanonicalFieldsAndNeverIdentityOrVersion() throws {
    let (_, ledger, key, original) = try fixture()
    var fixed = original
    fixed.values["update_time"] = .timestamp(42)
    fixed.values["id"] = .int(99); fixed.values["version"] = .int(99)
    let prepared = PreparedGraphMutations(), state = ledger.mutationSnapshot(key)
    try prepared.record(original: original, fixed: fixed, ledger: ledger, ledgerKey: key, state: state)
    try prepared.sealAndValidate(); try prepared.publishFixesAfterReview(); try prepared.publishFixesAfterReview()
    #expect(ledger.change(key) == ["contact_phone": .string("original pending input"), "update_time": .timestamp(42)])
    #expect(ledger.originalVersion(key) == 1)
    try prepared.validateLedgers()
  }
}

private struct FixLedgerChecker: EntityChecker {
  enum Mode { case accepted, throwing, rejecting }
  var mode: Mode = .accepted
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    mutation.values["update_time"] = .timestamp(Int64(now.timeIntervalSince1970 * 1_000))
    switch mode {
    case .accepted: return []
    case .throwing: throw TeaQLError.execution("checker failed after a candidate Fix")
    case .rejecting: return [CheckResult(ruleID: "required", location: .property("contact_phone"), message: "reject candidate Fix")]
    }
  }
}
private struct FixLedgerPolicy: MutationPolicy {
  let review: @Sendable (MutationPlan) throws -> Void
  let identity = MutationPolicyIdentity(policyID: "fix-ledger-test", version: "1", fingerprint: "fixture")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    try review(plan); return MutationPolicyDecision(verdict: .allow)
  }
}
private actor FixLedgerProvider: QueryExecutor, GraphTransactionExecutor {
  let fail: Bool
  let onWrite: @Sendable () -> Void
  private(set) var begins = 0, commits = 0, rollbacks = 0
  private(set) var writes: [Mutation] = []
  init(fail: Bool = false, onWrite: @escaping @Sendable () -> Void = {}) { self.fail = fail; self.onWrite = onWrite }
  func beginGraphTransaction() async throws { begins += 1 }
  func commitGraphTransaction() async throws { commits += 1 }
  func rollbackGraphTransaction() async throws { rollbacks += 1 }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "fix-ledger-test") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes.append(request.mutation); onWrite()
    if fail { throw TeaQLError.execution("simulated provider rejection") }
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
}
