import Foundation

public protocol QueryExecutor: Sendable {
  var idSetDataSourceIdentity: String { get }
  func execute(_ request: QueryRequest) async throws -> QueryResult
  func count(_ request: QueryRequest) async throws -> Int
}

public enum RelationTopNPolicy: Sendable { case window, alwaysProbe }
public protocol RelationTopNPlanning: Sendable {
  var relationTopNPolicy: RelationTopNPolicy { get }
}

/// Physical schema capability selected by a UserContext.
/// RuntimeModule installation remains passive; applications call UserContext.ensureSchema(_:).
package protocol SchemaExecutor: Sendable {
  func ensureSchema(_ module: RuntimeModule, context: UserContext) async throws
}

public extension QueryExecutor {
  var providerKind: String { String(describing: type(of: self)) }
  var idSetDataSourceIdentity: String { providerKind }

  func execute(_ query: SelectQuery) async throws -> QueryResult {
    try await execute(QueryRequest(query: query))
  }

  func count(_ query: SelectQuery) async throws -> Int {
    try await count(QueryRequest(query: query))
  }

  func count(_ request: QueryRequest) async throws -> Int {
    throw TeaQLError.execution(
      "Exact count is not supported by the configured query executor for \(request.query.entity.name)")
  }
}

public enum MutationKind: String, Sendable, Codable { case create, update, delete, recover }

public struct ContextEntityRef: Sendable, Hashable, Codable {
  public let entity: String
  public let id: TeaQLValue
  public init(entity: String, id: TeaQLValue) {
    precondition(!entity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.entity = entity
    self.id = id
  }
}

public struct ContextRootError: Error, Sendable {
  public enum Reason: String, Sendable { case missing, typeMismatch }
  public let reason: Reason
  public let expectedType: String
  public let activeRoot: ContextEntityRef?
}

public protocol EntityChecker: Sendable {
  func checkAndFix(
    context: UserContext, mutation: inout Mutation, now: Date
  ) throws -> [CheckResult]
}

public struct CheckException: Error, Sendable {
  public let violations: [CheckResult]
  public init(_ violations: [CheckResult]) { self.violations = violations }
}

public enum SQLExecutionOperation: String, Sendable, Codable {
  case select, insert, update, delete, recover
}

public struct SQLExecutionMetadata: Sendable {
  /// Ordered physical children of a logical result; leaves have no children.
  public private(set) var statements: [SQLExecutionMetadata] = []

  package func includingStatements(_ statements: [SQLExecutionMetadata]) -> Self {
    var result = self
    result.statements = statements
    return result
  }
  // Immutable value copies retain the already-safe fallback, never raw provenance.
  var maskedAlternative: SQLMaskedAlternative?
  var isSafeProjection = false
  public let operation: SQLExecutionOperation
  public let comment: String?
  public let purpose: String?
  public let auditReason: String?
  public let tracePath: [TraceNode]
  public let mutationLineage: [TraceNode]
  public let parameterizedSQL: String
  public let parameters: [TeaQLValue]
  public let debugSQL: String
  public let elapsedMicros: UInt64
  public let resultCount: Int?
  public let affectedRows: Int?
  public let resultSummary: String
  public let parameterLogPolicies: [SQLParameterLogPolicy]
  public let maskedParameters: [Bool]
  public let generatedSQL: Bool
  public let sqlOmissionReason: String?
  /// Statement completion, not graph/transaction commit.
  public let executionOutcome: String?

  public init(
    operation: SQLExecutionOperation,
    comment: String? = nil,
    purpose: String? = nil,
    auditReason: String? = nil,
    tracePath: [TraceNode] = [],
    mutationLineage: [TraceNode] = [],
    parameterizedSQL: String,
    parameters: [TeaQLValue],
    debugSQL: String,
    elapsedMicros: UInt64,
    resultCount: Int? = nil,
    affectedRows: Int? = nil,
    resultSummary: String,
    parameterLogPolicies: [SQLParameterLogPolicy] = [],
    maskedParameters: [Bool] = [],
    generatedSQL: Bool = false,
    sqlOmissionReason: String? = nil,
    executionOutcome: String? = nil
  ) {
    self.operation = operation
    self.comment = comment
    self.purpose = purpose
    self.auditReason = auditReason
    self.tracePath = tracePath
    self.mutationLineage = mutationLineage
    self.parameterizedSQL = parameterizedSQL
    self.parameters = parameters
    self.debugSQL = debugSQL
    self.elapsedMicros = elapsedMicros
    self.resultCount = resultCount
    self.affectedRows = affectedRows
    self.resultSummary = resultSummary
    self.parameterLogPolicies = parameterLogPolicies
    self.maskedParameters = maskedParameters
    self.generatedSQL = generatedSQL
    self.sqlOmissionReason = sqlOmissionReason
    self.executionOutcome = executionOutcome
  }
}

public protocol RuntimeTelemetrySink: Sendable {
  func record(_ metadata: SQLExecutionMetadata) async
}

/// SQL diagnostic destination. Values are redacted unless explicitly enabled
/// by the runtime's exact plaintext acknowledgement environment setting.
public protocol DiagnosticSQLLogSink: Sendable {
  func write(_ metadata: SQLExecutionMetadata) async
}

public actor TextDiagnosticSQLLogSink: DiagnosticSQLLogSink {
  private let writer: @Sendable (String) -> Void
  private var lines: [String] = []

  public init(writer: @escaping @Sendable (String) -> Void = { print($0) }) {
    self.writer = writer
  }

  public func write(_ metadata: SQLExecutionMetadata) {
    let metadata = LogPrivacy.project(metadata, allowPlaintext: LogPrivacy.plaintextEnabled())
    let text = "[TeaQL SQL][\(metadata.operation.rawValue)][\(metadata.elapsedMicros)us] "
      + "\(metadata.resultSummary) outcome=\(metadata.executionOutcome ?? "unknown") comment=\(metadata.comment ?? "") "
      + "purpose=\(metadata.purpose ?? "") auditReason=\(metadata.auditReason ?? "") "
      + "tracePath=\(metadata.tracePath) parameterCount=\(metadata.parameters.count)\n"
      + "SQL: \(metadata.debugSQL)"
    lines.append(text)
    writer(text)
  }

  public func snapshot() -> [String] { lines }
}

public actor SQLExecutionEvidenceStore: RuntimeTelemetrySink {
  public enum Mode: Sendable, Equatable { case all, select, mutation, disabled }
  private var mode: Mode = .all
  private var entries: [SQLExecutionMetadata] = []

  public init() {}

  public func record(_ metadata: SQLExecutionMetadata) {
    let isSelect = metadata.operation == .select
    guard mode == .all || (mode == .select && isSelect) || (mode == .mutation && !isSelect)
    else { return }
    entries.append(LogPrivacy.project(metadata))
  }

  public func enableAll() { mode = .all; entries.removeAll() }
  public func enableSelect() { mode = .select; entries.removeAll() }
  public func enableMutation() { mode = .mutation; entries.removeAll() }
  public func disable() { mode = .disabled; entries.removeAll() }
  public func snapshot() -> [SQLExecutionMetadata] { entries }
}

public struct Mutation: Sendable, Codable {
  // Trusted loaded provenance; never decoded from JSON or included in a write.
  package var loadedValues: TeaQLRecord = [:]
  private enum CodingKeys: String, CodingKey {
    case kind, entity, id, values, expectedVersion, auditReason, actor, auditCategory, mutationLineage
  }
  public let kind: MutationKind
  public let entity: EntityDescriptor
  public var id: TeaQLValue?
  public var values: TeaQLRecord
  public var expectedVersion: Int64?
  public var auditReason: String?
  public var actor: String?
  public var auditCategory: String?
  public var mutationLineage: [TraceNode]?

