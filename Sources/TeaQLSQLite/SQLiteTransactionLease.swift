import Foundation
import TeaQLCore

final class SQLiteTransactionAccess: @unchecked Sendable {
  let id = UUID()
  private let lock = NSLock()
  private var open = true
  private var complete = false

  func requireOpen() throws {
    try lock.withLock {
      guard open else { throw TeaQLError.execution("TRANSACTION_CONTEXT_EXPIRED: the transaction callback has ended") }
    }
  }

  func close() { lock.withLock { open = false } }
  func finish() { lock.withLock { open = false; complete = true } }
  var needsRollback: Bool { lock.withLock { !complete } }
}

final class SQLiteTransactionLease: UserContextTransactionLease {
  let service: SQLiteDataService
  let access: SQLiteTransactionAccess

  init(service: SQLiteDataService, access: SQLiteTransactionAccess) {
    self.service = service
    self.access = access
  }

  private var participant: SQLiteTransactionParticipant { .init(service: service, access: access) }
  var queryExecutor: any QueryExecutor { participant }
  var mutationExecutor: any MutationExecutor { participant }
  func closeAccess() { access.close() }
  func commit() async throws { try await service.finishUserContextTransaction(access, commit: true) }
  func rollback() async throws { try await service.finishUserContextTransaction(access, commit: false) }

  deinit {
    guard access.needsRollback else { return }
    access.close()
    let service = service
    let access = access
    Task { try? await service.finishUserContextTransaction(access, commit: false) }
  }
}

private struct SQLiteTransactionParticipant: SQLDiagnosticExecutor, SQLCountDiagnosticExecutor,
  QueryIntentProvenanceExecutor, RelationTopNPlanning, NativeProviderIdentity {
  let service: SQLiteDataService
  let access: SQLiteTransactionAccess
  var idSetDataSourceIdentity: String { service.idSetDataSourceIdentity }
  var relationTopNPolicy: RelationTopNPolicy { service.relationTopNPolicy }
  var nativeProviderKind: String { (service as any QueryExecutor).providerKind }

  func execute(_ request: QueryRequest) async throws -> QueryResult {
    do { return try await executeDiagnosed(request) }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  func count(_ request: QueryRequest) async throws -> Int {
    do { return try await countDiagnosed(request).count }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  func execute(_ request: MutationRequest) async throws -> MutationResult {
    do { return try await executeDiagnosed(request) }
    catch let failure as SQLExecutionFailure { throw failure.cause }
  }

  func executeDiagnosed(_ request: QueryRequest) async throws -> QueryResult {
    try await service.executeDiagnosed(request, owner: access)
  }

  func countDiagnosed(_ request: QueryRequest) async throws -> SQLCountResult {
    try await service.countDiagnosed(request, owner: access)
  }

  func executeDiagnosed(_ request: MutationRequest) async throws -> MutationResult {
    try await service.executeDiagnosed(request, owner: access)
  }

  func queryIntentProvenance(_ request: QueryRequest) async throws -> SQLExecutionMetadata {
    try access.requireOpen()
    return try await service.queryIntentProvenance(request)
  }
}
