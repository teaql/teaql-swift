import Foundation

/// Owns one native transaction. The exposed executors can use the connection
/// but cannot commit, roll back, or retain access past the end of the callback.
public protocol UserContextTransactionLease: Sendable {
  var queryExecutor: any QueryExecutor { get }
  var mutationExecutor: any MutationExecutor { get }
  func closeAccess()
  func commit() async throws
  func rollback() async throws
}

/// One physical data service must own both query and mutation routes.
public protocol UserContextTransactionExecutor: AnyObject, QueryExecutor, MutationExecutor {
  func beginUserContextTransaction() async throws -> any UserContextTransactionLease
}

public struct TransactionOutcomeUnknown: Error, Sendable, CustomStringConvertible {
  public init() {}
  public var description: String {
    "TRANSACTION_OUTCOME_UNKNOWN: reload authoritative state before attempting the operation again"
  }
}

package struct TransactionReadbackRolledBack: Error, Sendable, CustomStringConvertible {
  package var description: String {
    "TRANSACTION_READBACK_ROLLED_BACK: the transaction-local record must be reloaded"
  }
}

package final class UserContextTransactionScope: @unchecked Sendable {
  package let providerIdentity: ObjectIdentifier
  private let lock = NSLock()
  private var active = true
  private var firstFailure: (any Error)?
  private var graphs: [GraphMutationSession.Completion] = []
  private var events: [AuditEvent] = []
  private var ledgers: [ObjectIdentifier: EntityRoot] = [:]
  private var settled = false

  package init(providerIdentity: ObjectIdentifier) { self.providerIdentity = providerIdentity }

  package func requireAccess() throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("TRANSACTION_CONTEXT_EXPIRED: the transaction callback has ended") }
    }
  }

  package func requireWritable() throws {
    try lock.withLock {
      guard active else { throw TeaQLError.execution("TRANSACTION_CONTEXT_EXPIRED: the transaction callback has ended") }
      guard firstFailure == nil else { throw TeaQLError.execution("TRANSACTION_ROLLBACK_ONLY: a previous save failed") }
    }
  }

  package func fail(_ error: any Error) {
    lock.withLock { if !settled && firstFailure == nil { firstFailure = error } }
  }

  package func enlist(_ graph: GraphMutationSession.Completion) {
    lock.withLock {
      graphs.append(graph)
      events.append(contentsOf: graph.events)
    }
  }

  package func bufferAudit(_ event: AuditEvent) { lock.withLock { events.append(event) } }
  package func track(_ ledger: EntityRoot?) {
    guard let ledger else { return }
    lock.withLock { ledgers[ObjectIdentifier(ledger)] = ledger }
  }
  package func closeAccess() { lock.withLock { active = false } }

  package struct Completion: Sendable {
    let failure: (any Error)?
    let graphs: [GraphMutationSession.Completion]
    let events: [AuditEvent]
    let ledgers: [EntityRoot]

    func rollback() {
      for graph in graphs.reversed() { graph.rollback() }
    }

    func fence() {
      for graph in graphs { graph.fence() }
      for ledger in ledgers { ledger.fenceTransaction(TransactionOutcomeUnknown()) }
    }
  }

  package func takeCompletion() -> Completion {
    lock.withLock {
      let completion = Completion(failure: firstFailure, graphs: graphs, events: events,
        ledgers: Array(ledgers.values))
      firstFailure = nil
      graphs = []
      events = []
      ledgers = [:]
      settled = true
      return completion
    }
  }
}