  public init(
    kind: MutationKind,
    entity: EntityDescriptor,
    id: TeaQLValue? = nil,
    values: TeaQLRecord = [:],
    expectedVersion: Int64? = nil,
    auditReason: String? = nil,
    actor: String? = nil,
    auditCategory: String? = nil,
    mutationLineage: [TraceNode]? = nil
  ) {
    self.kind = kind
    self.entity = entity
    self.id = id
    self.values = values
    self.expectedVersion = expectedVersion
    self.auditReason = auditReason
    self.actor = actor
    self.auditCategory = auditCategory
    self.mutationLineage = mutationLineage
  }

  public func validatedForExecution() throws -> Self {
    _ = try MutationIntent(comment: auditReason)
    return self
  }
}

public struct MutationResult: Sendable {
  public let affectedRows: Int
  public let generatedValues: TeaQLRecord
  /// The authoritative persisted scalar row, captured in the mutation transaction.
  public let persistedRecord: TeaQLRecord?
  public let metadata: SQLExecutionMetadata?

  public init(
    affectedRows: Int,
    generatedValues: TeaQLRecord = [:],
    persistedRecord: TeaQLRecord? = nil,
    metadata: SQLExecutionMetadata? = nil
  ) {
    self.affectedRows = affectedRows
    self.generatedValues = generatedValues
    self.persistedRecord = persistedRecord
    self.metadata = metadata
  }
}

public protocol MutationExecutor: Sendable {
  func execute(_ request: MutationRequest) async throws -> MutationResult
}

public protocol GraphTransactionExecutor: MutationExecutor {
  func beginGraphTransaction() async throws
  func commitGraphTransaction() async throws
  func rollbackGraphTransaction() async throws
}

public extension MutationExecutor {
  var providerKind: String { String(describing: type(of: self)) }
  func execute(_ mutation: Mutation) async throws -> MutationResult {
    try await execute(MutationRequest(mutation: mutation))
  }
}

public enum FixEvidenceSource: String, Sendable { case clock, context }

public struct FixEvidence: Sendable, Equatable {
  public let entityType: String
  public let modelPath: String
  public let source: FixEvidenceSource
  public let sourceLabel: String

  public init(entityType: String, modelPath: String, source: FixEvidenceSource, sourceLabel: String) {
    precondition(!entityType.isEmpty && !modelPath.isEmpty && !sourceLabel.isEmpty)
    let normalized = sourceLabel.lowercased()
    precondition(!normalized.contains("authorization") && !normalized.contains("cookie") && !normalized.contains("token="),
      "sourceLabel must be a safe framework label")
    self.entityType = entityType; self.modelPath = modelPath; self.source = source; self.sourceLabel = sourceLabel
  }
}

public protocol AuditSink: Sendable {
  func record(_ event: AuditEvent) async throws
}

public struct AuditedEntity<Entity: TeaQLEntity>: Sendable {
  public let entity: Entity
  public let reason: String

  public init(entity: Entity, reason: String) {
    self.entity = entity
    self.reason = reason
  }

  public func save(_ context: UserContext) async throws -> Entity {
    _ = try MutationIntent(comment: reason)
    return try await context.executeGraphSave(comment: reason) { graphContext, session in
      try preflight(graphContext)
      let key = (entity as? any TeaQLMutationRootedEntity)?.teaqlEntityKey
        ?? EntityKey(entity: Entity.descriptor.name, id: .int(entity.id))
      return try await saveInGraph(graphContext, session: session,
        scope: session.scope(key: key))
    }
  }

  /// Generated graph infrastructure calls this for every reachable node before
  /// the first mutation of the graph is sent to the provider.
  public func preflight(_ context: UserContext) throws {
    let rooted = entity as? any TeaQLMutationRootedEntity
    if let rooted, entity.version != 0, !rooted.teaqlEntityRoot.hasPending(rooted.teaqlEntityKey) { return }
    _ = try context.preflightMutation(
      makeMutation(rooted: rooted),
      ledgerRoot: rooted?.teaqlEntityRoot,
      ledgerKey: rooted?.teaqlEntityKey)
  }

  /// Generated traversal uses the explicitly supplied session; it must not
  /// start another public save and silently join an unrelated root.
  public func saveInGraph(_ context: UserContext, session: GraphMutationSession,
                          scope: TraceScopeToken) async throws -> Entity {
    try context.requireGraphSession(session)
    let rooted = entity as? any TeaQLMutationRootedEntity
    if let rooted, entity.version != 0, !rooted.teaqlEntityRoot.hasPending(rooted.teaqlEntityKey) { return entity }
    var mutation = try makeMutation(rooted: rooted)
    mutation.auditReason = session.intent.auditReason
    mutation.mutationLineage = rooted.map { $0.teaqlEntityRoot.traceChain($0.teaqlEntityKey, fallback: scope) }
      ?? scope.recover()
    let saved = try persistedEntity(from: await context.execute(
      mutation, ledgerRoot: rooted?.teaqlEntityRoot, ledgerKey: rooted?.teaqlEntityKey))
    if let rooted {
      let originalKey = rooted.teaqlEntityKey
      let savedKey = EntityKey(entity: rooted.teaqlEntityKey.entity, id: .int(saved.id))
      let root = rooted.teaqlEntityRoot
      try session.afterCommit {
        try root.rekey(originalKey, to: savedKey)
        root.clearEntity(savedKey)
        try root.acceptCommittedVersion(savedKey, version: saved.version)
      }
    }
    return saved
  }

  private func makeMutation(rooted: (any TeaQLMutationRootedEntity)?) throws -> Mutation {
    var values = entity.toMutationRecord()
    let originalVersion = rooted.flatMap { $0.teaqlEntityRoot.originalVersion($0.teaqlEntityKey) } ?? entity.version
    if let rooted {
      if entity.id != 0 {
        let pending = rooted.teaqlEntityRoot.change(rooted.teaqlEntityKey)
        if !pending.isEmpty { values = pending }
      }
    }
    var mutation: Mutation
    if let rooted, rooted.teaqlEntityRoot.isDeleted(rooted.teaqlEntityKey) {
      guard entity.id != 0, entity.version != 0 else {
        throw TeaQLError.execution("Deletion requires a loaded entity ID and version")
      }
      mutation = Mutation(
        kind: .delete,
        entity: Entity.descriptor,
        id: .int(entity.id),
        expectedVersion: originalVersion,
        auditReason: reason
      )
    } else if entity.version == 0 {
      let idName = Entity.descriptor.idProperty?.name ?? "id"
      if entity.id == 0 { values.removeValue(forKey: idName) }
      else { values[idName] = .int(entity.id) }
      mutation = Mutation(
        kind: .create,
        entity: Entity.descriptor,
        values: values,
        auditReason: reason
      )
    } else {
      guard entity.id != 0 else {
        throw TeaQLError.execution("Persisted \(Entity.descriptor.name) must have a non-zero id")
      }
      values.removeValue(forKey: Entity.descriptor.idProperty?.name ?? "id")
      values.removeValue(forKey: Entity.descriptor.versionProperty?.name ?? "version")
      mutation = Mutation(
        kind: .update,
        entity: Entity.descriptor,
        id: .int(entity.id),
        values: values,
        expectedVersion: originalVersion,
        auditReason: reason
      )
    }
    if let snapshot = rooted?.teaqlLoadedSnapshot {
      for property in Entity.descriptor.properties {
        if let value = snapshot.record[property.name]
          ?? property.modelName.flatMap({ snapshot.record[$0] }) ?? snapshot.record[property.column] {
          mutation.loadedValues[property.name] = value
        }
      }
    }
    return mutation
  }

