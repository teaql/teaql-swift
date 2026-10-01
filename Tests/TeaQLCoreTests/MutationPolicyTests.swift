import Foundation
import Testing
@testable import TeaQLCore

@Suite("Mutation Policy")
struct MutationPolicyTests {
  private let order = EntityDescriptor(
    name: "Order", table: "order_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "name", type: .string),
    ])
  private let line = EntityDescriptor(
    name: "OrderLine", table: "order_line_data",
    properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "order", type: .int),
    ])

  @Test func wholeGraphIsReviewedOnceAndGovernanceReachesEveryAuditEvent() async throws {
    let provider = PolicyMutationRecorder()
    let audit = PolicyAuditRecorder()
    let observed = LockedPolicyPlans()
    let policy = ClosureMutationPolicy(identity: identity) { plan in
      observed.append(plan)
      return MutationPolicyDecision(verdict: .allow)
    }
    let context = approvedContext(provider: provider, policy: policy, audit: audit)
    let orderMutation = mutation(.create, order, values: ["name": .string("DRAFT")])
    let lineMutation = mutation(.create, line, values: ["order": .null])
    let orderKey = EntityKey(entity: "Order", id: .int(-1))
    let lineKey = EntityKey(entity: "OrderLine", id: .int(-2))

    try await context.executeGraphSave(comment: "verify graph save request") {
      _ = try context.preflightMutation(orderMutation, ledgerKey: orderKey)
      _ = try context.preflightMutation(lineMutation, ledgerKey: lineKey)
      _ = try await context.execute(orderMutation, ledgerRoot: nil, ledgerKey: orderKey)
      _ = try await context.execute(lineMutation, ledgerRoot: nil, ledgerKey: lineKey)
    }

    #expect(observed.values.count == 1)
    #expect(observed.values[0].operations.count == 2)
    #expect(observed.values[0].operations[0].changedValues["name"] == .string("DRAFT"))
    #expect(await provider.persistedMutations == 2)
    #expect(await provider.commitCount == 1)
    let events = await audit.events
    #expect(events.count == 2)
    #expect(events.allSatisfy { $0.mutationGovernance?.approvalStatus == .approved })
    #expect(events[0].mutationGovernance?.executionID == events[1].mutationGovernance?.executionID)
  }

  @Test func denialPrecedesProviderAndIncompletePlanRollsBack() async throws {
    let deniedProvider = PolicyMutationRecorder()
    let denying = ClosureMutationPolicy(identity: identity) { _ in
      MutationPolicyDecision(verdict: .deny, code: "ORDER_DENIED", message: "closed")
    }
    let deniedContext = approvedContext(provider: deniedProvider, policy: denying)
    let deniedMutation = mutation(.create, order, values: ["name": .string("denied")])
    let deniedKey = EntityKey(entity: "Order", id: .int(-1))
    await #expect(throws: MutationPolicyError.denied(code: "ORDER_DENIED", message: "closed")) {
      try await deniedContext.executeGraphSave(comment: "verify graph save request") {
        _ = try deniedContext.preflightMutation(deniedMutation, ledgerKey: deniedKey)
        _ = try await deniedContext.execute(deniedMutation, ledgerRoot: nil, ledgerKey: deniedKey)
      }
    }
    #expect(await deniedProvider.providerMutations == 0)
    #expect(await deniedProvider.rollbackCount == 1)

    let incompleteProvider = PolicyMutationRecorder()
    let allowing = ClosureMutationPolicy(identity: identity) { _ in
      MutationPolicyDecision(verdict: .allow)
    }
    let incomplete = approvedContext(provider: incompleteProvider, policy: allowing)
    let first = mutation(.create, order, values: ["name": .string("first")])
    let second = mutation(.create, line, values: ["order": .null])
    let firstKey = EntityKey(entity: "Order", id: .int(-1))
    let secondKey = EntityKey(entity: "OrderLine", id: .int(-2))
    await #expect(throws: MutationPolicyError.incompleteReviewedPlan) {
      try await incomplete.executeGraphSave(comment: "verify graph save request") {
        _ = try incomplete.preflightMutation(first, ledgerKey: firstKey)
        _ = try incomplete.preflightMutation(second, ledgerKey: secondKey)
        _ = try await incomplete.execute(first, ledgerRoot: nil, ledgerKey: firstKey)
      }
    }
    #expect(await incompleteProvider.providerMutations == 1)
    #expect(await incompleteProvider.persistedMutations == 0)
    #expect(await incompleteProvider.rollbackCount == 1)
  }

  @Test func customerPolicyRequiresCompleteGraphPreflight() async throws {
    let provider = PolicyMutationRecorder()
    let policy = ClosureMutationPolicy(identity: identity) { _ in
      MutationPolicyDecision(verdict: .allow)
    }
    let context = approvedContext(provider: provider, policy: policy)
    let command = mutation(.create, order, values: ["name": .string("unreviewed")])

    await #expect(throws: MutationPolicyError.missingGraphPreflight) {
      try await context.executeGraphSave(comment: "verify graph save request") {
        _ = try await context.execute(command)
      }
    }
    #expect(await provider.providerMutations == 0)
    #expect(await provider.persistedMutations == 0)
    #expect(await provider.rollbackCount == 1)
  }

  @Test func warningsAreStableDeduplicatedAndSinkFailureDoesNotBlockPersistence() async throws {
    let provider = PolicyMutationRecorder()
    let warnings = LockedPolicyWarnings(throwFirst: true)
    let context = UserContext(
      queryExecutor: EmptyPolicyQueryExecutor(), mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 },
      mutationGovernanceSink: DelegatingMutationGovernanceSink {
        _, warning in try warnings.accept(warning)
      })
    let plan = MutationPlan(
      executionID: "warning-1", requestKey: "Order.saveGraph", rootEntityType: "Order",
      auditReason: "review warning fixture",
      operations: [MutationPolicyOperation(
        kind: .update, entity: "Order", entityID: .int(1), originalVersion: 1,
        changedValues: ["name": .string("updated")])])
    let first = try context.reviewMutationPlan(plan)
    _ = try context.reviewMutationPlan(MutationPlan(
      executionID: "warning-2", requestKey: plan.requestKey,
      rootEntityType: plan.rootEntityType, auditReason: "review warning fixture", operations: plan.operations))
    #expect(first.warningCodes == [MutationPolicyWarningCode.missingPolicy])
    #expect(warnings.values.map(\.firstOccurrence) == [true, false])

    _ = try await context.execute(mutation(.create, order, values: ["name": .string("allowed")]))
    #expect(await provider.persistedMutations == 1)
  }

  @Test func approvalsRequireExactIdentityAndNonEpochTime() throws {
    let policy = ClosureMutationPolicy(identity: identity) { _ in
      MutationPolicyDecision(verdict: .allow)
    }
    let warnings = LockedPolicyWarnings()
    let context = UserContext(
      queryExecutor: EmptyPolicyQueryExecutor(), mutationExecutor: PolicyMutationRecorder(),
      requestPolicy: RequestPolicy { $0 },
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy },
      mutationPolicyApprovalProvider: DelegatingMutationPolicyApprovalProvider { requested in
        MutationPolicyApproval(
          policy: MutationPolicyIdentity(
            policyID: requested.policyID, version: requested.version,
            fingerprint: "sha256:different"),
          approvedBy: "security-owner", approvedAt: Date())
      },
      mutationGovernanceSink: DelegatingMutationGovernanceSink {
        _, warning in try warnings.accept(warning)
      })
    let snapshot = try context.reviewMutationPlan(MutationPlan(
      executionID: "approval", requestKey: "Order.saveGraph", rootEntityType: "Order",
      auditReason: "review approval fixture",
      operations: [MutationPolicyOperation(
        kind: .create, entity: "Order", changedValues: ["name": .string("A")])]))
    #expect(snapshot.approvalStatus == .missing)
    #expect(snapshot.warningCodes == [MutationPolicyWarningCode.missingApproval])
  }

  @Test func ledgerIdentitySurvivesParentIDAssignmentDuringExecution() async throws {
    let provider = PolicyMutationRecorder()
    let policy = ClosureMutationPolicy(identity: identity) { plan in
      #expect(plan.operations[1].changedValues["order"] == .null)
      return MutationPolicyDecision(verdict: .allow)
    }
    let context = approvedContext(provider: provider, policy: policy)
    let parent = mutation(.create, order, values: ["name": .string("parent")])
    let childBefore = mutation(.create, line, values: ["order": .null])
    let childAfter = mutation(.create, line, values: ["order": .int(1)])
    let parentKey = EntityKey(entity: "Order", id: .int(-1))
    let childKey = EntityKey(entity: "OrderLine", id: .int(-2))
    try await context.executeGraphSave(comment: "verify graph save request") {
      _ = try context.preflightMutation(parent, ledgerKey: parentKey)
      _ = try context.preflightMutation(childBefore, ledgerKey: childKey)
      _ = try await context.execute(parent, ledgerRoot: nil, ledgerKey: parentKey)
      _ = try await context.execute(childAfter, ledgerRoot: nil, ledgerKey: childKey)
    }
    #expect(await provider.persistedMutations == 2)
  }

  private var identity: MutationPolicyIdentity {
    MutationPolicyIdentity(
      policyID: "orders", version: "1", fingerprint: "sha256:orders-v1")
  }

  private func mutation(
    _ kind: MutationKind, _ entity: EntityDescriptor, values: TeaQLRecord
  ) -> Mutation {
    Mutation(kind: kind, entity: entity, values: values, auditReason: "test graph")
  }

  private func approvedContext(
    provider: PolicyMutationRecorder, policy: any MutationPolicy,
    audit: (any AuditSink)? = nil
  ) -> UserContext {
    UserContext(
      queryExecutor: EmptyPolicyQueryExecutor(), mutationExecutor: provider,
      requestPolicy: RequestPolicy { $0 }, auditSink: audit,
      mutationPolicyRegistry: DelegatingMutationPolicyRegistry { _ in policy },
      mutationPolicyApprovalProvider: DelegatingMutationPolicyApprovalProvider { requested in
        MutationPolicyApproval(
          policy: requested, approvedBy: "security-owner", approvedAt: Date())
      })
  }
}

