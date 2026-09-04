import Foundation

public protocol QueryExecutor: Sendable {
  var idSetDataSourceIdentity: String { get }
  func execute(_ query: SelectQuery) async throws -> QueryResult
  func count(_ query: SelectQuery) async throws -> Int
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

  func count(_ query: SelectQuery) async throws -> Int {
    throw TeaQLError.execution(
      "Exact count is not supported by the configured query executor for \(query.entity.name)")
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
  public let operation: SQLExecutionOperation
  public let comment: String?
  public let purpose: String?
  public let auditReason: String?
  public let tracePath: [TraceNode]
  public let parameterizedSQL: String
  public let parameters: [TeaQLValue]
  public let debugSQL: String
  public let elapsedMicros: UInt64
  public let resultCount: Int?
  public let affectedRows: Int?
  public let resultSummary: String

  public init(
    operation: SQLExecutionOperation,
    comment: String? = nil,
    purpose: String? = nil,
    auditReason: String? = nil,
    tracePath: [TraceNode] = [],
    parameterizedSQL: String,
    parameters: [TeaQLValue],
    debugSQL: String,
    elapsedMicros: UInt64,
    resultCount: Int? = nil,
    affectedRows: Int? = nil,
    resultSummary: String
  ) {
    self.operation = operation
    self.comment = comment
    self.purpose = purpose
    self.auditReason = auditReason
    self.tracePath = tracePath
    self.parameterizedSQL = parameterizedSQL
    self.parameters = parameters
    self.debugSQL = debugSQL
    self.elapsedMicros = elapsedMicros
    self.resultCount = resultCount
    self.affectedRows = affectedRows
    self.resultSummary = resultSummary
  }
}

public protocol RuntimeTelemetrySink: Sendable {
  func record(_ metadata: SQLExecutionMetadata) async
}

/// Value-bearing SQL diagnostic destination. The text sink is installed by
/// default and remains separate from safe RuntimeTelemetry.
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
    let text = "[TeaQL SQL][\(metadata.operation.rawValue)][\(metadata.elapsedMicros)us] "
      + "\(metadata.resultSummary) comment=\(metadata.comment ?? "") "
      + "purpose=\(metadata.purpose ?? "") auditReason=\(metadata.auditReason ?? "") "
      + "tracePath=\(metadata.tracePath)\n"
      + "Parameterized SQL: \(metadata.parameterizedSQL) params=\(metadata.parameters)\n"
      + "Debug SQL: \(metadata.debugSQL)"
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
    entries.append(metadata)
  }

  public func enableAll() { mode = .all; entries.removeAll() }
  public func enableSelect() { mode = .select; entries.removeAll() }
  public func enableMutation() { mode = .mutation; entries.removeAll() }
  public func disable() { mode = .disabled; entries.removeAll() }
  public func snapshot() -> [SQLExecutionMetadata] { entries }
}

public struct Mutation: Sendable, Codable {
  public let kind: MutationKind
  public let entity: EntityDescriptor
  public var id: TeaQLValue?
  public var values: TeaQLRecord
  public var expectedVersion: Int64?
  public var auditReason: String?
  public var actor: String?
  public var auditCategory: String?

  public init(
    kind: MutationKind,
    entity: EntityDescriptor,
    id: TeaQLValue? = nil,
    values: TeaQLRecord = [:],
    expectedVersion: Int64? = nil,
    auditReason: String? = nil,
    actor: String? = nil,
    auditCategory: String? = nil
  ) {
    self.kind = kind
    self.entity = entity
    self.id = id
    self.values = values
    self.expectedVersion = expectedVersion
    self.auditReason = auditReason
    self.actor = actor
    self.auditCategory = auditCategory
  }

  public func validatedForExecution() throws -> Self {
    guard let auditReason, !auditReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw TeaQLError.missingAuditReason
    }
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
  func execute(_ mutation: Mutation) async throws -> MutationResult
}

public protocol GraphTransactionExecutor: MutationExecutor {
  func beginGraphTransaction() async throws
  func commitGraphTransaction() async throws
  func rollbackGraphTransaction() async throws
}

public extension MutationExecutor {
  var providerKind: String { String(describing: type(of: self)) }
}

