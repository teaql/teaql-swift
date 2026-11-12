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

public struct CheckException: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
  public let violations: [CheckResult]
  public init(_ violations: [CheckResult]) { self.violations = violations.map { CheckerPrivacy.project($0) } }
  public var description: String { "CheckException(violations: [" + violations.map(\.description).joined(separator: ", ") + "])" }
  public var debugDescription: String { description }
  public var errorDescription: String? { description }
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
  package var isSafeProjection = false
  package private(set) var telemetryCorrelation: SQLTelemetryCorrelation?
  package func withTelemetryCorrelation(_ correlation: SQLTelemetryCorrelation?) -> Self {
    var result = self
    result.telemetryCorrelation = correlation
    return result
  }
  public let operation: SQLExecutionOperation
  public let comment: String?
  public let purpose: String?
  public let auditReason: String?
  public let tracePath: [TraceNode]
  public let traceChain: [TraceNode]
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
    traceChain: [TraceNode] = [],
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
    self.traceChain = traceChain
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
      + "traceChain=\(metadata.traceChain) tracePath=\(metadata.tracePath) parameterCount=\(metadata.parameters.count)\n"
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
    try MutationVersion.validate(self)
    try CanonicalMutationFields.validate(values, entity: entity)
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
    try validateLoadedIdentity()
    LoadedScalarRestoration.discardRestoredFields(of: entity)
    guard try validateVersion() else { return entity }
    return try await context.executeGraphSave(comment: reason, rootEntityType: Entity.descriptor.name, preparing: { graphContext, _ in
      try preflight(graphContext)
    }) { graphContext, session in
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
    try validateLoadedIdentity(rooted: rooted)
    LoadedScalarRestoration.discardRestoredFields(of: entity)
    if let rooted, (entity.version != 0 || rooted.teaqlLoadedSnapshot != nil),
      !rooted.teaqlEntityRoot.hasPending(rooted.teaqlEntityKey) { return }
    _ = try context.preflightMutation(
      makeMutation(rooted: rooted),
      ledgerRoot: rooted?.teaqlEntityRoot,
      ledgerKey: rooted?.teaqlEntityKey, loadedSnapshot: rooted?.teaqlLoadedSnapshot)
  }

  /// Generator bridge for a complete input-graph pass before its first Fix.
  /// No Checker, policy, clock, ID allocator or provider is invoked here.
  @discardableResult
  public func validateVersion() throws -> Bool {
    let rooted = entity as? any TeaQLMutationRootedEntity
    try validateLoadedIdentity(rooted: rooted)
    if let rooted, (entity.version != 0 || rooted.teaqlLoadedSnapshot != nil),
      !rooted.teaqlEntityRoot.hasPending(rooted.teaqlEntityKey) { return false }
    _ = try makeMutation(rooted: rooted).validatedForExecution()
    return true
  }

  /// Generated traversal uses the explicitly supplied session; it must not
  /// start another public save and silently join an unrelated root.
  public func saveInGraph(_ context: UserContext, session: GraphMutationSession,
                          scope: TraceScopeToken) async throws -> Entity {
    try context.requireGraphSession(session)
    let rooted = entity as? any TeaQLMutationRootedEntity
    try validateLoadedIdentity(rooted: rooted)
    if let rooted, (entity.version != 0 || rooted.teaqlLoadedSnapshot != nil),
      !rooted.teaqlEntityRoot.hasPending(rooted.teaqlEntityKey) {
      if session.preparedMutations.wasNormalized(ledger: rooted.teaqlEntityRoot, key: rooted.teaqlEntityKey) {
        return try Entity.from(record: session.readback().scalarRecord(for: entity))
      }
      return entity
    }
    var mutation = try makeMutation(rooted: rooted)
    mutation.auditReason = session.intent.auditReason
    mutation.mutationLineage = rooted.map { $0.teaqlEntityRoot.traceChain($0.teaqlEntityKey, fallback: scope) }
      ?? scope.recover()
    let pending = rooted.map { $0.teaqlEntityRoot.mutationSnapshot($0.teaqlEntityKey) }
    let saved = try persistedEntity(from: await context.execute(
      mutation, ledgerRoot: rooted?.teaqlEntityRoot, ledgerKey: rooted?.teaqlEntityKey))
    if let rooted, let pending {
      let originalKey = rooted.teaqlEntityKey
      let savedKey = EntityKey(entity: rooted.teaqlEntityKey.entity, id: .int(saved.id))
      let root = rooted.teaqlEntityRoot
      try session.afterCommit {
        try root.completeCommit(originalKey, to: savedKey, expected: pending, version: saved.version)
      }
    }
    return saved
  }

  /// A generated read-only graph pass uses this before relation normalization.
  /// A harmless old read view may outlive its ledger version; it must still
  /// retain its own immutable loaded identity, even when it has no write intent.
  @_spi(Generated) public func validateLoadedIdentity() throws {
    try validateLoadedIdentity(rooted: entity as? any TeaQLMutationRootedEntity)
  }

  private func validateLoadedIdentity(rooted: (any TeaQLMutationRootedEntity)?) throws {
    if let rooted, let snapshot = rooted.teaqlLoadedSnapshot,
      snapshot.key != rooted.teaqlEntityKey || snapshot.version != entity.version {
      throw TeaQLError.execution("ENTITY_VERSION_CONFLICT: \(Entity.descriptor.name) must retain its loaded identity and version")
    }
  }

  private func makeMutation(rooted: (any TeaQLMutationRootedEntity)?) throws -> Mutation {
    try validateLoadedIdentity(rooted: rooted)
    // A sparse decoded/read view may omit version. It stays inert when
    // unchanged, but editing it must never turn version zero into INSERT.
    // Even a caller-supplied markAsNew cannot erase its loaded provenance.
    if Entity.descriptor.versionProperty != nil, let rooted,
      let snapshot = rooted.teaqlLoadedSnapshot, snapshot.version == 0,
      !(snapshot.origin == .creationBaseline && rooted.teaqlEntityRoot.isNew(rooted.teaqlEntityKey)) {
      throw EntityCreationError(entityType: Entity.descriptor.name)
    }
    if let rooted {
      let key = rooted.teaqlEntityKey
      // New entities may still have ID zero and use their complete scalar
      // record below. Never lose malformed raw ledger input at that boundary.
      try CanonicalMutationFields.validate(rooted.teaqlEntityRoot.change(key), entity: Entity.descriptor)
      // A successful save advances this graph's ledger, not every Swift value
      // copy that once shared it. Only the authoritative returned snapshot may
      // use that newer version; never implicitly rebase an old dirty struct.
      let version = rooted.teaqlEntityRoot.originalVersion(key)
      if version.map({ $0 != entity.version }) == true {
        throw TeaQLError.execution("ENTITY_VERSION_CONFLICT: \(Entity.descriptor.name) must retain its loaded identity and version")
      }
    }
    var values = pendingMutationRecord(entity, rooted: rooted)
    let originalVersion = rooted.flatMap { $0.teaqlEntityRoot.originalVersion($0.teaqlEntityKey) } ?? entity.version
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
    } else if entity.version == 0 || rooted.map({ $0.teaqlEntityRoot.isNew($0.teaqlEntityKey) }) == true {
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

private struct ListExecutionOwner: Sendable {
  let context: UUID
  let root: QueryRequestScope
  let authorized: QueryRequestScope
}

private enum ListExecutionState {
  @TaskLocal static var owner: ListExecutionOwner?
}

public struct UserContext: Sendable {
  var objectStorageProvider: (any ObjectStorageProvider)?
  var objectStorageObserver: ObjectStorageObserver?
  var objectStorageContextID: String { graphTransactionGate.id.uuidString }
  // The existing per-Context gate already supplies a stable private identity.
  // Reuse identity only, not its mutation state/lock; avoid changing value layout.
  private var queryExecutionContext: UUID { graphTransactionGate.id }
  public let runtime: TeaQLRuntime
  public let actor: String?
  public let auditCategory: String?
  /// Application-owned tenant identity. It is never populated from generated
  /// query or federation payloads.
  public let trustedTenant: String?
  public let activeRoot: ContextEntityRef?
  public private(set) var queryExecutor: any QueryExecutor
  public private(set) var mutationExecutor: any MutationExecutor
  public let requestPolicy: RequestPolicy
  public let auditSink: (any AuditSink)?
  public let telemetrySink: (any RuntimeTelemetrySink)?
  public let diagnosticSQLLogSink: (any DiagnosticSQLLogSink)?
  public var querySQLLogEnabled: Bool
  public var mutationSQLLogEnabled: Bool
  public let runtimeTelemetry: any RuntimeTelemetry
  public private(set) var locale: TeaQLLocale
  public private(set) var i18nCatalog: I18nCatalog
  private var checkerMessages: CheckerMessageServices
  private var checkerMessageConfiguration: CheckerMessageConfiguration {
    graphSession?.checkerConfiguration ?? CheckerMessageConfiguration(services:checkerMessages,locale:locale,legacy:i18nCatalog)
  }
  private let entityInitializers: [EntityInitializer]
  private let entityCreationObserver: EntityCreationObserver?
  private let internalIDGenerator: (any InternalIDGenerator)?
  private let continuousPageState: ContinuousPageState
  private let idSetObservationState: IdSetObservationState
  private let idSetStore: any IdSetStore
  private let graphTransactionGate: GraphTransactionGate
  private var graphSession: GraphMutationSession?
  private var standaloneFixInvocation: StandaloneFixInvocation?
  package var contextFixFrame: ContextFixFrame?
  public var contextFixResolver: (any ContextFixResolver)?
  private var mutationPolicyCoordinator: MutationPolicyCoordinator
  public let businessClock: any BusinessClock
  public var businessTime: Date { businessClock.now() }
  public var businessDate: Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.startOfDay(for: businessTime)
  }

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
    runtimeTelemetry: any RuntimeTelemetry = RuntimeTelemetryStartup.defaultTelemetry(),
    idSetStore: any IdSetStore = InMemoryIdSetStore.shared,
    locale: TeaQLLocale = .en,
    i18nCatalog: I18nCatalog = .builtin,
    entityInitializers: [EntityInitializer] = [],
    entityCreationObserver: EntityCreationObserver? = nil,
    mutationPolicyRegistry: (any MutationPolicyRegistry)? = nil,
    mutationPolicyApprovalProvider: (any MutationPolicyApprovalProvider)? = nil,
    mutationGovernanceSink: (any MutationGovernanceSink)? = nil,
    objectStorageProvider: (any ObjectStorageProvider)? = nil,
    objectStorageObserver: ObjectStorageObserver? = nil,
    businessClock: any BusinessClock = SystemBusinessClock(),
    internalIDGenerator: (any InternalIDGenerator)? = nil,
    contextFixResolver: (any ContextFixResolver)? = nil
  ) {
    self.runtime = runtime
    self.businessClock = businessClock
    self.objectStorageProvider = objectStorageProvider
    self.objectStorageObserver = objectStorageObserver
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
    self.checkerMessages = CheckerMessageServices(model:runtime.checkerPresentation)
    self.entityInitializers = entityInitializers
    self.entityCreationObserver = entityCreationObserver
    self.internalIDGenerator = internalIDGenerator
    self.contextFixResolver = contextFixResolver
    self.contextFixFrame = nil
    self.continuousPageState = ContinuousPageState()
    self.idSetObservationState = IdSetObservationState()
    self.graphTransactionGate = GraphTransactionGate()
    self.graphSession = nil
    self.standaloneFixInvocation = nil
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
    try await executeGraphSave(request, rootEntityType: nil, preparation: nil, operation)
  }

  /// Generated traversal prepares the complete reachable graph under the same
  /// queue, session and captured clock, before transaction or provider entry.
  public func executeGraphSave<T: Sendable>(
    comment: String,
    rootEntityType: String? = nil,
    preparing: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> Void,
    _ operation: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> T
  ) async throws -> T {
    try await executeGraphSave(GraphMutationRequest(comment: comment), rootEntityType: rootEntityType,
      preparation: preparing, operation)
  }

  private func executeGraphSave<T: Sendable>(
    _ request: GraphMutationRequest,
    rootEntityType: String?,
    preparation: (@Sendable (UserContext, GraphMutationSession) async throws -> Void)?,
    _ operation: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> T
  ) async throws -> T {
    guard graphSession == nil, standaloneFixInvocation == nil,
      !GraphTransactionGate.Reentry.active.contains(graphTransactionGate.id) else {
      throw TeaQLError.execution("Independent graph save cannot implicitly join an active graph; pass its explicit session for composed children")
    }
    guard let transaction = mutationExecutor as? any GraphTransactionExecutor else {
      throw TeaQLError.execution("The configured mutation provider does not support atomic graph saves")
    }
    await graphTransactionGate.acquire()
    // The runtime owns the graph boundary, including transaction completion
    // and post-commit audit delivery. Individual entity operations remain its
    // children; applications and generated libraries need no SDK calls.
    return try await runtimeTelemetry.withOperation(RuntimeOperation(family: "mutation", name: "graph.save")) {
      try await executeGraphTransaction(request, transaction: transaction, rootEntityType: rootEntityType,
        preparation: preparation, operation)
    }
  }

  private func executeGraphTransaction<T: Sendable>(
    _ request: GraphMutationRequest, transaction: any GraphTransactionExecutor,
    rootEntityType: String?,
    preparation: (@Sendable (UserContext, GraphMutationSession) async throws -> Void)?,
    _ operation: @escaping @Sendable (UserContext, GraphMutationSession) async throws -> T
  ) async throws -> T {
    let policy = mutationPolicyCoordinator.fork()
    let session = GraphMutationSession(intent: request.intent, policy: policy, fixTime: businessTime,
      checkerConfiguration:checkerMessageConfiguration,checkerOrigin:rootEntityType)
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
      try Task.checkCancellation()
      try policy.beginGraph(auditReason: request.intent.auditReason, rootEntity: rootEntityType)
      if let preparation {
        try session.beginPreparation()
        var guarded = graphContext
        let denied = GraphPreparationExecutor()
        guarded.queryExecutor = denied
        guarded.mutationExecutor = denied
        let preparingContext = guarded
        try await GraphTransactionGate.Reentry.$active.withValue(
          GraphTransactionGate.Reentry.active.union([graphTransactionGate.id])) {
            try await GraphTransactionGate.Preparation.$active.withValue(
              GraphTransactionGate.Preparation.active.union([graphTransactionGate.id])) {
                try await preparation(preparingContext, session)
            }
        }
        // A later Fix may have changed an earlier captured ledger. Reject that
        // drift before exposing a stale plan to customer policy, then validate
        // again after policy because it too can retain a caller-owned reference.
        try session.preparedMutations.sealAndValidate()
        try policy.reviewPreparedGraph(context: preparingContext)
        try session.endPreparation()
        try session.preparedMutations.publishFixesAfterReview()
      }
      try Task.checkCancellation()
      let emptyPreparedPlan = preparation != nil && session.preparedMutations.isEmptyPlan
      if !emptyPreparedPlan {
        try await transaction.beginGraphTransaction()
        transactionStarted = true
      }
      var executionContext = graphContext
      if emptyPreparedPlan {
        let denied = GraphPreparationExecutor()
        executionContext.queryExecutor = denied; executionContext.mutationExecutor = denied
      }
      let executingContext = executionContext
      result = try await GraphTransactionGate.Reentry.$active.withValue(
        GraphTransactionGate.Reentry.active.union([graphTransactionGate.id])) {
          try await operation(executingContext, session)
      }
      try policy.ensureGraphComplete()
      try Task.checkCancellation()
      try session.preparedMutations.validateLedgers()
      if transactionStarted { try await transaction.commitGraphTransaction() }
      committed = true
      policy.endGraph()
    } catch {
      if transactionStarted && !committed { try? await transaction.rollbackGraphTransaction() }
      policy.endGraph()
      let (actions, _, evidence) = session.finish(committed: false)
      retainedEvidence = evidence
      for action in actions { try? action() }
      mutationPolicyCoordinator.retain(policy.lastSnapshot)
      if let check = error as? CheckException {
        throw CheckException(CheckerMessages.translate(check.violations,config:session.checkerConfiguration!,runtime:runtime,origin:rootEntityType))
      }
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

  public var fixTime: Date { graphSession?.fixTime ?? standaloneFixInvocation?.time ?? businessTime }

  private func requireProviderAccess() throws {
    guard !GraphTransactionGate.Preparation.active.contains(graphTransactionGate.id) else {
      throw TeaQLError.execution("GRAPH_PREPARATION_CANNOT_ACCESS_PROVIDER")
    }
    try graphSession?.requireProviderAccess()
    try standaloneFixInvocation?.ensureActive()
  }
  public func recordFixEvidence(_ evidence: FixEvidence) {
    if let graphSession { graphSession.recordFixEvidence(evidence) }
    else { standaloneFixInvocation?.record(evidence) }
  }
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
    try requireProviderAccess()
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
    var bootstrap = UserContext(
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
      entityCreationObserver: entityCreationObserver,
      objectStorageProvider: objectStorageProvider,
      objectStorageObserver: objectStorageObserver,
      businessClock: businessClock,
      internalIDGenerator: internalIDGenerator)
    // Retain customer governance configuration, not an active caller plan or
    // invocation. The new context still owns fresh graph/Fix execution state.
    bootstrap.mutationPolicyCoordinator = mutationPolicyCoordinator.fork()
    bootstrap.checkerMessages = checkerMessages
    return bootstrap
  }

  public mutating func setLocaleCode(_ code: String) throws { let value = try TeaQLLocale.parse(code); locale = value }
  public mutating func setLanguageCode(_ code: String) throws { try setLocaleCode(code) }
  public mutating func installI18nCatalog(_ catalog: I18nCatalog) { i18nCatalog = catalog }
  public mutating func installCheckerPresentation(_ model: CheckerPresentationModel) { checkerMessages = checkerMessages.replacing(model:model) }
  public mutating func installCheckerMessageCatalog(data: Data) throws {
    let catalog = try CheckerMessageCatalog(data:data); checkerMessages = checkerMessages.replacing(catalog:catalog)
  }
  public mutating func installCheckerMessageRenderer(_ renderer: @escaping CheckerMessageRenderer) { checkerMessages = checkerMessages.replacing(renderer:renderer) }
  public mutating func installCheckerMessageWarning(_ warning: @escaping CheckerMessageWarningSink) { checkerMessages = checkerMessages.replacing(warning:warning) }
  public func translateCheckResults(_ results: [CheckResult]) -> [CheckResult] {
    CheckerMessages.translate(results,config:checkerMessageConfiguration,runtime:runtime,origin:graphSession?.checkerOrigin)
  }
  public func translateCheckResults(_ results: [CheckResult], from origin: String) -> [CheckResult] {
    let config = checkerMessageConfiguration
    return CheckerMessages.translate(results.map { CheckerMessages.bind($0,model:config.services.model,origin:origin) },config:config,runtime:runtime,origin:origin)
  }

  /// Reserve before construction. The selected allocator is authoritative;
  /// neither failures nor invalid values fall back to a different generator.
  public func generateInternalID(for entity: String) async throws -> Int64 {
    try Task.checkCancellation()
    guard !entity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InternalIDError.invalidEntityName
    }
    try requireProviderAccess()
    guard graphSession == nil, standaloneFixInvocation == nil,
      !GraphTransactionGate.Reentry.active.contains(graphTransactionGate.id) else {
      throw InternalIDError.activeGraph
    }
    guard let generator = internalIDGenerator ?? (mutationExecutor as? any InternalIDGenerator) else {
      throw InternalIDError.unavailable
    }
    await graphTransactionGate.acquire()
    defer { graphTransactionGate.release(evidence: graphTransactionGate.lastFixEvidence) }
    try Task.checkCancellation()
    let value = try await GraphTransactionGate.Reentry.$active.withValue(
      GraphTransactionGate.Reentry.active.union([graphTransactionGate.id])) {
        try await generator.nextID(for: entity, context: self)
    }
    try Task.checkCancellation()
    guard value > 0 else { throw InternalIDError.invalidValue(value) }
    return value
  }

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
    return try await withListOperation(request, completion: { result in
      ["teaql.result.cardinality": .integer(Int64(result.records.count))]
    }) { authorized in
      try await executeQuery(authorized, inheritedIntent: inheritedIntent, attachmentKey: attachmentKey)
    }
  }

  private func scopeAlreadyAuthorized(_ scope: QueryRequestScope) -> Bool {
    guard let owner = ListExecutionState.owner else { return false }
    return owner.context == queryExecutionContext && owner.authorized === scope
  }

  private func withListOperation<Result: Sendable>(
    _ request: QueryRequest,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: (QueryRequest) async throws -> Result
  ) async throws -> Result {
    try requireProviderAccess()
    let bound = try request.bindingTree()
    if let owner = ListExecutionState.owner,
      owner.context == queryExecutionContext && owner.root === bound.scope.root {
      return try await body(bound)
    }
    let authorized = try bound.withQuery(requestPolicy.apply(bound.query)).bindingTree()
    let owner = ListExecutionOwner(context: queryExecutionContext, root: authorized.scope.root,
      authorized: authorized.scope)
    return try await ListExecutionState.$owner.withValue(owner) {
      try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "query", name: "\(authorized.query.entity.name).list",
        attributes: ["teaql.entity.type": .string(authorized.query.entity.name)]
      ), completion: completion) {
        try await body(authorized)
      }
    }
  }

  /// Generated-library bridge: one operation owns optional count, relation and
  /// facet loading and typed hydration. No shared Context mutation ledger or
  /// ambient SDK span is used to infer invocation ownership.
  public func executeTypedList<Entity: Sendable>(
    _ query: SelectQuery, countRequested: Bool,
    hydrate: @Sendable (TeaQLRecord) throws -> Entity
  ) async throws -> SmartList<Entity> {
    try await executeTypedList(query, countRequested: countRequested) { record, _ in
      try hydrate(record)
    }
  }

  /// A generated typed graph needs its per-row relation-result metadata as
  /// well as record values. Facets remain query-only data, never ledger fields.
  public func executeTypedList<Entity: Sendable>(
    _ query: SelectQuery, countRequested: Bool,
    hydrate: @Sendable (TeaQLRecord, [String: QueryResult]) throws -> Entity
  ) async throws -> SmartList<Entity> {
    let request = try QueryRequest(query: query)
    return try await withListOperation(request, completion: { rows in
      ["teaql.result.cardinality": .integer(Int64(rows.count))]
    }) { authorized in
      var query = authorized.query
      guard query.groupBy.isEmpty else {
        throw TeaQLError.unsupportedQueryCapability("grouped projections require the record query terminal")
      }
      let countAlias = countRequested ? query.pageCountOperation?.alias : nil
      let aggregateOnly = query.aggregates.contains {
        !($0.function == .count && $0.alias == countAlias)
      }
      if countRequested, let alias = countAlias {
        query.aggregates.removeAll { $0.function == .count && $0.alias == alias }
      }
      let rowsRequest = authorized.withQuery(query)
      let result = try await execute(rowsRequest)
      var total: Int?
      if countRequested {
        let observation = await idSetPaginationObservation()
        total = !aggregateOnly && query.idSetPagination != nil && observation.countAccuracy == "EXACT"
          ? observation.count : try await count(rowsRequest)
      }
      var aggregations = total.flatMap { value in
        query.pageCountOperation?.alias.map { [$0: TeaQLValue.int(Int64(value))] }
      } ?? [:]
      let rows: [Entity]
      if aggregateOnly {
        rows = []
        if let scalar = result.records.first {
          aggregations.merge(scalar) { _, value in value }
        }
      } else {
        rows = try result.records.enumerated().map { index, record in
          try hydrate(record, result.loadedRelations[index] ?? [:])
        }
      }
      return SmartList(rows, totalCount: total, aggregations: aggregations, facets: result.facets)
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
    let bound = try request.bindingTree()
    let request = try (scopeAlreadyAuthorized(bound.scope)
      ? bound : bound.withQuery(requestPolicy.apply(bound.query)).bindingTree())
    let validated = try request.query.validatedForExecution()
    // Root prose can mention a masked value bound only by a descendant. Capture
    // declared bindings before emitting parent logs, without fetching children.
    let invocationIntent: SQLExecutionMetadata?
    if let inheritedIntent { invocationIntent = inheritedIntent }
    else { invocationIntent = try await queryIntentProvenance(request.withQuery(validated)) }
    let idSetPrepared = try await prepareIdSetPagination(request.withQuery(validated), inheritedIntent: invocationIntent)
    let prepared = await prepareContinuousPage(idSetPrepared.query)
    var base = prepared.query
    base.relations = []
    base.relationAggregates = []
    base.facets = []
    let rawResult = try await executeProviderQuery(request.withQuery(base), inheritedIntent: invocationIntent)
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
    await registerContinuousPage(prepared.execution, rows: result.records)
    // Capture just the requested assembly key, in the final provider row order,
    // before a to-one load can replace it (including replacement with null).
    let attachmentKeys = attachmentKey.map { key in result.records.map { $0[key] ?? .null } } ?? []
    let facets = try await executeFacets(request, query: validated, inheritedIntent: invocationIntent)

    guard (!validated.relations.isEmpty || !validated.relationAggregates.isEmpty),
      !result.records.isEmpty else {
      return QueryResult(
        records: result.records, backend: result.backend, trace: result.trace,
        metadata: result.metadata, facets: facets).attachingRelationKeys(attachmentKeys)
    }

    var records = result.records
    var loadedRelations: [Int: [String: QueryResult]] = [:]
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
      child.groupByAliases = nil
      child.projection = []
      child.orderBy = []
      child.offset = 0
      child.limit = nil
      child.relations = []
      child.relationAggregates = []
      let membership = TeaQLExpression.inList(foreignKey.name, parentIDs)
      child.filter = child.filter.map { .and([$0, membership]) } ?? membership
      let rows = try await execute(request.derive(child), inheritedIntent: childIntent).records
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
        let localValues = result.records.compactMap { $0[relation.localKey] }.filter { $0 != .null }
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
        let facetBase = child
        // Facet membership belongs to each owner, not the batched visible rows.
        child.facets = []
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
        var childRelations: [Int: [String: QueryResult]] = [:]
        if useProbes {
          for localValue in localValues {
            var probe = child
            probe.partitionBy = nil
            let join = TeaQLExpression.equal(relation.foreignKey, localValue)
            probe.filter = probe.filter.map { .and([$0, join]) } ?? join
            let loaded = try await execute(request.derive(probe), inheritedIntent: childIntent,
              attachmentKey: relation.foreignKey)
            let start = children.count
            for (index, relations) in loaded.loadedRelations { childRelations[start + index] = relations }
            children.append(contentsOf: loaded.records)
            childKeys.append(contentsOf: loaded.relationAttachmentKeys)
          }
        } else {
          if child.limit != nil { child.partitionBy = relation.foreignKey }
          let join = TeaQLExpression.inList(relation.foreignKey, localValues)
          child.filter = child.filter.map { .and([$0, join]) } ?? join
          let loaded = try await execute(request.derive(child), inheritedIntent: childIntent,
            attachmentKey: relation.foreignKey)
          children = loaded.records
          childKeys = loaded.relationAttachmentKeys
          childRelations = loaded.loadedRelations
        }
        guard childKeys.count == children.count else {
          throw TeaQLError.execution("Relation assembly key count differs from row count")
        }
        var grouped: [TeaQLValue: [Int]] = [:]
        for (index, key) in childKeys.enumerated() {
          grouped[normalizedRelationIdentity(key), default: []].append(index)
        }
        for index in records.indices {
          let key = normalizedRelationIdentity(result.records[index][relation.localKey] ?? .null)
          let found = key == .null ? [] : grouped[key] ?? []
          let indices = relation.many ? found : Array(found.prefix(1))
          var matches = indices.map { children[$0] }
          // A known FK survives conditional target loading. Only its known
          // key is loaded; missing target fields must remain NotLoaded.
          if !relation.many && matches.isEmpty && key != .null {
            matches = [[relation.foreignKey: key]]
          }
          var nested: [Int: [String: QueryResult]] = [:]
          for (position, childIndex) in indices.enumerated() {
            if let relations = childRelations[childIndex] { nested[position] = relations }
          }
          var ownerFacets: [String: SmartList<TeaQLRecord>] = [:]
          if !facetBase.facets.isEmpty {
            var owner = facetBase
            owner.partitionBy = nil
            let membership = TeaQLExpression.inList(relation.foreignKey, key == .null ? [] : [key])
            owner.filter = owner.filter.map { .and([$0, membership]) } ?? membership
            let ownerRequest = try request.derive(owner).bindingTree()
            let authorizedOwner = try ownerRequest.withQuery(requestPolicy.apply(ownerRequest.query)).bindingTree()
            let ownerQuery = try authorizedOwner.query.validatedForExecution()
            ownerFacets = try await executeFacets(authorizedOwner, query: ownerQuery, inheritedIntent: childIntent)
          }
          loadedRelations[index, default: [:]][relation.name] = QueryResult(
            records: matches, backend: result.backend, facets: ownerFacets, loadedRelations: nested)
          records[index][relation.name] = relation.many
            ? .array(matches.map(TeaQLValue.object))
            : matches.first.map(TeaQLValue.object) ?? .null
        }
      }
    }
    return QueryResult(
      records: records, backend: result.backend, trace: result.trace,
      metadata: result.metadata, facets: facets, loadedRelations: loadedRelations).attachingRelationKeys(attachmentKeys)
  }

  private func executeFacets(
    _ request: QueryRequest, query: SelectQuery, inheritedIntent: SQLExecutionMetadata?
  ) async throws -> [String: SmartList<TeaQLRecord>] {
    var facets: [String: SmartList<TeaQLRecord>] = [:]
    for facet in query.facets {
      var child = facet.query.makeQuery()
      guard let facetScope = child.requestScope?.parent, facetScope.isFacet else {
        throw TeaQLError.execution("QUERY_FACET_SCOPE_REQUIRED")
      }
      let countAliases = child.aggregates.filter { $0.function == .count }.map(\.alias)
      let aliases = countAliases.isEmpty ? ["count"] : countAliases
      let helper = facetScope.helper(entity: query.entity.name, comment: "aggregate \(facetScope.relation)")
      var membership = query
      membership.facets = []; membership.relations = []; membership.relationAggregates = []
      membership.aggregates = aliases.map { QueryAggregate(.count, field: "*", alias: $0) }
      membership.groupBy = [facet.relationName]; membership.orderBy = []
      membership.groupByAliases = nil
      membership.partitionBy = nil; membership.offset = 0; membership.limit = nil
      membership.projection = []
      let rows = try await execute(request.derive(membership, scope: helper), inheritedIntent: inheritedIntent).records
      var counts: [TeaQLValue: TeaQLRecord] = [:]
      for row in rows {
        guard let value = row[facet.relationName], value != .null else { continue }
        counts[normalizedRelationIdentity(value)] = row
      }
      child.aggregates.removeAll { $0.function == .count }
      // Reverse aggregates must use the entire filtered source set, not the
      // visible page and not all rows referencing the facet value.
      var source = query
      source.relations = []; source.relationAggregates = []; source.facets = []
      source.aggregates = []; source.groupBy = []; source.orderBy = []
      source.groupByAliases = nil
      source.offset = 0; source.limit = nil; source.partitionBy = nil
      source.continuousPage = nil; source.idSetPagination = nil; source.projection = ["id"]
      child.relationAggregates = child.relationAggregates.map { aggregate in
        var nested = aggregate.query.makeQuery()
        if nested.entity.name == source.entity.name {
          let restriction = TeaQLExpression.inSubquery("id", RelationQueryPlan(source), "id")
          nested.filter = nested.filter.map { .and([$0, restriction]) } ?? restriction
        }
        return RelationAggregateLoad(relationName: aggregate.relationName, foreignKey: aggregate.foreignKey,
          alias: aggregate.alias, query: nested, singleResult: aggregate.singleResult, operation: aggregate.operation)
      }
      child.tracePath = query.tracePath + [TraceNode(
        entity: child.entity.name, comment: "\(query.entity.name).\(facet.relationName)",
        purpose: "", level: query.tracePath.count + 2, kind: "relation", name: facet.relationName)]
      // Restrict before pagination and recursion so nested counts cannot include
      // target candidates excluded by their parent's membership.
      if !facet.includeAllFacets {
        let filter = TeaQLExpression.inList("id", Array(counts.keys))
        child.filter = child.filter.map { .and([$0, filter]) } ?? filter
      }
      let loaded = try await execute(request.derive(child), inheritedIntent: inheritedIntent)
      let decorated = loaded.records.filter { row in
        facet.includeAllFacets || row["id"].map { counts[normalizedRelationIdentity($0)] != nil } == true
      }.map { row in
        var copy = row
        if let id = row["id"] {
          for alias in aliases { copy[alias] = counts[normalizedRelationIdentity(id)]?[alias] ?? .int(0) }
        }
        return copy
      }
      facets[facet.name] = SmartList(decorated, facets: loaded.facets)
    }
    return facets
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

  private func recordTelemetrySQL(_ metadata: SQLExecutionMetadata,
    intentSource: SQLExecutionMetadata? = nil, intentValues: [TeaQLValue] = []) async {
    let safe = LogPrivacy.project(metadata, intentSource: intentSource, intentValues: intentValues)
    runtimeTelemetry.recordSQL(safe)
    await telemetrySink?.record(safe)
  }

  private func executeProviderQuery(
    _ request: QueryRequest, inheritedIntent: SQLExecutionMetadata?
  ) async throws -> QueryResult {
    let result = try await runtimeTelemetry.withOperation(
      RuntimeOperation(family: "provider", name: "\(queryExecutor.providerKind).query",
        attributes: ["teaql.provider.kind": .string(queryExecutor.providerKind),
          "teaql.provider.operation": .string("query")])
    ) {
      do {
        if let diagnosed = queryExecutor as? any SQLDiagnosticExecutor {
          return try await diagnosed.executeDiagnosed(request)
        }
        return try await queryExecutor.execute(request)
      } catch let failure as SQLExecutionFailure {
        for diagnostic in failure.diagnostics {
          let source = LogPrivacy.inheritIntent(diagnostic.intentSource, inherited: inheritedIntent)
          await recordTelemetrySQL(diagnostic.metadata, intentSource: source)
          if querySQLLogEnabled {
            await diagnosticSQLLogSink?.write(LogPrivacy.project(diagnostic.metadata,
              allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: source))
          }
        }
        throw failure.cause
      }
    }
    if let metadata = result.metadata {
      await recordTelemetrySQL(metadata, intentSource: inheritedIntent)
      if querySQLLogEnabled { await diagnosticSQLLogSink?.write(LogPrivacy.project(metadata,
        allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: inheritedIntent)) }
    }
    return result
  }

  private func prepareIdSetPagination(
    _ request: QueryRequest, inheritedIntent: SQLExecutionMetadata?
  ) async throws -> (query: SelectQuery, execution: IdSetExecution?) {
    let query = request.query
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
        idQuery.requestScope = request.scope.helper(entity: query.entity.name,
          comment: "collect \(query.entity.name) IDs for pagination")
        let result = try await executeProviderQuery(try QueryRequest(query: idQuery), inheritedIntent: inheritedIntent)
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

  /// Runtime-owned page semantics; generated code only supplies operation
  /// descriptors and hydrates the resulting rows into its typed entities.
  public func executePage(_ query: SelectQuery, offset: Int, limit: Int) async throws -> TeaQLPage<TeaQLRecord> {
    var page = query; page.offset = offset; page.limit = limit
    return try await executePage(QueryRequest(query: page), offset: offset, limit: limit)
  }

  private func executePage(_ input: QueryRequest, offset: Int, limit: Int) async throws -> TeaQLPage<TeaQLRecord> {
    return try await withListOperation(input, completion: { page in
      ["teaql.result.cardinality": .integer(Int64(page.items.count))]
    }) { authorized in
    let query = authorized.query
    // Page arguments were installed before policy. Never overwrite a trusted
    // policy's bounded slice with the caller's original offset/limit here.
    var page = query
    if let alias = page.pageCountOperation?.alias {
      page.aggregates.removeAll { $0.function == .count && $0.alias == alias }
    }
    let request = authorized.withQuery(page)
    let result = try await execute(request)
    let observation = await idSetPaginationObservation()
    let total = page.idSetPagination != nil && observation.countAccuracy == "EXACT"
      ? observation.count : try await count(request)
    let named = page.pageCountOperation?.alias.map { [$0: TeaQLValue.int(Int64(total))] } ?? [:]
    return TeaQLPage(items: SmartList(result.records, totalCount: total, aggregations: named, facets: result.facets),
      total: total, offset: page.offset, limit: page.limit ?? 10_000)
    }
  }

  public func count(_ request: QueryRequest) async throws -> Int {
    try requireProviderAccess()
    let bound = try request.bindingTree()
    let authorized = try (scopeAlreadyAuthorized(bound.scope)
      ? bound : bound.withQuery(requestPolicy.apply(bound.query)).bindingTree())
    let operation = authorized.query.pageCountOperation
    let scope = operation.map(authorized.scope.derive)
      ?? authorized.scope.helper(entity: authorized.query.entity.name, comment: "count matching rows")
    let request = authorized.derive(authorized.query, scope: scope)
    var validated = try request.query.validatedForExecution()
    // Count strips eager loads, not the original invocation's redaction sources.
    let invocationIntent = try await queryIntentProvenance(request.withQuery(validated))
    validated.orderBy = []
    validated.offset = 0
    validated.limit = nil
    validated.projection = []
    validated.relations = []
    validated.relationAggregates = []
    validated.partitionBy = nil
    validated.facets = []
    validated.aggregates = []
    validated.groupBy = []
    validated.groupByAliases = nil
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
          await recordTelemetrySQL(result.metadata, intentSource: invocationIntent)
          if querySQLLogEnabled {
            await diagnosticSQLLogSink?.write(LogPrivacy.project(result.metadata,
              allowPlaintext: LogPrivacy.plaintextEnabled(), intentSource: invocationIntent))
          }
          return result.count
        } catch let failure as SQLExecutionFailure {
          for diagnostic in failure.diagnostics {
            let source = LogPrivacy.inheritIntent(diagnostic.intentSource, inherited: invocationIntent)
            await recordTelemetrySQL(diagnostic.metadata, intentSource: source)
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
    // Admission is a separate complete pass: a later exhausted row must not
    // let an earlier sibling run customer Fix or policy code.
    for mutation in mutations { _ = try mutation.validatedForExecution() }
    return try await executeGraphSave(comment: request.intent.comment, preparing: { context, _ in
      for mutation in mutations { _ = try context.preflightMutation(mutation) }
    }) { context, _ in
      var results: [MutationResult] = []
      results.reserveCapacity(mutations.count)
      for mutation in mutations { results.append(try await context.execute(mutation)) }
      return results
    }
  }

  public func execute(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) async throws -> MutationResult {
    try requireProviderAccess()
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
    try Task.checkCancellation()
    try graphSession?.ensureActive()
    try standaloneFixInvocation?.ensureActive()
    if graphSession == nil && standaloneFixInvocation == nil {
      // Request admission has already happened before taking the Clock SPI.
      // Keep the same time through Fix, provider work and committed audit.
      let scope = StandaloneFixInvocation(time: businessTime)
      var invocation = self
      invocation.standaloneFixInvocation = scope
      defer { graphTransactionGate.retainFixEvidence(scope.finish()) }
      return try await invocation.executeMutation(mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    }
    let validated: Mutation
    if let session = graphSession, let prepared = try session.preparedMutations.consume(
      mutation, ledger: ledgerRoot, ledgerKey: ledgerKey, rootComment: session.intent.comment) {
      validated = prepared
    } else {
      validated = try checkAndFixMutation(mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    }
    let oldProvenance = LogPrivacy.loadedMutationSource(validated)
    let invocationProvenance = LogPrivacy.inheritIntent(oldProvenance, inherited: graphSession?.intentProvenance)
    let mutationGovernance = try mutationPolicyCoordinator.enter(
      context: self, mutation: validated, ledgerKey: ledgerKey)
    try graphSession?.preparedMutations.publishFixesAfterReview()
    try graphSession?.preparedMutations.validateLedgers()
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
          await recordTelemetrySQL(diagnostic.metadata,
            intentSource: source, intentValues: submittedID.map { [$0] } ?? [])
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
        await recordTelemetrySQL(statement,
          intentSource: source, intentValues: auditID.map { [$0] } ?? [])
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
    // Preserve executed SQL diagnostics before rejecting a cancelled or changed
    // graph. Standalone providers may have already committed: only a graph can
    // promise rollback here, and a successful COMMIT is never checked afterwards.
    if let graphSession {
      try Task.checkCancellation()
      try graphSession.preparedMutations.validateLedgers()
      try graphSession.recordPersisted(validated, result: result, sourceKey: ledgerKey, sourceLedger: ledgerRoot)
    }
    return result
  }

  public func preflightMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot? = nil, ledgerKey: EntityKey? = nil,
    loadedSnapshot: LoadedEntitySnapshot? = nil
  ) throws -> Mutation {
    let original = try MutationRequest(mutation: mutation).mutation
    if let graphSession, let ledgerRoot, let ledgerKey {
      let fields = Set(ContextFix.fields(self, mutation: original).keys)
      if !fields.isEmpty { try graphSession.afterRollback(ledgerRoot.captureContextFields(ledgerKey, fields: fields)) }
    }
    let state = ledgerKey.flatMap { ledgerRoot?.mutationSnapshot($0) }
    var validated = try checkAndFixMutation(
      mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    var baseline: LoadedEntitySnapshot?, restored: TeaQLRecord = [:]
    if graphSession != nil, validated.kind == .update, let state, let loadedSnapshot,
      loadedSnapshot.origin == .hydrated, loadedSnapshot.key == ledgerKey,
      loadedSnapshot.version == validated.expectedVersion, state.version == loadedSnapshot.version,
      !state.isNew, !state.isDeleted, validated.id == ledgerKey?.id {
      baseline = loadedSnapshot
      for (field, value) in validated.values {
        guard let property = validated.entity.property(named: field), !property.isID, !property.isVersion,
          field == (property.modelName ?? property.name) else { continue }
        let aliases = [property.name, property.modelName ?? property.name, property.column]
        let known = aliases.compactMap { loadedSnapshot.record[$0] }
        if !known.isEmpty && known.allSatisfy({ LoadedScalarRestoration.same(value, $0, property: property) }) {
          restored[field] = value; validated.values.removeValue(forKey: field)
        }
      }
    }
    try graphSession?.preparedMutations.record(original: original, fixed: validated,
      ledger: ledgerRoot, ledgerKey: ledgerKey, state: state, baseline: baseline, restored: restored)
    if baseline == nil || validated.kind != .update || !validated.values.isEmpty {
      try mutationPolicyCoordinator.recordPreflight(validated, ledgerKey: ledgerKey,
        references: graphSession?.preparedMutations.policyReferences(ledger: ledgerRoot, key: ledgerKey))
    }
    graphSession?.recordProvenance(Array(validated.values.values))
    graphSession?.recordLoadedProvenance(LogPrivacy.loadedMutationSource(validated))
    return validated
  }

  /// A generated traversal declares symbolic relationships before customer
  /// policy. Only an actual saved target in this invocation may resolve them.
  @_spi(Generated) public func bindGraphReference<Source: TeaQLMutationRootedEntity, Target: TeaQLMutationRootedEntity>(
    _ source: Source, field: String, to target: Target
  ) throws {
    guard let session = graphSession,
      GraphTransactionGate.Preparation.active.contains(graphTransactionGate.id) else {
      throw MutationPolicyError.preflightAfterReview
    }
    try session.ensureActive()
    guard source.teaqlEntityRoot === target.teaqlEntityRoot,
      runtime.entity(named: Source.descriptor.name) == Source.descriptor,
      runtime.entity(named: Target.descriptor.name) == Target.descriptor,
      let property = Source.descriptor.property(named: field), property.isRelation,
      property.referencedEntity == Target.descriptor.name,
      field == (property.modelName ?? property.name), target.id == 0,
      target.version == 0 else { throw MutationPolicyError.operationOutsideReviewedPlan }
    try session.preparedMutations.bind(source: source.teaqlEntityKey, field: field,
      target: target.teaqlEntityKey, targetEntity: Target.descriptor, ledger: source.teaqlEntityRoot)
  }

  private func checkAndFixMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) throws -> Mutation {
    // A retained Context capability cannot run another customer callback after
    // its invocation finished, even if a later plan check would reject it.
    try graphSession?.ensureActive()
    try standaloneFixInvocation?.ensureActive()
    let request = try MutationRequest(mutation: mutation)
    if graphSession == nil && standaloneFixInvocation == nil {
      let scope = StandaloneFixInvocation(time: businessTime)
      var invocation = self
      invocation.standaloneFixInvocation = scope
      defer { graphTransactionGate.retainFixEvidence(scope.finish()) }
      return try invocation.checkAndFixInInvocation(request, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    }
    return try checkAndFixInInvocation(request, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
  }

  private func checkAndFixInInvocation(
    _ request: MutationRequest, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) throws -> Mutation {
    var validated = request.mutation
    let messages = checkerMessageConfiguration
    validated.actor = actor
    validated.auditCategory = auditCategory
    let roots = ContextRootAdmission(context: self, mutation: request.mutation)
    try roots.validate(validated)
    try roots.applyCreateDefaults(&validated)
    let checker = runtime.checker(named: validated.entity.name)
    let contextFix = ContextFixFrame(request.mutation, fields: ContextFix.fields(self, mutation: request.mutation))
    var violations: [CheckResult] = []
    if let checker {
      let declaringEntityType = request.mutation.entity.name
      let owner = request.mutation.entity
      var scope = CheckerPrivacy.capture(request.mutation, owner: owner, runtime: runtime)
      var rawResults: [CheckResult] = []
      var callbackFailure: (any Error)?
      let frame = contextFix
      var checkingContext = self
      checkingContext.contextFixFrame = frame
      defer { frame.close() }
      do { rawResults = try checker.checkAndFix(context: checkingContext, mutation: &validated, now: fixTime) }
      catch let error as CheckException { rawResults = error.violations }
      catch { callbackFailure = error }
      scope.append(CheckerPrivacy.capture(validated, owner: owner, runtime: runtime))
      if let callbackFailure {
        let secrets = LogPrivacy.plaintextEnabled() ? scope.debug : scope.safe
        // Preserve application error identity when this invocation has no
        // sensitive values. Otherwise do not retain an unsafe cause/userInfo.
        if secrets.isEmpty { throw callbackFailure }
        throw CheckerExecutionError(description: CheckerPrivacy.scrub(String(describing: callbackFailure), secrets: secrets) ?? "Checker failed")
      }
      let results = rawResults.map { source in
        var value = CheckerMessages.bind(source.bindingDeclaringEntity(declaringEntityType),model:messages.services.model,origin:declaringEntityType)
        if value.observedLength == nil, value.inputValue == nil, ["checker.minLength","checker.maxLength"].contains(CheckerMessages.rule(value.ruleID)),
          value.location.segments.count == 1, case .property(let field) = value.location.segments[0], case .string(let text) = validated.values[field] {
          value.observedLength = text.count
          value.observedLengthUnit = .grapheme
        }
        return value
      }
      violations = CheckerMessages.translate(results,config:messages,runtime:runtime,owner:owner,scope:scope)
    }
    // Request-owned intent has always survived a Checker attempting to replace
    // it. Restore it here as well as at the final request/provider handoff.
    validated.auditReason = request.intent.auditReason
    // A field Fix may repair values, never the target, operation, schema/privacy
    // metadata or trusted actor. Diagnose against the original model descriptor.
    let originalEntity = request.mutation.entity
    if validated.kind != request.mutation.kind || validated.entity != originalEntity
      || validated.actor != actor || validated.auditCategory != auditCategory
      || validated.mutationLineage != request.mutation.mutationLineage
      || !sameMutationRecord(validated.loadedValues, request.mutation.loadedValues) {
      violations.append(CheckResult(ruleID: "invalid_type", location: ObjectLocation(),
        message: "Fix cannot replace the mutation target, operation, metadata or trusted actor",
        entityType: originalEntity.name))
    }
    if validated.id != request.mutation.id {
      let property = originalEntity.idProperty
      violations.append(CheckResult(ruleID: "invalid_type",
        location: .property(property?.modelName ?? property?.name ?? "id"),
        message: "Fix cannot replace the mutation identity", entityType: originalEntity.name))
    }
    if validated.expectedVersion != request.mutation.expectedVersion {
      let property = originalEntity.versionProperty
      violations.append(CheckResult(ruleID: "invalid_type",
        location: .property(property?.modelName ?? property?.name ?? "version"),
        message: "Fix cannot replace the original optimistic version", entityType: originalEntity.name))
    }
    // Validate the final custom-Fix result even without an installed checker.
    // Keep invalid numbers away from policy snapshots and provider boundaries;
    // do not publish a rejected Fix back into a caller's mutation ledger.
    let invalidFields = Set(validated.values.compactMap { name, value -> String? in
      guard case .double(let number) = value, !number.isFinite else { return nil }
      let property = originalEntity.property(named: name)
      return property?.modelName ?? property?.name ?? name
    })
    if !invalidFields.isEmpty {
      violations.append(contentsOf: invalidFields.sorted().map {
        CheckResult(ruleID: "invalid_type", location: .property($0),
          message: "Expected a finite Float/Double value", entityType: originalEntity.name)
      })
    }
    try ModeledInteger32.normalizeMutation(&validated.values, entity: originalEntity, violations: &violations)
    ModeledBoolean.validateMutation(validated.values, entity: originalEntity, violations: &violations)
    try roots.validate(validated, final: true)
    if !violations.isEmpty { throw CheckException(violations) }
    _ = try validated.validatedForExecution()
    contextFix.normalizeFinalIntent(&validated)
    if checker != nil && graphSession == nil {
      if let ledgerRoot, let ledgerKey {
        for (field, value) in validated.values {
          ledgerRoot.set(ledgerKey, field: field, value: value)
        }
      }
    }
    return request.withMutation(validated).mutation
  }
}
