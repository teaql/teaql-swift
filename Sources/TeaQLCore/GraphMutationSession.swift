import Foundation

/// Persistence succeeded; downstream cleanup or audit delivery failed. Retrying the
/// mutation itself would be wrong. Causes remain available to trusted code.
public struct GraphCommittedError: Error, Sendable, CustomStringConvertible {
  public let committed = true
  public let causes: [any Error]
  public var description: String { "Graph committed; \(causes.count) completion callbacks or audit deliveries failed" }
  package init(causes: [any Error]) { self.causes = causes }
}

/// Immutable responsibility branch. No push/pop state lives on UserContext.
public final class TraceScopeToken: Sendable {
  public let parent: TraceScopeToken?
  public let node: TraceNode
  fileprivate let owner: UUID?

  public convenience init(parent: TraceScopeToken? = nil, key: EntityKey, reason: String) throws {
    try self.init(parent: parent, key: key, reason: reason, owner: nil)
  }

  fileprivate init(parent: TraceScopeToken?, key: EntityKey, reason: String, owner: UUID?) throws {
    _ = try MutationIntent(comment: reason)
    self.parent = parent
    self.owner = owner
    self.node = TraceNode(entity: key.entity, comment: reason, purpose: "",
      kind: "auditReason", name: key.entity, entityID: key.id)
  }

  public func recover() -> [TraceNode] {
    var result: [TraceNode] = []
    var cursor: TraceScopeToken? = self
    while let scope = cursor { result.append(scope.node); cursor = scope.parent }
    return result.reversed().enumerated().map { index, node in
      TraceNode(entity: node.entity, comment: node.comment, purpose: node.purpose,
        level: index, kind: node.kind, name: node.name, entityID: node.entityID)
    }
  }

  public func assigning(_ originalKey: EntityKey, to savedKey: EntityKey) throws -> TraceScopeToken {
    guard node.name == originalKey.entity, node.entityID == originalKey.id else { return self }
    return try TraceScopeToken(parent: parent, key: savedKey, reason: node.comment, owner: owner)
  }
}

/// One explicit graph invocation. Generated traversal passes both this session
/// and immutable parent tokens; independent roots never implicitly join it.
public final class GraphMutationSession: @unchecked Sendable {
  private let id = UUID()
  public let intent: MutationIntent
  public let fixTime: Date
  package let policy: MutationPolicyCoordinator
  private let lock = NSLock()
  private var active = true
  private var commitActions: [@Sendable () throws -> Void] = []
  private var rollbackActions: [@Sendable () throws -> Void] = []
  private var auditEvents: [(AuditEvent, [TeaQLValue])] = []
  private var privacyValues: [TeaQLValue] = []
  private var fixEvidence: [FixEvidence] = []

  package init(intent: MutationIntent, policy: MutationPolicyCoordinator) {
    self.intent = intent; self.policy = policy; fixTime = Date()
  }

  package func ensureActive() throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("Graph Mutation Session is already closed") }
    }
  }

  public func scope(key: EntityKey, localReason: String? = nil,
                    parent: TraceScopeToken? = nil) throws -> TraceScopeToken {
    try ensureActive()
    guard let parent else { return try TraceScopeToken(parent: nil, key: key, reason: intent.comment, owner: id) }
    guard parent.owner == id else {
      throw TeaQLError.execution("Trace scope belongs to a different Graph Mutation Session")
    }
    guard let localReason, (try? MutationIntent(comment: localReason)) != nil else { return parent }
    return try TraceScopeToken(parent: parent, key: key, reason: localReason, owner: id)
  }

  public func afterCommit(_ action: @escaping @Sendable () throws -> Void) throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("Graph Mutation Session is already closed") }
      commitActions.append(action)
    }
  }

  public func afterRollback(_ action: @escaping @Sendable () throws -> Void) throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("Graph Mutation Session is already closed") }
      rollbackActions.append(action)
    }
  }

  package func recordFixEvidence(_ value: FixEvidence) { lock.withLock { fixEvidence.append(value) } }
  package func recordProvenance(_ values: [TeaQLValue]) { lock.withLock { privacyValues.append(contentsOf: values) } }
  package func bufferAudit(_ event: AuditEvent, values: [TeaQLValue]) throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("Graph Mutation Session is already closed") }
      auditEvents.append((event, values)); privacyValues.append(contentsOf: values)
    }
  }
  package var intentProvenance: SQLExecutionMetadata {
    lock.withLock {
      SQLExecutionMetadata(operation: .select, parameterizedSQL: "", parameters: privacyValues,
        debugSQL: "", elapsedMicros: 0, resultSummary: "",
        parameterLogPolicies: Array(repeating: .unknown, count: privacyValues.count), generatedSQL: true)
    }
  }
  package func finish(committed: Bool) -> ([@Sendable () throws -> Void], [AuditEvent], [FixEvidence]) {
    lock.withLock {
      precondition(active)
      active = false
      let events = committed ? auditEvents.map { event, values in
        AuditEvent(entity: event.entity, entityID: event.entityID, operation: event.operation,
          reason: LogPrivacy.scrub(event.reason, values: privacyValues + values), actor: event.actor,
          category: event.category, occurredAt: event.occurredAt,
          mutationGovernance: event.mutationGovernance,
          mutationLineage: TraceChain.maskLineage(event.mutationLineage ?? [], values: privacyValues + values))
      } : []
      let actions = committed ? commitActions : rollbackActions.reversed()
      commitActions = []; rollbackActions = []; auditEvents = []; privacyValues = []
      return (Array(actions), events, fixEvidence)
    }
  }
}

/// Shared provider coordination only; never owns lineage or graph callbacks.
package final class GraphTransactionGate: @unchecked Sendable {
  package enum Reentry { @TaskLocal static var active: Set<UUID> = [] }
  package let id = UUID()
  private let lock = NSLock()
  private var occupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var retainedFixEvidence: [FixEvidence] = []

  package func acquire() async {
    while true {
      if lock.withLock({ if occupied { return false }; occupied = true; return true }) { return }
      await withCheckedContinuation { continuation in
        let resume = lock.withLock {
          if !occupied { return true }; waiters.append(continuation); return false
        }
        if resume { continuation.resume() }
      }
    }
  }
  package func release(evidence: [FixEvidence]) {
    let waiter = lock.withLock {
      retainedFixEvidence = evidence; occupied = false
      return waiters.isEmpty ? nil : waiters.removeFirst()
    }
    waiter?.resume()
  }
  package var lastFixEvidence: [FixEvidence] { lock.withLock { retainedFixEvidence } }
}
