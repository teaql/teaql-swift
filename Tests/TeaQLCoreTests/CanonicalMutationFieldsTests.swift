import Foundation
import Testing
@testable import TeaQLCore

private let canonicalEntity = EntityDescriptor(name: "CanonicalProbe", table: "canonical_probe", properties: [
  PropertyDescriptor(name: "id", type: .int, isID: true),
  PropertyDescriptor(name: "version", type: .int, isVersion: true),
  PropertyDescriptor(name: "requiredString", modelName: "required_string", column: "legacy_text", type: .string),
  PropertyDescriptor(name: "typePlatformId", modelName: "type_platform", column: "legacy_owner", type: .int, isRelation: true),
])

@Suite struct CanonicalMutationFieldsTests {
  @Test(arguments: [MutationKind.create, .update],
    ["requiredString", "legacy_text", "typePlatformId", "type_platform_id", "legacy_owner", "unknown_field"])
  func malformedInputNeverReachesCustomerCodeOrProvider(_ kind: MutationKind, _ field: String) async throws {
    let effects = CanonicalEffects(), provider = CanonicalProvider()
    let context = try context(effects, provider)
    do {
      _ = try await context.execute(mutation(kind, [field: .string("private-canary-do-not-log")]))
      Issue.record("Malformed mutation field was accepted")
    } catch let error as CheckException {
      #expect(error.violations.count == 1)
      #expect(error.violations[0].ruleID == "unknown_field")
      #expect(error.violations[0].entityType == canonicalEntity.name)
      #expect(error.violations[0].inputValue == nil)
      #expect(error.violations[0].systemValue == nil)
      #expect(!String(describing: error).contains("private-canary-do-not-log"))
    }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.counts == [0, 0, 0])
  }

  @Test(arguments: [false, true])
  func logicalAndStorageDuplicatesAreRejectedEvenWhenEqual(_ equal: Bool) async throws {
    let effects = CanonicalEffects(), provider = CanonicalProvider()
    let context = try context(effects, provider)
    do {
      _ = try await context.execute(mutation(.update,
        ["type_platform": .int(1), "typePlatformId": .int(equal ? 1 : 2)]))
      Issue.record("Logical and storage duplicate was accepted")
    } catch let error as CheckException {
      #expect(error.violations.map(\.ruleID) == ["unknown_field"])
      #expect(error.violations[0].location.modelPath == "type_platform")
    }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.counts == [0, 0, 0])
  }

  @Test func aLaterMalformedBatchItemPreventsEveryEarlierFixAndTransaction() async throws {
    let effects = CanonicalEffects(), provider = CanonicalProvider()
    let context = try context(effects, provider)
    do {
      _ = try await context.execute(MutationBatchRequest(mutations: [
        mutation(.update, ["required_string": .string("first")]),
        mutation(.update, ["type_platform_id": .int(1)]),
      ], comment: "admit the whole batch before customer code"))
      Issue.record("Malformed batch reached graph execution")
    } catch let error as CheckException { #expect(error.violations[0].ruleID == "unknown_field") }
    #expect(effects.counts == [0, 0, 0])
    #expect(await provider.counts == [0, 0, 0])
  }

  @Test func rejectedPreflightRetainsPendingLedgerAndCanonicalErrorLocation() throws {
    let effects = CanonicalEffects(), provider = CanonicalProvider()
    let context = try context(effects, provider), ledger = EntityRoot()
    let key = EntityKey(entity: canonicalEntity.name, id: .int(1))
    ledger.set(key, field: "required_string", value: .string("keep this intention"))
    ledger.set(key, field: "requiredString", value: .string("malformed intention"))
    let original = ledger.snapshot()
    do {
      _ = try context.preflightMutation(mutation(.update, ledger.change(key)), ledgerRoot: ledger, ledgerKey: key)
      Issue.record("Malformed preflight reached Fix")
    } catch let error as CheckException {
      #expect(error.violations[0].location.modelPath == "required_string")
      #expect(error.violations[0].wire().instancePath == "/requiredString")
    }
    #expect(ledger.snapshot() == original)
    #expect(effects.counts == [0, 0, 0])
  }

  @Test func customFixCannotIntroduceAnAliasOrUnknownField() async throws {
    for field in ["requiredString", "legacy_owner", "unknown_field"] {
      let effects = CanonicalEffects(introduce: field), provider = CanonicalProvider()
      let context = try context(effects, provider)
      do {
        _ = try await context.execute(mutation(.update, ["required_string": .string("valid")]))
        Issue.record("Invalid custom Fix reached policy/provider")
      } catch let error as CheckException { #expect(error.violations[0].ruleID == "unknown_field") }
      #expect(effects.counts == [1, 0, 1])
      #expect(await provider.counts == [0, 0, 0])
    }
  }

  @Test func equalValueRestorationDoesNotDiscardMalformedAliases() throws {
    let ledger = EntityRoot(), key = EntityKey(entity: canonicalEntity.name, id: .int(1))
    try ledger.setOriginalVersion(key, version: 1)
    let values: TeaQLRecord = ["requiredString": .string("original"), "typePlatformId": .int(7)]
    let snapshot = LoadedEntitySnapshots().capture(key: key, version: 1, record: values)
    ledger.set(key, field: "required_string", value: .string("original"))
    ledger.set(key, field: "requiredString", value: .string("original"))
    ledger.set(key, field: "typePlatformId", value: .int(7))
    ledger.discardRestoredFields(key, snapshot: snapshot, descriptor: canonicalEntity)
    #expect(ledger.change(key) == values)
    do { _ = try mutation(.update, ledger.change(key)).validatedForExecution()
      Issue.record("Malformed equal-value aliases disappeared during restoration")
    } catch let error as CheckException {
      #expect(error.violations.count == 2)
      #expect(error.violations.allSatisfy { $0.ruleID == "unknown_field" })
    }
  }

  @Test func canonicalKeysRemainUnchangedThroughFixPolicyAndProvider() async throws {
    let effects = CanonicalEffects(), provider = CanonicalProvider()
    let context = try context(effects, provider)
    let values: TeaQLRecord = ["required_string": .string("valid"), "type_platform": .int(7)]
    _ = try await context.execute(mutation(.update, values))
    #expect(effects.fields == Set(values.keys))
    #expect(effects.reviewedFields == Set(values.keys))
    #expect(await provider.commands.first?.values == values)
    #expect(await provider.counts == [1, 0, 0])
  }

  private func mutation(_ kind: MutationKind, _ values: TeaQLRecord) -> Mutation {
    Mutation(kind: kind, entity: canonicalEntity, id: kind == .create ? nil : .int(1),
      values: values, expectedVersion: kind == .create ? nil : 1, auditReason: "verify canonical mutation fields")
  }

  private func context(_ effects: CanonicalEffects, _ provider: CanonicalProvider) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "canonical-field-contract", entities: [canonicalEntity],
      checkers: [canonicalEntity.name: effects]))
    return UserContext(runtime: runtime, queryExecutor: provider, mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in effects }, businessClock: effects)
  }
}

