import Foundation
import Testing
@testable import TeaQLCore

private struct RootUnusedExecutor: QueryExecutor, MutationExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult { throw TeaQLError.execution("unexpected query") }
  func execute(_ request: MutationRequest) async throws -> MutationResult { throw TeaQLError.execution("unexpected mutation") }
}
private final class RootCheckCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var reads = 0
  func record() { lock.withLock { reads += 1 } }
  var count: Int { lock.withLock { reads } }
}
private struct AdmissionTestChecker: EntityChecker {
  let action: Int
  let calls: RootCheckCounter
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    calls.record()
    switch action {
    case 1: mutation.values["domain_root"] = .int(2)
    case 2: mutation.values["domain_root"] = .null
    case 3: mutation.values.removeValue(forKey: "domain_root")
    case 4: throw TeaQLError.execution("customer checker failure")
    default:
      #expect(mutation.values["domain_root"] == .int(1) || mutation.loadedValues["domainRoot"] == .int(1))
    }
    return []
  }
}

@Suite("Model-declared context-root admission")
struct ContextRootAdmissionTests {
  private let root = EntityDescriptor(name: "DomainRoot", table: "root", properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
  private var entity: EntityDescriptor {
    EntityDescriptor(name: "WorkItem", table: "work_item", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "domainRoot", modelName: "domain_root", type: .int, isRelation: true, referencedEntity: "DomainRoot"),
      PropertyDescriptor(name: "name", type: .string)
    ])
  }
  private func runtime(checker: (any EntityChecker)? = nil, managed: Bool = true) throws -> TeaQLRuntime {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "Root tests", entities: [root, entity],
      checkers: checker.map { ["WorkItem": $0] } ?? [:],
      contextRootFields: managed ? ["WorkItem": ["domain_root": "DomainRoot"]] : [:]))
    return runtime
  }
  private func context(root: ContextEntityRef? = ContextEntityRef(entity: "DomainRoot", id: .int(1)),
    checker: (any EntityChecker)? = nil, managed: Bool = true, locale: TeaQLLocale = .en,
    catalog: I18nCatalog = .builtin) throws -> UserContext {
    UserContext(runtime: try runtime(checker: checker, managed: managed), activeRoot: root,
      queryExecutor: RootUnusedExecutor(), mutationExecutor: RootUnusedExecutor(), requestPolicy: RequestPolicy { $0 },
      locale: locale, i18nCatalog: catalog, businessClock: FixedBusinessClock(Date(timeIntervalSince1970: 0)))
  }
  private func mutation(_ kind: MutationKind = .update, original: TeaQLValue? = .int(1), pending: TeaQLValue? = nil) -> Mutation {
    var m = Mutation(kind: kind, entity: entity, id: kind == .create ? nil : .int(7),
      values: kind == .delete || kind == .recover ? [:] : ["name": .string("a business edit")],
      expectedVersion: kind == .create ? nil : (kind == .recover ? -1 : 1), auditReason: "verify managed roots")
    if let original { m.loadedValues["domainRoot"] = original }
    if let pending { m.values["domain_root"] = pending }
    return m
  }
  private func rejection(_ action: () throws -> Void, rule: String) {
    do { try action(); Issue.record("Expected context-root rejection") }
    catch let error as CheckException {
      #expect(error.violations.count == 1)
      if let v = error.violations.first {
        #expect(v.ruleID == rule); #expect(v.entityType == "WorkItem")
        #expect(v.location.modelPath == "domain_root")
        #expect(v.inputValue == nil && v.systemValue == nil)
      }
    } catch { Issue.record("Wrong rejection type: \(error)") }
  }

  @Test(arguments: [MutationKind.update, .delete, .recover])
  func loadedOriginalIsCheckedEvenWhenAbsentFromTheDelta(_ kind: MutationKind) throws {
    let calls = RootCheckCounter(), ctx = try context(root: ContextEntityRef(entity: "DomainRoot", id: .int(2)),
      checker: AdmissionTestChecker(action: 0, calls: calls))
    rejection({ _ = try ctx.preflightMutation(mutation(kind)) }, rule: "context_root_mismatch")
    #expect(calls.count == 0)
  }
  @Test(arguments: [MutationKind.update, .delete, .recover])
  func unknownOriginalIsNotAnImplicitOwnershipGrant(_ kind: MutationKind) throws {
    let ctx = try context()
    rejection({ _ = try ctx.preflightMutation(mutation(kind, original: nil)) }, rule: "context_root_missing")
  }
  @Test(arguments: [TeaQLValue.int(2), .int(-1), .int(0), .uint(UInt64.max), .double(1), .string("1"), .null])
  func explicitConflictingOrMalformedIntentCannotBeRepairedByCustomFix(_ value: TeaQLValue) throws {
    let calls = RootCheckCounter(), ctx = try context(checker: AdmissionTestChecker(action: 0, calls: calls))
    rejection({ _ = try ctx.preflightMutation(mutation(pending: value)) }, rule: "context_root_mismatch")
    #expect(calls.count == 0)
  }
  @Test func aMatchingDeltaCannotHideAnotherLoadedOwner() throws {
    let ctx = try context()
    rejection({ _ = try ctx.preflightMutation(mutation(original: .int(2), pending: .int(1))) }, rule: "context_root_mismatch")
  }
  @Test(arguments: [TeaQLValue.int(1), .uint(1)])
  func matchingSignedAndUnsignedIDsAreEquivalent(_ value: TeaQLValue) throws {
    let ctx = try context(), fixed = try ctx.preflightMutation(mutation(original: value))
    #expect(fixed.values["name"] == .string("a business edit")); #expect(ctx.lastFixEvidence.isEmpty)
  }
  @Test(arguments: [1, 2, 3])
  func finalCreateFixCannotRebindNullOrRemoveTheManagedReference(_ action: Int) throws {
    let calls = RootCheckCounter(), ctx = try context(checker: AdmissionTestChecker(action: action, calls: calls))
    rejection({ _ = try ctx.preflightMutation(mutation(.create, original: nil)) },
      rule: action == 1 ? "context_root_mismatch" : "context_root_missing")
    #expect(calls.count == 1)
  }
  @Test(arguments: [1, 2])
  func finalUpdateFixCannotRebindOrNullTheManagedReference(_ action: Int) throws {
    let calls = RootCheckCounter(), ctx = try context(checker: AdmissionTestChecker(action: action, calls: calls))
    rejection({ _ = try ctx.preflightMutation(mutation()) }, rule: "context_root_mismatch")
    #expect(calls.count == 1)
  }
  @Test(arguments: [TeaQLValue.null, .int(0), .uint(0)])
  func createDefaultPrecedesCustomCheckerAndKeepsContextProvenance(_ empty: TeaQLValue) throws {
    let calls = RootCheckCounter(), ctx = try context(checker: AdmissionTestChecker(action: 0, calls: calls))
    let result = try ctx.preflightMutation(mutation(.create, original: nil, pending: empty))
    #expect(result.values["domain_root"] == .int(1)); #expect(calls.count == 1)
    #expect(ctx.lastFixEvidence == [FixEvidence(entityType: "WorkItem", modelPath: "domain_root", source: .context, sourceLabel: "activeRoot:DomainRoot")])
  }
  @Test func absentCreateDefaultAndRepeatedInvocationProduceOneReceiptEach() throws {
    let ctx = try context()
    for _ in 0..<2 {
      #expect(try ctx.preflightMutation(mutation(.create, original: nil)).values["domain_root"] == .int(1))
      #expect(ctx.lastFixEvidence.count == 1)
    }
  }
  @Test func explicitCreateValueIsNotFalselyAttributedToContext() throws {
    let ctx = try context()
    _ = try ctx.preflightMutation(mutation(.create, original: nil, pending: .int(1)))
    #expect(ctx.lastFixEvidence.isEmpty)
  }
  @Test func throwingCheckerDoesNotLoseActualDefaultProvenance() throws {
    let ctx = try context(checker: AdmissionTestChecker(action: 4, calls: RootCheckCounter()))
    do { _ = try ctx.preflightMutation(mutation(.create, original: nil)); Issue.record("Expected customer failure") }
    catch is TeaQLError { #expect(ctx.lastFixEvidence.count == 1) }
  }
  @Test(arguments: [Optional<ContextEntityRef>.none, ContextEntityRef(entity: "Other", id: .int(1)),
    ContextEntityRef(entity: "DomainRoot", id: .int(0)), ContextEntityRef(entity: "DomainRoot", id: .string("1"))])
  func missingOrInvalidActiveRootRejectsBeforeCustomChecker(_ root: ContextEntityRef?) throws {
    let calls = RootCheckCounter(), ctx = try context(root: root, checker: AdmissionTestChecker(action: 0, calls: calls))
    rejection({ _ = try ctx.preflightMutation(mutation()) }, rule: "context_root_missing")
    #expect(calls.count == 0)
  }
  @Test func ordinaryReferenceDoesNotAcquireAHighLevelPolicy() throws {
    let ctx = try context(root: nil, managed: false)
    #expect(try ctx.preflightMutation(mutation(original: .int(2))).values["name"] == .string("a business edit"))
  }
  @Test func checkerReplacementCannotEraseInstalledMetadata() throws {
    var rt = try runtime()
    try rt.install(RuntimeModule(name: "custom checker", entities: [entity]))
    #expect(rt.contextRootFields(named: "WorkItem") == ["domain_root": "DomainRoot"])
  }
  @Test(arguments: ["domainRoot", "unknown", "id", "name"])
  func malformedMetadataIsRejectedBeforeInstallation(_ field: String) throws {
    var rt = TeaQLRuntime()
    #expect(throws: TeaQLError.self) {
      try rt.install(RuntimeModule(name: "invalid metadata", entities: [root, entity], contextRootFields: ["WorkItem": [field: "DomainRoot"]]))
    }
    #expect(rt.entities.isEmpty)
  }
  @Test func wrongTargetAndConflictingMetadataAreRejected() throws {
    var rt = try runtime()
    #expect(throws: TeaQLError.self) {
      try rt.install(RuntimeModule(name: "wrong target", entities: [entity], contextRootFields: ["WorkItem": ["domain_root": "Other"]]))
    }
    #expect(rt.contextRootFields(named: "WorkItem") == ["domain_root": "DomainRoot"])
  }
  @Test(arguments: [TeaQLLocale.en, .zhCN, .de], [JsonFieldNamingProfile.camelCase, .snakeCase, .pascalCase])
  func diagnosticsAreLocalizedRebasedAndValueFree(_ locale: TeaQLLocale, _ profile: JsonFieldNamingProfile) throws {
    let ctx = try context(root: ContextEntityRef(entity: "DomainRoot", id: .int(9123456789)), locale: locale)
    do { _ = try ctx.preflightMutation(mutation()); Issue.record("Expected root mismatch") }
    catch let error as CheckException {
      let prefix = ObjectLocation.property("child_list").index(2)
      let v = ctx.translateCheckResults(error.violations.map { $0.prefixed(by: prefix) })[0]
      let wire = v.wire(profile: profile)
      #expect(wire.instancePath == prefix.property("domain_root").instancePath(profile: profile))
      #expect(wire.inputValue == nil && wire.systemValue == nil)
      #expect(wire.message != "checker.context_root_mismatch")
      #expect(!String(describing: wire).contains("9123456789"))
    }
  }
}