private enum GraphSaveTaskContext {
  @TaskLocal static var session: UUID?
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

private final class GraphSaveCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private var activeSession: UUID?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var commitActions: [@Sendable () -> Void] = []
  private var rollbackActions: [@Sendable () -> Void] = []
  private var capturedFixTime: Date?
  private var currentFixEvidence: [FixEvidence] = []
  private var retainedFixEvidence: [FixEvidence] = []

  func execute<T: Sendable>(
    executor: any MutationExecutor,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    if let ambient = GraphSaveTaskContext.session, isActive(ambient) {
      return try await operation()
    }
    guard let transaction = executor as? any GraphTransactionExecutor else {
      throw TeaQLError.execution(
        "The configured mutation provider does not support atomic graph saves")
    }
    let session = UUID()
    await acquire(session)
    do {
      try await transaction.beginGraphTransaction()
      let result = try await GraphSaveTaskContext.$session.withValue(session) {
        try await operation()
      }
      try await transaction.commitGraphTransaction()
      let actions = finish(session, committed: true)
      actions.forEach { $0() }
      return result
    } catch {
      try? await transaction.rollbackGraphTransaction()
      let actions = finish(session, committed: false)
      actions.reversed().forEach { $0() }
      throw error
    }
  }

  func afterCommit(_ action: @escaping @Sendable () -> Void) throws {
    guard let session = GraphSaveTaskContext.session else {
      throw TeaQLError.execution("No graph save is active")
    }
    lock.lock(); defer { lock.unlock() }
    guard activeSession == session else { throw TeaQLError.execution("No graph save is active") }
    commitActions.append(action)
  }

  func afterRollback(_ action: @escaping @Sendable () -> Void) throws {
    guard let session = GraphSaveTaskContext.session else {
      throw TeaQLError.execution("No graph save is active")
    }
    lock.lock(); defer { lock.unlock() }
    guard activeSession == session else { throw TeaQLError.execution("No graph save is active") }
    rollbackActions.append(action)
  }

  func fixTime() -> Date? { lock.withLock { capturedFixTime } }
  func recordFixEvidence(_ evidence: FixEvidence) { lock.withLock { currentFixEvidence.append(evidence) } }
  func lastFixEvidence() -> [FixEvidence] { lock.withLock { retainedFixEvidence } }

  private func isActive(_ session: UUID) -> Bool {
    lock.lock(); defer { lock.unlock() }; return activeSession == session
  }

  private func acquire(_ session: UUID) async {
    while true {
      let acquired = lock.withLock { () -> Bool in
        guard activeSession == nil else { return false }
        activeSession = session; commitActions = []; rollbackActions = []; capturedFixTime = Date(); currentFixEvidence = []
        return true
      }
      if acquired { return }
      await withCheckedContinuation { continuation in
        let resumeImmediately = lock.withLock { () -> Bool in
          if activeSession == nil { return true }
          waiters.append(continuation)
          return false
        }
        if resumeImmediately { continuation.resume() }
      }
    }
  }

  private func finish(_ session: UUID, committed: Bool) -> [@Sendable () -> Void] {
    lock.lock()
    precondition(activeSession == session)
    let actions = committed ? commitActions : rollbackActions
    retainedFixEvidence = currentFixEvidence
    activeSession = nil; commitActions = []; rollbackActions = []; capturedFixTime = nil; currentFixEvidence = []
    let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
    lock.unlock()
    waiter?.resume()
    return actions
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
    try await context.executeGraphSave {
      try await saveWithinGraph(context)
    }
  }

  /// Generated graph infrastructure calls this for every reachable node before
  /// the first mutation of the graph is sent to the provider.
  public func preflight(_ context: UserContext) throws {
    let rooted = entity as? any TeaQLMutationRootedEntity
    _ = try context.preflightMutation(
      makeMutation(rooted: rooted),
      ledgerRoot: rooted?.teaqlEntityRoot,
      ledgerKey: rooted?.teaqlEntityKey)
  }

  private func saveWithinGraph(_ context: UserContext) async throws -> Entity {
    let rooted = entity as? any TeaQLMutationRootedEntity
    let mutation = try makeMutation(rooted: rooted)
    let saved = try persistedEntity(from: await context.execute(
      mutation, ledgerRoot: rooted?.teaqlEntityRoot, ledgerKey: rooted?.teaqlEntityKey))
    if let rooted {
      let originalKey = rooted.teaqlEntityKey
      let savedKey = EntityKey(entity: rooted.teaqlEntityKey.entity, id: .int(saved.id))
      let root = rooted.teaqlEntityRoot
      try context.afterGraphCommit {
        root.rekey(originalKey, to: savedKey)
        root.clearEntity(savedKey)
        root.setOriginalVersion(savedKey, version: saved.version)
      }
    }
    return saved
  }

