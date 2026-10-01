import Foundation

public enum MutationPolicyWarningCode {
  public static let missingPolicy = "MUTATION-POLICY-001"
  public static let missingApproval = "MUTATION-POLICY-002"
}

public struct MutationPolicyIdentity: Sendable, Hashable, Codable {
  public let policyID: String
  public let version: String
  public let fingerprint: String

  public init(policyID: String, version: String, fingerprint: String) {
    self.policyID = policyID
    self.version = version
    self.fingerprint = fingerprint
  }

  package func validated() throws -> Self {
    guard !policyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw MutationPolicyError.invalidPolicyIdentity }
    return self
  }
}

public struct MutationPolicyOperation: Sendable, Codable, Equatable {
  public let kind: MutationKind
  public let entity: String
  public let entityID: TeaQLValue?
  public let originalVersion: Int64?
  public let changedValues: TeaQLRecord

  public init(
    kind: MutationKind, entity: String, entityID: TeaQLValue? = nil,
    originalVersion: Int64? = nil, changedValues: TeaQLRecord
  ) {
    self.kind = kind
    self.entity = entity
    self.entityID = entityID
    self.originalVersion = originalVersion
    self.changedValues = changedValues
  }
}

public struct MutationPlan: Sendable, Codable, Equatable {
  public let executionID: String
  public let requestKey: String
  public let rootEntityType: String
  public let auditReason: String?
  public let operations: [MutationPolicyOperation]

  public init(
    executionID: String, requestKey: String, rootEntityType: String,
    auditReason: String? = nil, operations: [MutationPolicyOperation]
  ) {
    self.executionID = executionID
    self.requestKey = requestKey
    self.rootEntityType = rootEntityType
    self.auditReason = auditReason
    self.operations = operations
  }

  package func validated() throws -> Self {
    guard !executionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !requestKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !rootEntityType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !operations.isEmpty,
          operations.allSatisfy({ !$0.entity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw MutationPolicyError.invalidPlan }
    return self
  }
}

public enum MutationPolicyVerdict: String, Sendable, Codable { case allow, deny }

public struct MutationPolicyDecision: Sendable, Codable, Equatable {
  public let verdict: MutationPolicyVerdict
  public let code: String?
  public let message: String?
  public let fieldPaths: [String]

  public init(
    verdict: MutationPolicyVerdict, code: String? = nil,
    message: String? = nil, fieldPaths: [String] = []
  ) {
    self.verdict = verdict
    self.code = code
    self.message = message
    self.fieldPaths = fieldPaths
  }
}

public protocol MutationPolicy: Sendable {
  var identity: MutationPolicyIdentity { get }
  func review(context: UserContext, plan: MutationPlan) throws -> MutationPolicyDecision
}

public protocol MutationPolicyRegistry: Sendable {
  func resolve(requestKey: String) -> (any MutationPolicy)?
}

public struct DelegatingMutationPolicyRegistry: MutationPolicyRegistry {
  private let resolver: @Sendable (String) -> (any MutationPolicy)?
  public init(_ resolver: @escaping @Sendable (String) -> (any MutationPolicy)?) {
    self.resolver = resolver
  }
  public func resolve(requestKey: String) -> (any MutationPolicy)? { resolver(requestKey) }
}

public struct MutationPolicyApproval: Sendable, Codable, Equatable {
  public let policy: MutationPolicyIdentity
  public let approvedBy: String
  public let approvedAt: Date