private struct EmptyPolicyQueryExecutor: QueryExecutor {
  func execute(_ request: QueryRequest) async throws -> QueryResult {
    QueryResult(records: [], backend: "test")
  }
}

private actor PolicyMutationRecorder: GraphTransactionExecutor {
  private(set) var providerMutations = 0
  private(set) var persistedMutations = 0
  private(set) var commitCount = 0
  private(set) var rollbackCount = 0
  private var pendingMutations = 0
  private var transactionActive = false

  func beginGraphTransaction() async throws {
    pendingMutations = 0
    transactionActive = true
  }
  func commitGraphTransaction() async throws {
    persistedMutations += pendingMutations
    pendingMutations = 0
    transactionActive = false
    commitCount += 1
  }
  func rollbackGraphTransaction() async throws {
    pendingMutations = 0
    transactionActive = false
    rollbackCount += 1
  }
  func execute(_ request: MutationRequest) async throws -> MutationResult { let mutation = request.mutation;
    providerMutations += 1
    if transactionActive { pendingMutations += 1 }
    else { persistedMutations += 1 }
    var row = mutation.values
    row["id"] = mutation.id ?? .int(Int64(providerMutations))
    row["version"] = .int((mutation.expectedVersion ?? 0) + 1)
    return MutationResult(affectedRows: 1, persistedRecord: row)
  }
}