  private func makeMutation(rooted: (any TeaQLMutationRootedEntity)?) throws -> Mutation {
    var values = entity.toMutationRecord()
    if let rooted {
      if entity.id != 0 {
        let pending = rooted.teaqlEntityRoot.change(rooted.teaqlEntityKey)
        if !pending.isEmpty { values = pending }
      }
    }
    let mutation: Mutation
    if let rooted, rooted.teaqlEntityRoot.isDeleted(rooted.teaqlEntityKey) {
      guard entity.id != 0, entity.version != 0 else {
        throw TeaQLError.execution("Deletion requires a loaded entity ID and version")
      }
      mutation = Mutation(
        kind: .delete,
        entity: Entity.descriptor,
        id: .int(entity.id),
        expectedVersion: entity.version,
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
        expectedVersion: entity.version,
        auditReason: reason
      )
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
  private let graphSaveCoordinator: GraphSaveCoordinator

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
    entityCreationObserver: EntityCreationObserver? = nil
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
    self.graphSaveCoordinator = GraphSaveCoordinator()
  }

  public func executeGraphSave<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await graphSaveCoordinator.execute(executor: mutationExecutor, operation: operation)
  }

  public func afterGraphCommit(_ action: @escaping @Sendable () -> Void) throws {
    try graphSaveCoordinator.afterCommit(action)
  }

  public func afterGraphRollback(_ action: @escaping @Sendable () -> Void) throws {
    try graphSaveCoordinator.afterRollback(action)
  }