private final class CanonicalEffects: @unchecked Sendable, EntityChecker, BusinessClock, MutationPolicy {
  private let lock = NSLock()
  private var calls = [0, 0, 0], checked = Set<String>(), reviewed = Set<String>()
  private let introduce: String?
  init(introduce: String? = nil) { self.introduce = introduce }
  let identity = MutationPolicyIdentity(policyID: "canonical-fields", version: "1", fingerprint: "fixture")
  var counts: [Int] { lock.withLock { calls } }
  var fields: Set<String> { lock.withLock { checked } }
  var reviewedFields: Set<String> { lock.withLock { reviewed } }
  func now() -> Date { lock.withLock { calls[2] += 1 }; return Date(timeIntervalSince1970: 1_792_488_600) }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { calls[0] += 1; checked = Set(mutation.values.keys) }
    if let introduce { mutation.values[introduce] = .string("private-fix-canary") }
    return []
  }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { calls[1] += 1; reviewed = Set(plan.operations.flatMap { $0.changedValues.keys }) }
    return MutationPolicyDecision(verdict: .allow)
  }
}

private actor CanonicalProvider: QueryExecutor, GraphTransactionExecutor {
  private(set) var commands: [Mutation] = []
  private var begins = 0, commits = 0
  var counts: [Int] { [commands.count, begins, commits] }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "canonical-spy") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    commands.append(request.mutation)
    return MutationResult(affectedRows: 1, persistedRecord: request.mutation.values)
  }
  func beginGraphTransaction() async throws { begins += 1 }
  func commitGraphTransaction() async throws { commits += 1 }
  func rollbackGraphTransaction() async throws { }
}