private actor PolicyAuditRecorder: AuditSink {
  private(set) var events: [AuditEvent] = []
  func record(_ event: AuditEvent) async throws { events.append(event) }
}

private final class ClosureMutationPolicy: MutationPolicy, @unchecked Sendable {
  let identity: MutationPolicyIdentity
  private let reviewer: @Sendable (MutationPlan) throws -> MutationPolicyDecision
  init(
    identity: MutationPolicyIdentity,
    reviewer: @escaping @Sendable (MutationPlan) throws -> MutationPolicyDecision
  ) {
    self.identity = identity
    self.reviewer = reviewer
  }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision {
    try reviewer(plan)
  }
}

private final class LockedPolicyPlans: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MutationPlan] = []
  func append(_ plan: MutationPlan) { lock.withLock { storage.append(plan) } }
  var values: [MutationPlan] { lock.withLock { storage } }
}

private final class LockedPolicyWarnings: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MutationGovernanceWarning] = []
  private let throwFirst: Bool
  init(throwFirst: Bool = false) { self.throwFirst = throwFirst }
  func accept(_ warning: MutationGovernanceWarning) throws {
    let shouldThrow = lock.withLock { () -> Bool in
      storage.append(warning)
      return throwFirst && storage.count == 1
    }
    if shouldThrow { throw TeaQLError.execution("warning sink unavailable") }
  }
  var values: [MutationGovernanceWarning] { lock.withLock { storage } }
}