  public var fixTime: Date { graphSaveCoordinator.fixTime() ?? Date() }
  public func recordFixEvidence(_ evidence: FixEvidence) { graphSaveCoordinator.recordFixEvidence(evidence) }
  public var lastFixEvidence: [FixEvidence] { graphSaveCoordinator.lastFixEvidence() }

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
    try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "query", name: "\(query.entity.name).list",
        attributes: ["teaql.entity.type": .string(query.entity.name)]
      ), completion: { result in
      ["teaql.result.cardinality": .integer(Int64(result.records.count))]
    }) {
      try await executeQuery(query)
    }
  }

  public func continuousPageObservation() async -> ContinuousPageObservation {
    await continuousPageState.currentObservation()
  }

  public func idSetPaginationObservation() async -> IdSetPaginationObservation {
    await idSetObservationState.current()
  }

  private func executeQuery(_ query: SelectQuery) async throws -> QueryResult {
    let validated = try requestPolicy.apply(query).validatedForExecution()
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
      try await queryExecutor.execute(base)
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
      await telemetrySink?.record(metadata)
      if querySQLLogEnabled { await diagnosticSQLLogSink?.write(metadata) }
    }
    await registerContinuousPage(prepared.execution, rows: result.records)
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
      let membershipRows = try await execute(membership).records
      var counts: [TeaQLValue: Int64] = [:]
      for row in membershipRows {
        guard let value = row[facet.relationName], value != .null else { continue }
        counts[normalizedRelationIdentity(value), default: 0] += 1
      }

      var child = facet.query.makeQuery()
      child.comment = validated.comment
      child.purpose = validated.purpose
      var childRows = try await execute(child).records.map { row in
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
      facets[facet.name] = SmartList(childRows)
    }

    guard (!validated.relations.isEmpty || !validated.relationAggregates.isEmpty),
      !result.records.isEmpty else {
      return QueryResult(
        records: result.records, backend: result.backend, trace: result.trace,
        metadata: result.metadata, facets: facets)
    }

    var records = result.records
    for aggregate in validated.relationAggregates {
      guard let parentID = validated.entity.idProperty else {
        throw TeaQLError.unknownProperty(entity: validated.entity.name, property: "id")
      }
      let parentIDs = records.compactMap { $0[parentID.name] }
      guard !parentIDs.isEmpty else { continue }
      var child = aggregate.query.makeQuery()
      child.tracePath = validated.tracePath + [TraceNode(
        entity: child.entity.name, comment: validated.comment ?? "",
        purpose: validated.purpose ?? "", level: validated.tracePath.count + 2,
        kind: "relation", name: "\(validated.entity.name).\(aggregate.relationName)")]
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
      let rows = try await execute(child).records
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
      let relationParentCount = records.compactMap { $0[relation.localKey] }.count
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
        let localValues = records.compactMap { $0[relation.localKey] }
        guard !localValues.isEmpty else { return }
        var child = relation.query.makeQuery()
        child.tracePath = validated.tracePath + [TraceNode(
          entity: child.entity.name, comment: validated.comment ?? "",
          purpose: validated.purpose ?? "", level: validated.tracePath.count + 2,
          kind: "relation", name: "\(validated.entity.name).\(relation.name)")]
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
        if useProbes {
          for localValue in localValues {
            var probe = child
            probe.partitionBy = nil
            let join = TeaQLExpression.equal(relation.foreignKey, localValue)
            probe.filter = probe.filter.map { .and([$0, join]) } ?? join
            children.append(contentsOf: try await execute(probe).records)
          }
        } else {
          if child.limit != nil { child.partitionBy = relation.foreignKey }
          let join = TeaQLExpression.inList(relation.foreignKey, localValues)
          child.filter = child.filter.map { .and([$0, join]) } ?? join
          children = try await execute(child).records
        }
        let grouped = Dictionary(grouping: children) { $0[relation.foreignKey] ?? .null }
        for index in records.indices {
          let matches = grouped[records[index][relation.localKey] ?? .null] ?? []
          records[index][relation.name] = relation.many
            ? .array(matches.map(TeaQLValue.object))
            : matches.first.map(TeaQLValue.object) ?? .null
        }
      }
    }
    return QueryResult(
      records: records, backend: result.backend, trace: result.trace,
      metadata: result.metadata, facets: facets)
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
    var validated = try requestPolicy.apply(query).validatedForExecution()
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
      try await queryExecutor.count(validated)
    }
  }

  public func execute(_ mutation: Mutation) async throws -> MutationResult {
    try await execute(mutation, ledgerRoot: nil, ledgerKey: nil)
  }

  public func execute(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) async throws -> MutationResult {
    try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "mutation", name: "\(mutation.entity.name).\(mutation.kind.rawValue)",
        attributes: [
          "teaql.entity.type": .string(mutation.entity.name),
          "teaql.mutation.kind": .string(mutation.kind.rawValue),
        ]
      )
    ) {
      try await executeMutation(mutation, ledgerRoot: ledgerRoot, ledgerKey: ledgerKey)
    }
  }

  private func executeMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot?, ledgerKey: EntityKey?
  ) async throws -> MutationResult {
    var validated = try mutation.validatedForExecution()
    validated.actor = actor
    validated.auditCategory = auditCategory
    if let checker = runtime.checker(named: validated.entity.name) {
      let violations = translateCheckResults(
        try checker.checkAndFix(context: self, mutation: &validated, now: fixTime))
      if let ledgerRoot, let ledgerKey {
        for (field, value) in validated.values { ledgerRoot.set(ledgerKey, field: field, value: value) }
      }
      if !violations.isEmpty { throw CheckException(violations) }
    }
    let result = try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "provider", name: "\(mutationExecutor.providerKind).mutation",
        attributes: [
          "teaql.provider.kind": .string(mutationExecutor.providerKind),
          "teaql.provider.operation": .string(validated.kind.rawValue),
        ]
      )
    ) {
      try await mutationExecutor.execute(validated)
    }
    if let metadata = result.metadata {
      await telemetrySink?.record(metadata)
      if mutationSQLLogEnabled { await diagnosticSQLLogSink?.write(metadata) }
    }
    if let auditSink, let reason = validated.auditReason {
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
        try await auditSink.record(
          AuditEvent(
            entity: validated.entity.name,
            entityID: validated.id ?? result.generatedValues["id"],
            operation: validated.kind,
            reason: reason,
            actor: actor,
            category: auditCategory,
            occurredAt: Date()
          ))
      }
    }
    return result
  }

  public func preflightMutation(
    _ mutation: Mutation, ledgerRoot: EntityRoot? = nil, ledgerKey: EntityKey? = nil
  ) throws -> Mutation {
    var validated = try mutation.validatedForExecution()
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
    return validated
  }
}