  public init(policy: MutationPolicyIdentity, approvedBy: String, approvedAt: Date) {
    self.policy = policy
    self.approvedBy = approvedBy
    self.approvedAt = approvedAt
  }
}

public protocol MutationPolicyApprovalProvider: Sendable {
  func findApproval(identity: MutationPolicyIdentity) -> MutationPolicyApproval?
}

public struct DelegatingMutationPolicyApprovalProvider: MutationPolicyApprovalProvider {
  private let finder: @Sendable (MutationPolicyIdentity) -> MutationPolicyApproval?
  public init(_ finder: @escaping @Sendable (MutationPolicyIdentity) -> MutationPolicyApproval?) {
    self.finder = finder
  }
  public func findApproval(identity: MutationPolicyIdentity) -> MutationPolicyApproval? {
    finder(identity)
  }
}

public enum MutationPolicySource: String, Sendable, Codable { case generatedDefault, customer }
public enum MutationPolicyApprovalStatus: String, Sendable, Codable {
  case notApplicable, missing, approved
}

public struct MutationPolicyOperationSummary: Sendable, Codable, Equatable {
  public let kind: MutationKind
  public let entity: String
  public let entityID: TeaQLValue?
  public let changedFields: [String]
}

public struct MutationGovernanceSnapshot: Sendable, Codable, Equatable {
  public let executionID: String
  public let requestKey: String
  public let source: MutationPolicySource
  public let policy: MutationPolicyIdentity?
  public let approvalStatus: MutationPolicyApprovalStatus
  public let warningCodes: [String]
  public let operations: [MutationPolicyOperationSummary]
}

public struct MutationGovernanceWarning: Sendable, Equatable {
  public let snapshot: MutationGovernanceSnapshot
  public let warningCode: String
  public let firstOccurrence: Bool
}

public protocol MutationGovernanceSink: Sendable {
  func onWarning(context: UserContext, warning: MutationGovernanceWarning) throws
}

public struct DelegatingMutationGovernanceSink: MutationGovernanceSink {
  private let consumer: @Sendable (UserContext, MutationGovernanceWarning) throws -> Void
  public init(
    _ consumer: @escaping @Sendable (UserContext, MutationGovernanceWarning) throws -> Void
  ) { self.consumer = consumer }
  public func onWarning(context: UserContext, warning: MutationGovernanceWarning) throws {
    try consumer(context, warning)
  }
}

public enum MutationPolicyError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidPlan
  case invalidPolicyIdentity
  case denied(code: String, message: String)
  case graphAlreadyActive
  case preflightAfterReview
  case missingGraphPreflight
  case operationOutsideReviewedPlan
  case incompleteReviewedPlan

  public var description: String {
    switch self {
    case .invalidPlan: "Mutation Policy plan is invalid"
    case .invalidPolicyIdentity: "Mutation Policy identity is invalid"
    case .denied(let code, let message): "[MUTATION POLICY DENIED] \(code): \(message)"
    case .graphAlreadyActive: "Mutation Policy graph is already active"
    case .preflightAfterReview: "Mutation preflight cannot change after policy review"
    case .missingGraphPreflight:
      "Customer Mutation Policy requires complete graph preflight before provider mutation"
    case .operationOutsideReviewedPlan: "Provider mutation is not present in the reviewed graph plan"
    case .incompleteReviewedPlan: "Reviewed mutation plan contains operations that were not executed"
    }
  }
}

private struct ConsoleMutationGovernanceSink: MutationGovernanceSink {
  func onWarning(context: UserContext, warning: MutationGovernanceWarning) throws {
    guard warning.firstOccurrence else { return }
    print(
      "TeaQL mutation policy warning code=\(warning.warningCode) "
        + "requestKey=\(warning.snapshot.requestKey) source=\(warning.snapshot.source.rawValue) "
        + "approval=\(warning.snapshot.approvalStatus.rawValue)")
  }
}

private enum MutationMatchKey: Hashable {
  case ledger(EntityKey)
  case structural(String)
}