  private func persistedEntity(from result: MutationResult) throws -> Entity {
    guard let record = result.persistedRecord else {
      throw TeaQLError.execution(
        "Mutation executor did not return authoritative persisted state for \(Entity.descriptor.name)")
    }
    // Providers return storage-column keys, while generated entity hydration is
    // intentionally expressed in language-native property names.  Normalize at
    // the runtime boundary so database-generated/defaulted and Checker/Fix
    // values are visible on the authoritative entity returned by save().
    var normalized = record
    for property in Entity.descriptor.properties where normalized[property.name] == nil {
      if let modelName = property.modelName, let value = record[modelName] {
        normalized[property.name] = value
      } else if let value = record[property.column] {
        normalized[property.name] = value
      }
    }
    return try Entity.from(record: normalized)
  }
}

extension TeaQLEntity {
  public func auditAs(_ reason: String) -> AuditedEntity<Self> {
    AuditedEntity(entity: self, reason: reason)
  }
}

public struct AuditEvent: Sendable, Codable {
  public let entity: String
  public let entityID: TeaQLValue?
  public let operation: MutationKind
  public let reason: String
  public let actor: String?
  public let category: String?
  public let occurredAt: Date
  public let mutationGovernance: MutationGovernanceSnapshot?
  public let mutationLineage: [TraceNode]?

  public init(
    entity: String, entityID: TeaQLValue?, operation: MutationKind,
    reason: String, actor: String?, category: String? = nil, occurredAt: Date,
    mutationGovernance: MutationGovernanceSnapshot? = nil,
    mutationLineage: [TraceNode]? = nil
  ) {
    self.entity = entity
    self.entityID = entityID
    self.operation = operation
    self.reason = reason
    self.actor = actor
    self.category = category
    self.occurredAt = occurredAt
    self.mutationGovernance = mutationGovernance
    self.mutationLineage = mutationLineage
  }
}

public struct RequestPolicy: Sendable {
  public let apply: @Sendable (SelectQuery) throws -> SelectQuery
  package let idSetIdentity: UUID

  public init(apply: @escaping @Sendable (SelectQuery) throws -> SelectQuery) {
    self.apply = apply
    self.idSetIdentity = UUID()
  }
}

public typealias EntityInitializer = @Sendable (
  _ context: UserContext, _ entityName: String, _ entity: inout any TeaQLEntity
) -> Void

public typealias EntityCreationObserver = @Sendable (
  _ context: UserContext, _ entityName: String, _ entity: any TeaQLEntity
) -> Void

public struct ContinuousPageObservation: Sendable, Equatable {
  public let plan: String
  public let cursorID: String?
}

private struct ContinuousPageCursor: Sendable {
  let id: String
  let boundary: TeaQLValue
  let expiresAt: Date
}

private actor ContinuousPageState {
  private var cursors: [String: ContinuousPageCursor] = [:]
  private var observation = ContinuousPageObservation(plan: "DISABLED", cursorID: nil)

  func cursor(queryKey: String, offset: Int) -> ContinuousPageCursor? {
    let key = "\(queryKey):\(offset)"
    guard let cursor = cursors[key] else { return nil }
    guard cursor.expiresAt > Date() else { cursors.removeValue(forKey: key); return nil }
    return cursor
  }

  func put(queryKey: String, offset: Int, cursor: ContinuousPageCursor) {
    cursors["\(queryKey):\(offset)"] = cursor
  }

  func observe(_ plan: String, cursorID: String? = nil) {
    observation = ContinuousPageObservation(plan: plan, cursorID: cursorID)
  }

  func currentObservation() -> ContinuousPageObservation { observation }
}

private struct ContinuousPageExecution: Sendable {
  let queryKey: String
  let originalOffset: Int
  let limit: Int
  let ttlSeconds: Int
  let optimized: Bool
  let cursorID: String?
}

public struct IdSetPaginationObservation: Sendable, Equatable {
  public let plan: String
  public let count: Int
  public let countAccuracy: String
}

public struct RetainedIdSet: Sendable {
  public let ids: [Int64]
  public let expiresAt: Date
  public init(ids: [Int64], expiresAt: Date) { self.ids = ids; self.expiresAt = expiresAt }
}

public protocol IdSetStore: Sendable {
  func obtain(
    key: String, build: @escaping @Sendable () async throws -> RetainedIdSet
  ) async throws -> (RetainedIdSet, Bool)
}

public actor InMemoryIdSetStore: IdSetStore {
  public static let shared = InMemoryIdSetStore()
  private var sets: [String: RetainedIdSet] = [:]
  private var builds: [String: Task<RetainedIdSet, Error>] = [:]

  public init() {}

  public func obtain(
    key: String, build: @escaping @Sendable () async throws -> RetainedIdSet
  ) async throws -> (RetainedIdSet, Bool) {
    if let retained = sets[key], retained.expiresAt > Date() { return (retained, false) }
    if let active = builds[key] { return (try await active.value, false) }
    let task = Task { try await build() }
    builds[key] = task
    do {
      let retained = try await task.value
      builds.removeValue(forKey: key)
      if sets.count >= 64, let oldest = sets.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
        sets.removeValue(forKey: oldest.key)
      }
      sets[key] = retained
      return (retained, true)
    } catch {
      builds.removeValue(forKey: key)
      throw error
    }
  }
}

private actor IdSetObservationState {
  private var value = IdSetPaginationObservation(
    plan: "ID_SET_DISABLED", count: 0, countAccuracy: "UNKNOWN")
  func observe(_ plan: String, count: Int = 0, accuracy: String = "UNKNOWN") {
    value = IdSetPaginationObservation(plan: plan, count: count, countAccuracy: accuracy)
  }
  func current() -> IdSetPaginationObservation { value }
}

private struct IdSetExecution: Sendable {
  let pageIds: [Int64]
}

private enum IdSetBuildError: Error { case limitExceeded(Int) }

public struct UserContext: Sendable {
  public let runtime: TeaQLRuntime
  public let actor: String?
  public let auditCategory: String?
  /// Application-owned tenant identity. It is never populated from generated
  /// query or federation payloads.
  public let trustedTenant: String?
  public let activeRoot: ContextEntityRef?
  public let queryExecutor: any QueryExecutor
  public let mutationExecutor: any MutationExecutor
  public let requestPolicy: RequestPolicy
  public let auditSink: (any AuditSink)?
  public let telemetrySink: (any RuntimeTelemetrySink)?
  public let diagnosticSQLLogSink: (any DiagnosticSQLLogSink)?
  public var querySQLLogEnabled: Bool
  public var mutationSQLLogEnabled: Bool
  public let runtimeTelemetry: any RuntimeTelemetry
  public private(set) var locale: TeaQLLocale
  public private(set) var i18nCatalog: I18nCatalog
  private let entityInitializers: [EntityInitializer]
  private let entityCreationObserver: EntityCreationObserver?
  private let continuousPageState: ContinuousPageState
  private let idSetObservationState: IdSetObservationState
  private let idSetStore: any IdSetStore
  private let graphTransactionGate: GraphTransactionGate
  private var graphSession: GraphMutationSession?
  private var mutationPolicyCoordinator: MutationPolicyCoordinator

