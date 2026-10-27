import Foundation
import Testing
@testable import TeaQLCore

@Suite("Checked version lifecycle admission")
struct VersionLifecycleAdmissionTests {
  private let entity = EntityDescriptor(name: "VersionProbe", table: "version_probe", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])

  private func mutation(_ kind: MutationKind, _ version: Int64?) -> Mutation {
    Mutation(kind: kind, entity: entity, id: .int(1), values: ["name": .string("pending")],
      expectedVersion: version, auditReason: "validate the optimistic version before side effects")
  }

  @Test(arguments: [Int64.min, -2, -1, 0, Int64.max])
  func invalidUpdateDoesNotReachTheCheckerPolicyOrProvider(_ version: Int64) async throws {
    try await assertRejectedBeforeEffects(mutation(.update, version),
      code: version == Int64.max ? "VERSION_EXHAUSTED" : "INVALID_VERSION_STATE")
  }

  @Test(arguments: [Int64.min, -2, -1, 0])
  func invalidDeleteDoesNotBecomeRecovery(_ version: Int64) async throws {
    try await assertRejectedBeforeEffects(mutation(.delete, version), code: "INVALID_VERSION_STATE")
  }

  @Test(arguments: [Int64.min, Int64.min + 1, 0, 1, Int64.max])
  func invalidRecoveryDoesNotReachCustomerCode(_ version: Int64) async throws {
    try await assertRejectedBeforeEffects(mutation(.recover, version),
      code: version < 0 ? "VERSION_EXHAUSTED" : "INVALID_VERSION_STATE")
  }

  @Test func missingExpectedVersionIsRejectedBeforeTheChecker() async throws {
    for kind in [MutationKind.update, .delete, .recover] {
      try await assertRejectedBeforeEffects(mutation(kind, nil), code: "INVALID_VERSION_STATE")
    }
  }

  @Test func completeBatchIsAdmittedBeforeItsFirstFix() async throws {
    let probe = VersionAdmissionProbe(), checker = VersionAdmissionChecker()
    let context = try context(probe, checker: checker)
    let request = try MutationBatchRequest(mutations: [mutation(.update, 1), mutation(.update, .max)],
      comment: "reject the complete batch before fixing its first item")
    do { _ = try await context.execute(request); Issue.record("invalid late version executed") }
    catch { #expect(String(describing: error).contains("VERSION_EXHAUSTED")) }
    #expect(checker.count == 0)
    #expect(checker.policyCount == 0)
    #expect(await probe.writes == 0)
    #expect(await probe.begins == 0)
    #expect(await probe.audits == 0)
  }

  @Test func requestAndMutationAdmissionAgree() throws {
    for kind in [MutationKind.update, .delete, .recover] {
      let invalid = mutation(kind, 0)
      do { _ = try invalid.validatedForExecution(); Issue.record("mutation admission accepted zero") }
      catch { #expect(String(describing: error).contains("INVALID_VERSION_STATE")) }
      do { _ = try MutationRequest(mutation: invalid); Issue.record("request admission accepted zero") }
      catch { #expect(String(describing: error).contains("INVALID_VERSION_STATE")) }
    }
  }

  @Test func legalBoundaryVersionsReachTheProviderUnchanged() async throws {
    for (kind, version) in [(MutationKind.update, Int64.max - 1), (.delete, Int64.max),
      (.recover, Int64.min + 2)] {
      let probe = VersionAdmissionProbe(), checker = VersionAdmissionChecker()
      let context = try context(probe, checker: checker)
      _ = try await context.execute(mutation(kind, version))
      #expect(checker.count == 1)
      #expect(checker.policyCount == 1)
      #expect(await probe.writes == 1)
      #expect(await probe.lastVersion == version)
    }
  }

  @Test func checkedArithmeticCoversEveryRepresentableBoundary() throws {
    for (kind, old, next) in [(MutationKind.create, Int64(0), Int64(1)), (.update, 1, 2),
      (.update, .max - 1, .max), (.delete, 1, -2), (.delete, .max, .min),
      (.recover, -2, 3), (.recover, .min + 2, .max)] {
      let result = try MutationVersion.next(for: kind, original: old)
      #expect(result == next)
    }
  }

  @Test func errorsAreTypedAndTheirDescriptionDoesNotExposeTheVersion() throws {
    do { _ = try MutationVersion.next(for: .recover, original: .min); Issue.record("exhausted version accepted") }
    catch let error as MutationVersionError {
      #expect(error.code == .exhausted)
      #expect(error.operation == .recover)
      #expect(error.originalVersion == Int64.min)
      #expect(error.description == "VERSION_EXHAUSTED: invalid recover version transition")
      #expect(!error.description.contains(String(Int64.min)))
    }
  }

  @Test func versionlessUpdateRemainsVersionless() throws {
    let plain = EntityDescriptor(name: "Plain", table: "plain", properties: [PropertyDescriptor(name: "id", type: .int, isID: true)])
    let request = try MutationRequest(mutation: Mutation(kind: .update, entity: plain, id: .int(1),
      values: [:], auditReason: "preserve the versionless contract"))
    #expect(request.mutation.expectedVersion == nil)
  }

  private func assertRejectedBeforeEffects(_ command: Mutation, code: String) async throws {
    let probe = VersionAdmissionProbe(), checker = VersionAdmissionChecker()
    let context = try context(probe, checker: checker)
    let ledger = EntityRoot(), key = EntityKey(entity: entity.name, id: .int(1))
    ledger.set(key, field: "name", value: .string("pending"))
    do { _ = try await context.execute(command, ledgerRoot: ledger, ledgerKey: key); Issue.record("invalid version reached execution") }
    catch { #expect(String(describing: error).contains(code)) }
    #expect(checker.count == 0)
    #expect(checker.policyCount == 0)
    #expect(ledger.change(key)["name"] == .string("pending"))
    #expect(await probe.writes == 0)
    #expect(await probe.begins == 0)
    #expect(await probe.audits == 0)
  }

  private func context(_ probe: VersionAdmissionProbe, checker: VersionAdmissionChecker) throws -> UserContext {
    var runtime = TeaQLRuntime()
    try runtime.install(RuntimeModule(name: "version admission", entities: [entity], checkers: [entity.name: checker]))
    return UserContext(runtime: runtime, queryExecutor: probe, mutationExecutor: probe,
      requestPolicy: RequestPolicy { $0 }, auditSink: probe,
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in checker })
  }
}

private final class VersionAdmissionChecker: @unchecked Sendable, EntityChecker, MutationPolicy {
  private let lock = NSLock()
  private var calls = 0
  private var reviews = 0
  var count: Int { lock.withLock { calls } }
  var policyCount: Int { lock.withLock { reviews } }
  let identity = MutationPolicyIdentity(policyID: "version-admission", version: "1", fingerprint: "fixture")
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    lock.withLock { reviews += 1 }; return MutationPolicyDecision(verdict: .allow)
  }
  func checkAndFix(context: UserContext, mutation: inout Mutation, now: Date) throws -> [CheckResult] {
    lock.withLock { calls += 1 }; return []
  }
}

private actor VersionAdmissionProbe: QueryExecutor, GraphTransactionExecutor, AuditSink {
  private(set) var begins = 0, writes = 0, audits = 0
  private(set) var lastVersion: Int64?
  func beginGraphTransaction() async throws { begins += 1 }
  func commitGraphTransaction() async throws {}
  func rollbackGraphTransaction() async throws {}
  func record(_ event: AuditEvent) { audits += 1 }
  func execute(_ request: QueryRequest) async throws -> QueryResult { QueryResult(records: [], backend: "version-spy") }
  func execute(_ request: MutationRequest) async throws -> MutationResult {
    writes += 1; lastVersion = request.mutation.expectedVersion
    return MutationResult(affectedRows: 1, persistedRecord: ["id": .int(1), "version": .int(1)])
  }
}