package final class MutationPolicyCoordinator: @unchecked Sendable {
  private let registry: (any MutationPolicyRegistry)?
  private let approvalProvider: (any MutationPolicyApprovalProvider)?
  private let warningSink: any MutationGovernanceSink
  private let stateLock = NSRecursiveLock()
  private let warningLock = NSLock()
  private var emittedWarnings: Set<String> = []
  private var graphActive = false
  private var graphReviewed = false
  private var preflight: [(MutationPolicyOperation, MutationMatchKey)] = []
  private var rootEntity: String?
  private var auditReason: String?
  private var remaining: [MutationMatchKey: Int] = [:]
  private var graphSnapshot: MutationGovernanceSnapshot?
  private var retainedSnapshot: MutationGovernanceSnapshot?

  package init(
    registry: (any MutationPolicyRegistry)?,
    approvalProvider: (any MutationPolicyApprovalProvider)?,
    warningSink: (any MutationGovernanceSink)?
  ) {
    self.registry = registry
    self.approvalProvider = approvalProvider
    self.warningSink = warningSink ?? ConsoleMutationGovernanceSink()
  }

  package func beginGraph(auditReason: String) throws {
    stateLock.lock(); defer { stateLock.unlock() }
    guard !graphActive else { throw MutationPolicyError.graphAlreadyActive }
    graphActive = true
    graphReviewed = false
    preflight = []
    rootEntity = nil
    self.auditReason = auditReason
    remaining = [:]
    graphSnapshot = nil
  }

  package func endGraph() {
    stateLock.lock(); defer { stateLock.unlock() }
    graphActive = false
    graphReviewed = false
    preflight = []
    rootEntity = nil
    auditReason = nil
    remaining = [:]
    graphSnapshot = nil
  }

  package func recordPreflight(_ mutation: Mutation, ledgerKey: EntityKey?) throws {
    stateLock.lock(); defer { stateLock.unlock() }
    guard graphActive else { return }
    guard !graphReviewed else { throw MutationPolicyError.preflightAfterReview }
    let operation = operation(from: mutation)
    rootEntity = rootEntity ?? operation.entity
    auditReason = auditReason ?? mutation.auditReason
    preflight.append((operation, matchKey(mutation: mutation, ledgerKey: ledgerKey)))
  }

  package func enter(
    context: UserContext, mutation: Mutation, ledgerKey: EntityKey?
  ) throws -> MutationGovernanceSnapshot {
    stateLock.lock(); defer { stateLock.unlock() }
    let operation = operation(from: mutation)
    guard graphActive else {
      return try review(context: context, plan: makePlan(
        root: operation.entity, auditReason: mutation.auditReason, operations: [operation]))
    }
    if !graphReviewed {
      if registry != nil && preflight.isEmpty { throw MutationPolicyError.missingGraphPreflight }
      if registry == nil && preflight.isEmpty {
        return try review(context: context, plan: makePlan(
          root: operation.entity, auditReason: mutation.auditReason, operations: [operation]))
      }
      let operations = preflight.isEmpty ? [operation] : preflight.map(\.0)
      let snapshot = try review(context: context, plan: makePlan(
        root: rootEntity ?? operation.entity,
        auditReason: auditReason ?? mutation.auditReason,
        operations: operations))
      graphSnapshot = snapshot
      remaining = [:]
      let keys = preflight.isEmpty
        ? [matchKey(mutation: mutation, ledgerKey: ledgerKey)] : preflight.map(\.1)
      for key in keys { remaining[key, default: 0] += 1 }
      graphReviewed = true
    }
    let key = matchKey(mutation: mutation, ledgerKey: ledgerKey)
    guard let count = remaining[key], count > 0
    else { throw MutationPolicyError.operationOutsideReviewedPlan }
    if count == 1 { remaining.removeValue(forKey: key) }
    else { remaining[key] = count - 1 }
    return graphSnapshot!
  }

  package func ensureGraphComplete() throws {
    stateLock.lock(); defer { stateLock.unlock() }
    if graphReviewed && !remaining.isEmpty { throw MutationPolicyError.incompleteReviewedPlan }
  }

  package func review(
    context: UserContext, plan input: MutationPlan
  ) throws -> MutationGovernanceSnapshot {
    let plan = try input.validated()
    let policy = registry?.resolve(requestKey: plan.requestKey)
    let source: MutationPolicySource
    let identity: MutationPolicyIdentity?
    let approvalStatus: MutationPolicyApprovalStatus
    let warningCodes: [String]
    if let policy {
      let validatedIdentity = try policy.identity.validated()
      let decision = try policy.review(context: context, plan: plan)
      if decision.verdict == .deny {
        throw MutationPolicyError.denied(
          code: nonBlank(decision.code) ?? "MUTATION-POLICY-DENIED",
          message: nonBlank(decision.message) ?? "mutation rejected")
      }
      source = .customer
      identity = validatedIdentity
      let approval = approvalProvider?.findApproval(identity: validatedIdentity)
      approvalStatus = valid(approval: approval, identity: validatedIdentity) ? .approved : .missing
      warningCodes = approvalStatus == .approved
        ? [] : [MutationPolicyWarningCode.missingApproval]
    } else {
      source = .generatedDefault
      identity = nil
      approvalStatus = .notApplicable
      warningCodes = [MutationPolicyWarningCode.missingPolicy]
    }
    let snapshot = MutationGovernanceSnapshot(
      executionID: plan.executionID,
      requestKey: plan.requestKey,
      source: source,
      policy: identity,
      approvalStatus: approvalStatus,
      warningCodes: warningCodes,
      operations: plan.operations.map {
        MutationPolicyOperationSummary(
          kind: $0.kind, entity: $0.entity, entityID: $0.entityID,
          changedFields: $0.changedValues.keys.sorted())
      })
    stateLock.lock(); retainedSnapshot = snapshot; stateLock.unlock()
    for code in warningCodes { emitWarning(context: context, snapshot: snapshot, code: code) }
    return snapshot
  }

  package var lastSnapshot: MutationGovernanceSnapshot? {
    stateLock.lock(); defer { stateLock.unlock() }; return retainedSnapshot
  }

  private func makePlan(
    root: String, auditReason: String?, operations: [MutationPolicyOperation]
  ) -> MutationPlan {
    MutationPlan(
      executionID: UUID().uuidString,
      requestKey: "\(root).saveGraph",
      rootEntityType: root,
      auditReason: auditReason,
      operations: operations)
  }

  private func operation(from mutation: Mutation) -> MutationPolicyOperation {
    MutationPolicyOperation(
      kind: mutation.kind,
      entity: mutation.entity.name,
      entityID: mutation.id ?? mutation.values[mutation.entity.idProperty?.name ?? "id"],
      originalVersion: mutation.expectedVersion,
      changedValues: mutation.values)
  }

  private func matchKey(mutation: Mutation, ledgerKey: EntityKey?) -> MutationMatchKey {
    if let ledgerKey { return .ledger(ledgerKey) }
    return .structural(canonical(operation(from: mutation)))
  }

  private func canonical(_ operation: MutationPolicyOperation) -> String {
    let data = (try? JSONEncoder.sorted.encode(operation)) ?? Data()
    return data.base64EncodedString()
  }

  private func valid(
    approval: MutationPolicyApproval?, identity: MutationPolicyIdentity
  ) -> Bool {
    guard let approval,
          approval.policy == identity,
          nonBlank(approval.approvedBy) != nil,
          approval.approvedAt.timeIntervalSince1970.isFinite,
          approval.approvedAt.timeIntervalSince1970 != 0
    else { return false }
    return true
  }

  private func emitWarning(
    context: UserContext, snapshot: MutationGovernanceSnapshot, code: String
  ) {
    let policy = snapshot.policy.map {
      "\($0.policyID):\($0.version):\($0.fingerprint)"
    } ?? "none"
    let key = "\(snapshot.requestKey)|\(policy)|\(code)"
    warningLock.lock()
    let first = emittedWarnings.insert(key).inserted
    warningLock.unlock()
    try? warningSink.onWarning(
      context: context,
      warning: MutationGovernanceWarning(
        snapshot: snapshot, warningCode: code, firstOccurrence: first))
  }

  private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private extension JSONEncoder {
  static var sorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}