  public init(
    runtime: TeaQLRuntime = TeaQLRuntime(),
    actor: String? = nil,
    auditCategory: String? = nil,
    trustedTenant: String? = nil,
    activeRoot: ContextEntityRef? = nil,
    queryExecutor: any QueryExecutor,
    mutationExecutor: any MutationExecutor,
    requestPolicy: RequestPolicy,
    auditSink: (any AuditSink)? = nil,
    telemetrySink: (any RuntimeTelemetrySink)? = nil,
    diagnosticSQLLogSink: (any DiagnosticSQLLogSink)? = TextDiagnosticSQLLogSink(),
    querySQLLogEnabled: Bool = true,
    mutationSQLLogEnabled: Bool = true,
    runtimeTelemetry: any RuntimeTelemetry = NoopRuntimeTelemetry(),
    idSetStore: any IdSetStore = InMemoryIdSetStore.shared,
    locale: TeaQLLocale = .en,
    i18nCatalog: I18nCatalog = .builtin,
    entityInitializers: [EntityInitializer] = [],
    entityCreationObserver: EntityCreationObserver? = nil,
    mutationPolicyRegistry: (any MutationPolicyRegistry)? = nil,
    mutationPolicyApprovalProvider: (any MutationPolicyApprovalProvider)? = nil,
    mutationGovernanceSink: (any MutationGovernanceSink)? = nil
  ) {
    self.runtime = runtime
    self.actor = actor
    self.auditCategory = auditCategory
    self.trustedTenant = trustedTenant
    self.activeRoot = activeRoot
    self.queryExecutor = queryExecutor
    self.mutationExecutor = mutationExecutor
    self.requestPolicy = requestPolicy
    self.auditSink = auditSink
    self.telemetrySink = telemetrySink
    self.diagnosticSQLLogSink = diagnosticSQLLogSink ?? TextDiagnosticSQLLogSink()
    self.querySQLLogEnabled = querySQLLogEnabled
    self.mutationSQLLogEnabled = mutationSQLLogEnabled
    self.runtimeTelemetry = runtimeTelemetry
    self.idSetStore = idSetStore
    self.locale = locale
    self.i18nCatalog = i18nCatalog
    self.entityInitializers = entityInitializers
    self.entityCreationObserver = entityCreationObserver
    self.continuousPageState = ContinuousPageState()
    self.idSetObservationState = IdSetObservationState()
    self.graphTransactionGate = GraphTransactionGate()
    self.graphSession = nil
    self.mutationPolicyCoordinator = MutationPolicyCoordinator(
      registry: mutationPolicyRegistry,
      approvalProvider: mutationPolicyApprovalProvider,
      warningSink: mutationGovernanceSink)
  }

  public func executeGraphSave<T: Sendable>(
    comment: String,
    _ operation: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> T
  ) async throws -> T {
    try await executeGraphSave(GraphMutationRequest(comment: comment), operation)
  }

  public func executeGraphSave<T: Sendable>(
    _ request: GraphMutationRequest,
    _ operation: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> T
  ) async throws -> T {
    guard graphSession == nil, !GraphTransactionGate.Reentry.active.contains(graphTransactionGate.id) else {
      throw TeaQLError.execution("Independent graph save cannot implicitly join an active graph; pass its explicit session for composed children")
    }
    guard let transaction = mutationExecutor as? any GraphTransactionExecutor else {
      throw TeaQLError.execution("The configured mutation provider does not support atomic graph saves")
    }
    await graphTransactionGate.acquire()
    let policy = mutationPolicyCoordinator.fork()
    let session = GraphMutationSession(intent: request.intent, policy: policy)
    var invocation = self
    invocation.graphSession = session
    invocation.mutationPolicyCoordinator = policy
    let graphContext = invocation
    var committed = false
    var transactionStarted = false
    var retainedEvidence: [FixEvidence] = []
    var gateReleased = false
    defer { if !gateReleased { graphTransactionGate.release(evidence: retainedEvidence) } }
    let result: T
    do {
      try policy.beginGraph(auditReason: request.intent.auditReason)
      try await transaction.beginGraphTransaction()
      transactionStarted = true
      result = try await GraphTransactionGate.Reentry.$active.withValue(
        GraphTransactionGate.Reentry.active.union([graphTransactionGate.id])) {
          try await operation(graphContext, session)
      }
      try policy.ensureGraphComplete()
      try await transaction.commitGraphTransaction()
      committed = true
      policy.endGraph()
    } catch {
      if transactionStarted && !committed { try? await transaction.rollbackGraphTransaction() }
      policy.endGraph()
      let (actions, _, evidence) = session.finish(committed: false)
      retainedEvidence = evidence
      for action in actions { try? action() }
      mutationPolicyCoordinator.retain(policy.lastSnapshot)
      throw error
    }
    let (actions, events, evidence) = session.finish(committed: true)
    retainedEvidence = evidence
    var deliveryFailures: [any Error] = []
    for action in actions {
      do { try action() }
      catch { deliveryFailures.append(error) }
    }
    mutationPolicyCoordinator.retain(policy.lastSnapshot)
    graphTransactionGate.release(evidence: retainedEvidence)
    gateReleased = true
    // Commit already succeeded: a sink failure must never trigger rollback.
    for event in events {
      do { try await auditSink?.record(event) }
      catch { deliveryFailures.append(error) }
    }
    if !deliveryFailures.isEmpty { throw GraphCommittedError(causes: deliveryFailures) }
    return result
  }

  public var fixTime: Date { graphSession?.fixTime ?? Date() }
  public func recordFixEvidence(_ evidence: FixEvidence) { graphSession?.recordFixEvidence(evidence) }
  public var lastFixEvidence: [FixEvidence] { graphTransactionGate.lastFixEvidence }

  package func requireGraphSession(_ session: GraphMutationSession) throws {
    guard graphSession === session else {
      throw TeaQLError.execution("Graph mutation requires its explicit invocation context and session")
    }
    try session.ensureActive()
  }

  public var lastMutationGovernance: MutationGovernanceSnapshot? {
    mutationPolicyCoordinator.lastSnapshot
  }

  public func reviewMutationPlan(_ plan: MutationPlan) throws -> MutationGovernanceSnapshot {
    _ = try MutationIntent(comment: plan.auditReason)
    return try mutationPolicyCoordinator.review(context: self, plan: plan)
  }

  public func requireActiveRoot(_ expectedType: String) throws -> ContextEntityRef {
    guard let activeRoot else {
      throw ContextRootError(reason: .missing, expectedType: expectedType, activeRoot: nil)
    }
    guard activeRoot.entity == expectedType else {
      throw ContextRootError(reason: .typeMismatch, expectedType: expectedType, activeRoot: activeRoot)
    }
    return activeRoot
  }

  /// Explicitly reconciles a passive RuntimeModule through this context's provider.
  public func ensureSchema(_ module: RuntimeModule) async throws {
    guard let provider = queryExecutor as? any SchemaExecutor else {
      throw TeaQLError.execution(
        "Ensure Schema requires a schema-aware provider; configured provider is \(queryExecutor.providerKind)")
    }
    try await provider.ensureSchema(module, context: self)
    try await module.generatedBootstrap?(self)
  }

  /// SPI for generated modules. Bootstrap mutations use an isolated graph-save
  /// coordinator while retaining the caller's provider, installed checkers,
  /// policies, sinks, and trusted application context.
  public func _generatedBootstrapContext(
    actor: String = "teaql-generated-bootstrap",
    activeRoot: ContextEntityRef? = nil
  ) -> UserContext {
    UserContext(
      runtime: runtime,
      actor: actor,
      auditCategory: "runtime-bootstrap",
      trustedTenant: trustedTenant,
      activeRoot: activeRoot,
      queryExecutor: queryExecutor,
      mutationExecutor: mutationExecutor,
      requestPolicy: requestPolicy,
      auditSink: auditSink,
      telemetrySink: telemetrySink,
      diagnosticSQLLogSink: diagnosticSQLLogSink,
      querySQLLogEnabled: querySQLLogEnabled,
      mutationSQLLogEnabled: mutationSQLLogEnabled,
      runtimeTelemetry: runtimeTelemetry,
      idSetStore: idSetStore,
      locale: locale,
      i18nCatalog: i18nCatalog,
      entityInitializers: entityInitializers,
      entityCreationObserver: entityCreationObserver)
  }

  public mutating func setLocaleCode(_ code: String) throws { let value = try TeaQLLocale.parse(code); locale = value }
  public mutating func setLanguageCode(_ code: String) throws { try setLocaleCode(code) }
  public mutating func installI18nCatalog(_ catalog: I18nCatalog) { i18nCatalog = catalog }
  public func translateCheckResults(_ results: [CheckResult]) -> [CheckResult] { results.map { i18nCatalog.translate($0, locale: locale) } }

  /// Applies trusted local defaults without exposing them as generated input.
  public func initializeEntity<Entity: TeaQLEntity>(
    _ entityName: String, _ entity: Entity
  ) -> Entity {
    precondition(!entityName.isEmpty, "entityName must not be empty")
    var initialized: any TeaQLEntity = entity
    for initializer in entityInitializers {
      initializer(self, entityName, &initialized)
    }
    guard let concrete = initialized as? Entity else {
      preconditionFailure("Entity initializer changed the concrete type for \(entityName)")
    }
    entityCreationObserver?(self, entityName, concrete)
    return concrete
  }

  public func execute(_ query: SelectQuery) async throws -> QueryResult {
    try await execute(QueryRequest(query: query))
  }

  public func execute(_ request: QueryRequest) async throws -> QueryResult {
    try await execute(request, inheritedIntent: nil)
  }

  private func execute(
    _ request: QueryRequest, inheritedIntent: SQLExecutionMetadata?, attachmentKey: String? = nil
  ) async throws -> QueryResult {
    let query = request.query
    return try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "query", name: "\(query.entity.name).list",
        attributes: ["teaql.entity.type": .string(query.entity.name)]
      ), completion: { result in
      ["teaql.result.cardinality": .integer(Int64(result.records.count))]
    }) {
      try await executeQuery(request, inheritedIntent: inheritedIntent, attachmentKey: attachmentKey)
    }
  }

  public func continuousPageObservation() async -> ContinuousPageObservation {
    await continuousPageState.currentObservation()
  }

  public func idSetPaginationObservation() async -> IdSetPaginationObservation {
    await idSetObservationState.current()
  }

  private func executeQuery(
    _ request: QueryRequest, inheritedIntent: SQLExecutionMetadata?, attachmentKey: String?
  ) async throws -> QueryResult {
    let validated = try request.withQuery(requestPolicy.apply(request.query)).query.validatedForExecution()
    // Root prose can mention a masked value bound only by a descendant. Capture
    // declared bindings before emitting parent logs, without fetching children.
    let invocationIntent: SQLExecutionMetadata?
    if let inheritedIntent { invocationIntent = inheritedIntent }
    else { invocationIntent = try await queryIntentProvenance(request.withQuery(validated)) }
    let idSetPrepared = try await prepareIdSetPagination(validated)
    let prepared = await prepareContinuousPage(idSetPrepared.query)
    var base = prepared.query
    base.relations = []
    base.relationAggregates = []
    base.facets = []
    let rawResult = try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "provider", name: "\(queryExecutor.providerKind).query",
        attributes: [
          "teaql.provider.kind": .string(queryExecutor.providerKind),
          "teaql.provider.operation": .string("query"),
        ]
      )
    ) {
      do {
        if let diagnosed = queryExecutor as? any SQLDiagnosticExecutor {
          return try await diagnosed.executeDiagnosed(request.withQuery(base))
        }
        return try await queryExecutor.execute(request.withQuery(base))
      } catch let failure as SQLExecutionFailure {
        for diagnostic in failure.diagnostics {
          let source = LogPrivacy.inheritIntent(diagnostic.intentSource, inherited: invocationIntent)
          await telemetrySink?.record(LogPrivacy.project(diagnostic.metadata, intentSource: source))
          if querySQLLogEnabled {
            await diagnosticSQLLogSink?.write(LogPrivacy.project(diagnostic.metadata,
              allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: source))
          }
        }
        throw failure.cause
      }
    }
    let result: QueryResult
    if let execution = idSetPrepared.execution {
      let order = Dictionary(uniqueKeysWithValues: execution.pageIds.enumerated().map { ($0.element, $0.offset) })
      let records = rawResult.records.filter { row in
        row["id"]?.int64Value.map { order[$0] != nil } ?? false
      }.sorted { left, right in
        order[left["id"]!.int64Value!]! < order[right["id"]!.int64Value!]!
      }
      result = QueryResult(
        records: records, backend: rawResult.backend, trace: rawResult.trace,
        metadata: rawResult.metadata, facets: rawResult.facets)
    } else {
      result = rawResult
    }
    if let metadata = result.metadata {
      await telemetrySink?.record(LogPrivacy.project(metadata, intentSource: invocationIntent))
      if querySQLLogEnabled { await diagnosticSQLLogSink?.write(LogPrivacy.project(metadata,
        allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: invocationIntent)) }
    }
    await registerContinuousPage(prepared.execution, rows: result.records)
    // Capture just the requested assembly key, in the final provider row order,
    // before a to-one load can replace it (including replacement with null).
    let attachmentKeys = attachmentKey.map { key in result.records.map { $0[key] ?? .null } } ?? []
    var facets: [String: SmartList<TeaQLRecord>] = [:]
    for facet in validated.facets {
      var membership = validated
      membership.facets = []
      membership.relations = []
      membership.relationAggregates = []
      membership.orderBy = []
      membership.offset = 0
      membership.limit = nil
      membership.projection = [facet.relationName]
      let membershipRows = try await execute(request.withQuery(membership), inheritedIntent: invocationIntent).records
      var counts: [TeaQLValue: Int64] = [:]
      for row in membershipRows {
        guard let value = row[facet.relationName], value != .null else { continue }
        counts[normalizedRelationIdentity(value), default: 0] += 1
      }

      var child = facet.query.makeQuery()
      child.tracePath = validated.tracePath + [TraceNode(
        entity: child.entity.name, comment: "\(validated.entity.name).\(facet.relationName)",
        purpose: "", level: validated.tracePath.count + 2,
        kind: "relation", name: facet.relationName)]
      child.comment = validated.comment
      child.purpose = validated.purpose
      let childResult = try await execute(request.withQuery(child), inheritedIntent: invocationIntent)
      var childRows = childResult.records.map { row in
        var copy = row
        if let id = row["id"] {
          copy["count"] = .int(counts[normalizedRelationIdentity(id)] ?? 0)
        }
        return copy
      }
      if !facet.includeAllFacets {
        childRows.removeAll { row in
          guard let id = row["id"] else { return true }
          return counts[normalizedRelationIdentity(id)] == nil
        }
      }
      facets[facet.name] = SmartList(childRows, facets: childResult.facets)
    }

    guard (!validated.relations.isEmpty || !validated.relationAggregates.isEmpty),
      !result.records.isEmpty else {
      return QueryResult(
        records: result.records, backend: result.backend, trace: result.trace,
        metadata: result.metadata, facets: facets).attachingRelationKeys(attachmentKeys)
    }

    var records = result.records
    let childIntent = LogPrivacy.inheritIntent(result.metadata, inherited: invocationIntent)
    for aggregate in validated.relationAggregates {
      guard let parentID = validated.entity.idProperty else {
        throw TeaQLError.unknownProperty(entity: validated.entity.name, property: "id")
      }
      let parentIDs = records.compactMap { $0[parentID.name] }
      guard !parentIDs.isEmpty else { continue }
      var child = aggregate.query.makeQuery()
      child.tracePath = validated.tracePath + [TraceNode(
        entity: child.entity.name, comment: "\(validated.entity.name).\(aggregate.relationName)",
        purpose: "", level: validated.tracePath.count + 2,
        kind: "relation", name: aggregate.relationName)]
      guard let foreignKey = child.entity.property(named: aggregate.foreignKey) else {
        throw TeaQLError.unknownProperty(
          entity: child.entity.name, property: aggregate.foreignKey)
      }
      if child.aggregates.isEmpty {
        child.aggregates = [QueryAggregate(.count, field: "*", alias: aggregate.alias)]
      }
      let valueAlias = child.aggregates.first?.alias ?? aggregate.alias
      child.groupBy = [foreignKey.name]
      child.projection = []
      child.orderBy = []
      child.offset = 0
      child.limit = nil
      child.relations = []
      child.relationAggregates = []
      child.comment = validated.comment
      child.purpose = validated.purpose
      let membership = TeaQLExpression.inList(foreignKey.name, parentIDs)
      child.filter = child.filter.map { .and([$0, membership]) } ?? membership
      let rows = try await execute(request.withQuery(child), inheritedIntent: childIntent).records
      let pairs: [(TeaQLValue, TeaQLValue)] = rows.compactMap { row in
        guard let key = row[foreignKey.name], let value = row[valueAlias] else { return nil }
        return (normalizedRelationIdentity(key), value)
      }
      let values: [TeaQLValue: TeaQLValue] = Dictionary(uniqueKeysWithValues: pairs)
      let emptyValue: TeaQLValue = child.aggregates.first?.function == .count ? .int(0) : .null
      for index in records.indices {
        guard let id = records[index][parentID.name] else { continue }
        records[index][aggregate.alias] = values[normalizedRelationIdentity(id)] ?? emptyValue
      }
    }
    for relation in validated.relations {
      // A preceding relation may replace a scalar field with its loaded object.
      // Membership belongs to the provider snapshot, not the mutable output graph.
      let relationParentCount = result.records.compactMap { $0[relation.localKey] }.count
      let relationThreshold = relation.query.topNProbeParentThreshold
      let relationLimited = relation.query.limit != nil
      let relationAlwaysProbe =
        (queryExecutor as? any RelationTopNPlanning)?.relationTopNPolicy == .alwaysProbe
      let relationUsesProbes = relationLimited && ((relationAlwaysProbe && relationThreshold == nil)
        || (relationThreshold.map { $0 > 0 && relationParentCount <= $0 } ?? false))
      try await runtimeTelemetry.withOperation(
        RuntimeOperation(
          family: "relation_load", name: "\(validated.entity.name).\(relation.name)",
          attributes: [
            "teaql.entity.type": .string(validated.entity.name),
            "teaql.relation.name": .string(relation.name),
          ]
        ), completion: { _ in
          return [
            "teaql.relation.parent_count": .integer(Int64(relationParentCount)),
            "teaql.relation.per_parent_limit": .integer(Int64(relation.query.limit ?? 0)),
            "teaql.relation.configured_probe_threshold": .integer(Int64(relationThreshold ?? -1)),
            "teaql.relation.selected_plan": .string(relationUsesProbes ? "bounded_probes" : relationLimited ? "window" : "batch"),
            "teaql.relation.probe_count": .integer(Int64(relationUsesProbes ? relationParentCount : 0)),
          ]
        }
      ) {
        let localValues = result.records.compactMap { $0[relation.localKey] }
        guard !localValues.isEmpty else { return }
        var child = relation.query.makeQuery()
        child.tracePath = validated.tracePath + [TraceNode(
          entity: child.entity.name, comment: "\(validated.entity.name).\(relation.traceName ?? relation.name)",
          purpose: "", level: validated.tracePath.count + 2,
          kind: "relation", name: relation.traceName ?? relation.name)]
        // Relation assembly groups child rows by the foreign key. A generated
        // child projection may select only business fields, so the runtime must
        // retain this structural key even when the caller did not request it.
        if !child.projection.isEmpty && !child.projection.contains(relation.foreignKey) {
          child.projection.append(relation.foreignKey)
        }
        child.comment = validated.comment
        child.purpose = validated.purpose
        if child.limit != nil,
          !child.orderBy.contains(where: { $0.field == (child.entity.properties.first(where: { $0.isID })?.name ?? "id") })
        {
          child.orderBy.append(OrderBy(child.entity.properties.first(where: { $0.isID })?.name ?? "id", .ascending))
        }
        let threshold = child.topNProbeParentThreshold
        let alwaysProbe = (queryExecutor as? any RelationTopNPlanning)?.relationTopNPolicy == .alwaysProbe
        let useProbes = child.limit != nil && ((alwaysProbe && threshold == nil)
          || (threshold.map { $0 > 0 && localValues.count <= $0 } ?? false))
        var children: [TeaQLRecord] = []
        var childKeys: [TeaQLValue] = []
        if useProbes {
          for localValue in localValues {
            var probe = child
            probe.partitionBy = nil
            let join = TeaQLExpression.equal(relation.foreignKey, localValue)
            probe.filter = probe.filter.map { .and([$0, join]) } ?? join
            let loaded = try await execute(request.withQuery(probe), inheritedIntent: childIntent,
              attachmentKey: relation.foreignKey)
            children.append(contentsOf: loaded.records)
            childKeys.append(contentsOf: loaded.relationAttachmentKeys)
          }
        } else {
          if child.limit != nil { child.partitionBy = relation.foreignKey }
          let join = TeaQLExpression.inList(relation.foreignKey, localValues)
          child.filter = child.filter.map { .and([$0, join]) } ?? join
          let loaded = try await execute(request.withQuery(child), inheritedIntent: childIntent,
            attachmentKey: relation.foreignKey)
          children = loaded.records
          childKeys = loaded.relationAttachmentKeys
        }
        guard childKeys.count == children.count else {
          throw TeaQLError.execution("Relation assembly key count differs from row count")
        }
        var grouped: [TeaQLValue: [TeaQLRecord]] = [:]
        for (key, row) in zip(childKeys, children) {
          grouped[normalizedRelationIdentity(key), default: []].append(row)
        }
        for index in records.indices {
          let key = normalizedRelationIdentity(result.records[index][relation.localKey] ?? .null)
          let matches = grouped[key] ?? []
          records[index][relation.name] = relation.many
            ? .array(matches.map(TeaQLValue.object))
            : matches.first.map(TeaQLValue.object) ?? .null
        }
      }
    }
    return QueryResult(
      records: records, backend: result.backend, trace: result.trace,
      metadata: result.metadata, facets: facets).attachingRelationKeys(attachmentKeys)
  }

  private func queryIntentProvenance(_ request: QueryRequest) async throws -> SQLExecutionMetadata? {
    guard let provider = queryExecutor as? any QueryIntentProvenanceExecutor else { return nil }
    var source: SQLExecutionMetadata? = try await provider.queryIntentProvenance(request)
    let query = request.query
    let children = query.relations.map { $0.query.makeQuery() }
      + query.relationAggregates.map { $0.query.makeQuery() }
      + query.facets.map { $0.query.makeQuery() }
    for child in children {
      source = LogPrivacy.inheritIntent(
        try await queryIntentProvenance(request.withQuery(child)), inherited: source)
    }
    return source
  }

  private func prepareIdSetPagination(
    _ query: SelectQuery
  ) async throws -> (query: SelectQuery, execution: IdSetExecution?) {
    guard let options = query.idSetPagination else {
      await idSetObservationState.observe("ID_SET_DISABLED")
      return (query, nil)
    }
    guard let limit = query.limit, limit > 0, query.aggregates.isEmpty,
      query.groupBy.isEmpty, query.partitionBy == nil
    else {
      await idSetObservationState.observe("ID_SET_FALLBACK_UNSUPPORTED_SHAPE")
      var fallback = query; fallback.idSetPagination = nil
      return (fallback, nil)
    }
    let idField = query.entity.idProperty?.name ?? "id"
    var stable = query
    if !stable.orderBy.contains(where: { $0.field == idField }) {
      stable.orderBy.append(OrderBy(idField, .ascending))
    }
    var normalized = stable
    normalized.offset = 0; normalized.limit = nil; normalized.projection = []
    normalized.relations = []; normalized.relationAggregates = []; normalized.facets = []
    normalized.comment = nil; normalized.purpose = nil
    normalized.idSetPagination = nil; normalized.continuousPage = nil
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(normalized)
    let security = "\(actor ?? "")|\(trustedTenant ?? "")|\(activeRoot.map { "\($0.entity):\($0.id)" } ?? "")|\(requestPolicy.idSetIdentity)|\(queryExecutor.idSetDataSourceIdentity)"
    let key = "teaql:id-set:v1:\(options.namespace):\(security):\(encoded.base64EncodedString())"
    let stableSnapshot = stable
    do {
      let (retained, built) = try await idSetStore.obtain(key: key) {
        var idQuery = stableSnapshot
        idQuery.offset = 0
        idQuery.limit = options.maxIds == Int.max ? Int.max : options.maxIds + 1
        idQuery.projection = [idField]
        idQuery.relations = []; idQuery.relationAggregates = []; idQuery.facets = []
        idQuery.idSetPagination = nil; idQuery.continuousPage = nil
        let result = try await queryExecutor.execute(idQuery)
        let ids = result.records.compactMap { $0[idField]?.int64Value }
        guard ids.count <= options.maxIds else {
          throw IdSetBuildError.limitExceeded(ids.count)
        }
        return RetainedIdSet(
          ids: ids, expiresAt: Date().addingTimeInterval(TimeInterval(options.ttlSeconds)))
      }
      await idSetObservationState.observe(
        built ? "ID_SET_BUILD" : "ID_SET_HIT", count: retained.ids.count, accuracy: "EXACT")
      let pageIds = Array(retained.ids.dropFirst(query.offset).prefix(limit))
      var page = query
      page.offset = 0; page.limit = nil
      page.idSetPagination = nil; page.continuousPage = nil
      let membership = TeaQLExpression.inList(idField, pageIds.map(TeaQLValue.int))
      page.filter = page.filter.map { .and([$0, membership]) } ?? membership
      return (page, IdSetExecution(pageIds: pageIds))
    } catch IdSetBuildError.limitExceeded(let count) {
      await idSetObservationState.observe(
        "ID_SET_FALLBACK_LIMIT_EXCEEDED", count: count, accuracy: "LOWER_BOUND")
      var fallback = query; fallback.idSetPagination = nil
      return (fallback, nil)
    } catch {
      await idSetObservationState.observe("ID_SET_FALLBACK_STORE_UNAVAILABLE")
      var fallback = query; fallback.idSetPagination = nil
      return (fallback, nil)
    }
  }

  private func prepareContinuousPage(
    _ query: SelectQuery
  ) async -> (query: SelectQuery, execution: ContinuousPageExecution?) {
    guard let options = query.continuousPage else {
      await continuousPageState.observe("DISABLED")
      return (query, nil)
    }
    guard let limit = query.limit, query.orderBy.count == 1,
      query.orderBy[0].field == (query.entity.idProperty?.name ?? "id"),
      query.aggregates.isEmpty, query.groupBy.isEmpty, query.partitionBy == nil
    else {
      await continuousPageState.observe("OFFSET_FALLBACK:UNSUPPORTED_QUERY_SHAPE")
      return (query, nil)
    }
    var normalized = query
    normalized.offset = 0
    normalized.comment = nil
    normalized.purpose = nil
    normalized.continuousPage = nil
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(normalized)) ?? Data()
    let key = "teaql:continuous-page:v1:\(options.namespace):\(encoded.base64EncodedString())"
    if query.offset == 0 {
      await continuousPageState.observe("OFFSET_FALLBACK:FIRST_PAGE")
      return (query, ContinuousPageExecution(
        queryKey: key, originalOffset: 0, limit: limit, ttlSeconds: options.ttlSeconds,
        optimized: false, cursorID: nil))
    }
    guard let cursor = await continuousPageState.cursor(queryKey: key, offset: query.offset) else {
      await continuousPageState.observe("OFFSET_FALLBACK:CACHE_MISS")
      return (query, ContinuousPageExecution(
        queryKey: key, originalOffset: query.offset, limit: limit,
        ttlSeconds: options.ttlSeconds, optimized: false, cursorID: nil))
    }
    var seek = query
    seek.offset = 0
    let condition: TeaQLExpression = query.orderBy[0].direction == .descending
      ? .lessThan(query.orderBy[0].field, cursor.boundary)
      : .greaterThan(query.orderBy[0].field, cursor.boundary)
    seek.filter = seek.filter.map { .and([$0, condition]) } ?? condition
    await continuousPageState.observe("CURSOR_SEEK", cursorID: cursor.id)
    return (seek, ContinuousPageExecution(
      queryKey: key, originalOffset: query.offset, limit: limit,
      ttlSeconds: options.ttlSeconds, optimized: true, cursorID: cursor.id))
  }

  private func registerContinuousPage(
    _ execution: ContinuousPageExecution?, rows: [TeaQLRecord]
  ) async {
    guard let execution, rows.count == execution.limit,
      let boundary = rows.last?["id"], boundary != .null else { return }
    await continuousPageState.put(
      queryKey: execution.queryKey, offset: execution.originalOffset + rows.count,
      cursor: ContinuousPageCursor(
        id: "cpg_\(UUID().uuidString.lowercased())", boundary: boundary,
        expiresAt: Date().addingTimeInterval(TimeInterval(execution.ttlSeconds))))
    if execution.optimized {
      await continuousPageState.observe("CURSOR_SEEK", cursorID: execution.cursorID)
    }
  }

  private func normalizedRelationIdentity(_ value: TeaQLValue) -> TeaQLValue {
    if let signed = value.int64Value { return .int(signed) }
    return value
  }

  public func count(_ query: SelectQuery) async throws -> Int {
    try await count(QueryRequest(query: query))
  }

  public func count(_ request: QueryRequest) async throws -> Int {
    var validated = try request.withQuery(requestPolicy.apply(request.query)).query.validatedForExecution()
    // Count strips eager loads, not the original invocation's redaction sources.
    let invocationIntent = try await queryIntentProvenance(request.withQuery(validated))
    validated.orderBy = []
    validated.offset = 0
    validated.limit = nil
    validated.projection = []
    validated.relations = []
    validated.relationAggregates = []
    validated.partitionBy = nil
    return try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "provider", name: "\(queryExecutor.providerKind).count",
        attributes: [
          "teaql.provider.kind": .string(queryExecutor.providerKind),
          "teaql.provider.operation": .string("count"),
        ]
      )
    ) {
      if let diagnosed = queryExecutor as? any SQLCountDiagnosticExecutor {
        do {
          let result = try await diagnosed.countDiagnosed(request.withQuery(validated))
          await telemetrySink?.record(LogPrivacy.project(result.metadata, intentSource: invocationIntent))
          if querySQLLogEnabled {
            await diagnosticSQLLogSink?.write(LogPrivacy.project(result.metadata,
              allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: invocationIntent))
          }
          return result.count
        } catch let failure as SQLExecutionFailure {
          for diagnostic in failure.diagnostics {
            let source = LogPrivacy.inheritIntent(diagnostic.intentSource, inherited: invocationIntent)
            await telemetrySink?.record(LogPrivacy.project(diagnostic.metadata, intentSource: source))
            if querySQLLogEnabled {
              await diagnosticSQLLogSink?.write(LogPrivacy.project(diagnostic.metadata,
                allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: source))
            }
          }
          throw failure.cause
        }
      }
      return try await queryExecutor.count(request.withQuery(validated))
    }
  }

  public func execute(_ mutation: Mutation) async throws -> MutationResult {
    try await execute(MutationRequest(mutation: mutation))
  }

  public func execute(_ request: MutationRequest) async throws -> MutationResult {
    try await execute(request.mutation, ledgerRoot: nil, ledgerKey: nil)
  }

  /// The provider cannot execute a naked child array. One validated root owns
  /// preflight, invocation-local privacy, atomic execution and committed audit.
  public func execute(_ request: MutationBatchRequest) async throws -> [MutationResult] {
    let mutations = request.mutations
    guard !mutations.isEmpty else { return [] }
    return try await executeGraphSave(comment: request.intent.comment) { context, _ in
      for mutation in mutations { _ = try context.preflightMutation(mutation) }
      var results: [MutationResult] = []
      results.reserveCapacity(mutations.count)
      for mutation in mutations { results.append(try await context.execute(mutation)) }
      return results
    }
  }

  public func execute(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) async throws -> MutationResult {
    let request = try MutationRequest(mutation: mutation)
    let standalone = graphSession == nil
    if standalone {
      guard !GraphTransactionGate.Reentry.active.contains(graphTransactionGate.id) else {
        throw TeaQLError.execution("Mutation cannot implicitly enter another graph; use its explicit invocation context")
      }
      await graphTransactionGate.acquire()
    }
    defer { if standalone { graphTransactionGate.release(evidence: graphTransactionGate.lastFixEvidence) } }
    return try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "mutation", name: "\(mutation.entity.name).\(mutation.kind.rawValue)",
        attributes: [
          "teaql.entity.type": .string(mutation.entity.name),
          "teaql.mutation.kind": .string(mutation.kind.rawValue),
        ]
      )
    ) {
      try await executeMutation(request.mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    }
  }

  private func executeMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) async throws -> MutationResult {
    try graphSession?.ensureActive()
    let validated = try checkAndFixMutation(
      mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    let oldProvenance = LogPrivacy.loadedMutationSource(validated)
    let invocationProvenance = LogPrivacy.inheritIntent(oldProvenance, inherited: graphSession?.intentProvenance)
    let mutationGovernance = try mutationPolicyCoordinator.enter(
      context: self, mutation: validated, ledgerKey: ledgerKey)
    let submittedID = validated.id
      ?? validated.entity.idProperty.flatMap { validated.values[$0.name] }
    let result = try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "provider", name: "\(mutationExecutor.providerKind).mutation",
        attributes: [
          "teaql.provider.kind": .string(mutationExecutor.providerKind),
          "teaql.provider.operation": .string(validated.kind.rawValue),
        ]
      )
    ) {
      do {
        if let diagnosed = mutationExecutor as? any SQLDiagnosticExecutor {
          return try await diagnosed.executeDiagnosed(validated)
        }
        return try await mutationExecutor.execute(validated)
      } catch let failure as SQLExecutionFailure {
        for diagnostic in failure.diagnostics {
          let source = LogPrivacy.inheritIntent(diagnostic.intentSource, inherited: invocationProvenance)
          await telemetrySink?.record(LogPrivacy.project(diagnostic.metadata,
            intentSource: source, intentValues: submittedID.map { [$0] } ?? []))
          if diagnostic.metadata.operation == .select ? querySQLLogEnabled : mutationSQLLogEnabled {
            await diagnosticSQLLogSink?.write(LogPrivacy.project(diagnostic.metadata,
              allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: source,
              intentValues: submittedID.map { [$0] } ?? []))
          }
        }
        throw failure.cause
      }
    }
    let auditID = validated.id ?? result.generatedValues["id"]
      ?? validated.entity.idProperty.flatMap { validated.values[$0.name] }
    if let metadata = result.metadata {
      let source = LogPrivacy.inheritIntent(metadata, inherited: invocationProvenance)
      for statement in metadata.statements.isEmpty ? [metadata] : metadata.statements {
        await telemetrySink?.record(LogPrivacy.project(statement,
          intentSource: source, intentValues: auditID.map { [$0] } ?? []))
        if statement.operation == .select ? querySQLLogEnabled : mutationSQLLogEnabled {
          await diagnosticSQLLogSink?.write(LogPrivacy.project(statement,
            allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: source,
            intentValues: auditID.map { [$0] } ?? []))
        }
      }
    }
    if result.affectedRows > 0, let auditSink, let reason = validated.auditReason {
      let auditValues = Array(validated.values.values) + (auditID.map { [$0] } ?? [])
        + LogPrivacy.privateValues(oldProvenance)
      try await runtimeTelemetry.withOperation(
        RuntimeOperation(
          family: "audit", name: "\(validated.entity.name).event",
          attributes: [
            "teaql.entity.type": .string(validated.entity.name),
            "teaql.mutation.kind": .string(validated.kind.rawValue),
            "teaql.audit.changed_field_count": .integer(Int64(validated.values.count)),
          ]
        )
      ) {
        let lineage = auditID.map {
          TraceChain.assignedLineage(validated.mutationLineage ?? [], key: EntityKey(entity: validated.entity.name, id: $0))
        } ?? validated.mutationLineage ?? []
        let event = AuditEvent(
            entity: validated.entity.name,
            entityID: auditID,
            operation: validated.kind,
            reason: reason,
            actor: actor,
            category: auditCategory,
            occurredAt: fixTime,
            mutationGovernance: mutationGovernance,
            mutationLineage: lineage)
        if let graphSession { try graphSession.bufferAudit(event, values: auditValues) }
        else {
          try await auditSink.record(AuditEvent(entity: event.entity, entityID: event.entityID,
            operation: event.operation, reason: LogPrivacy.scrub(reason, values: auditValues),
            actor: event.actor, category: event.category, occurredAt: event.occurredAt,
            mutationGovernance: event.mutationGovernance,
            mutationLineage: TraceChain.maskLineage(lineage, values: auditValues)))
        }
      }
    }
    return result
  }

  public func preflightMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot? = nil, ledgerKey: EntityKey? = nil
  ) throws -> Mutation {
    let validated = try checkAndFixMutation(
      mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    try mutationPolicyCoordinator.recordPreflight(validated, ledgerKey: ledgerKey)
    graphSession?.recordProvenance(Array(validated.values.values))
    graphSession?.recordLoadedProvenance(LogPrivacy.loadedMutationSource(validated))
    return validated
  }

  private func checkAndFixMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) throws -> Mutation {
    let request = try MutationRequest(mutation: mutation)
    var validated = request.mutation
    validated.actor = actor
    validated.auditCategory = auditCategory
    if let checker = runtime.checker(named: validated.entity.name) {
      let violations = translateCheckResults(
        try checker.checkAndFix(context: self, mutation: &validated, now: fixTime))
      if let ledgerRoot, let ledgerKey {
        for (field, value) in validated.values {
          ledgerRoot.set(ledgerKey, field: field, value: value)
        }
      }
      if !violations.isEmpty { throw CheckException(violations) }
    }
    return request.withMutation(validated).mutation
  }
}
