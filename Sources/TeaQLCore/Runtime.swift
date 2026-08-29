import Foundation

public protocol QueryExecutor: Sendable {
  func execute(_ query: SelectQuery) async throws -> QueryResult
  func count(_ query: SelectQuery) async throws -> Int
}

/// Physical schema capability selected by a UserContext.
/// RuntimeModule installation remains passive; applications call UserContext.ensureSchema(_:).
package protocol SchemaExecutor: Sendable {
  func ensureSchema(_ module: RuntimeModule, context: UserContext) async throws
}

public extension QueryExecutor {
  var providerKind: String { String(describing: type(of: self)) }

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
  public let parameterizedSQL: String
  public let parameters: [TeaQLValue]
  public let debugSQL: String
  public let elapsedMicros: UInt64
  public let resultCount: Int?
  public let affectedRows: Int?
  public let resultSummary: String

  public init(
    operation: SQLExecutionOperation,
    parameterizedSQL: String,
    parameters: [TeaQLValue],
    debugSQL: String,
    elapsedMicros: UInt64,
    resultCount: Int? = nil,
    affectedRows: Int? = nil,
    resultSummary: String
  ) {
    self.operation = operation
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

  public init(
    kind: MutationKind,
    entity: EntityDescriptor,
    id: TeaQLValue? = nil,
    values: TeaQLRecord = [:],
    expectedVersion: Int64? = nil,
    auditReason: String? = nil,
    actor: String? = nil
  ) {
    self.kind = kind
    self.entity = entity
    self.id = id
    self.values = values
    self.expectedVersion = expectedVersion
    self.auditReason = auditReason
    self.actor = actor
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

public extension MutationExecutor {
  var providerKind: String { String(describing: type(of: self)) }
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
    var values = entity.toMutationRecord()
    let rooted = entity as? any TeaQLMutationRootedEntity
    if let rooted {
      if entity.id != 0 { values = rooted.teaqlEntityRoot.change(rooted.teaqlEntityKey) }
    }
    let mutation: Mutation
    if entity.version == 0 {
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
    let saved = try persistedEntity(from: await context.execute(
      mutation, ledgerRoot: rooted?.teaqlEntityRoot, ledgerKey: rooted?.teaqlEntityKey))
    if let rooted {
      let savedKey = EntityKey(entity: rooted.teaqlEntityKey.entity, id: .int(saved.id))
      rooted.teaqlEntityRoot.rekey(rooted.teaqlEntityKey, to: savedKey)
      rooted.teaqlEntityRoot.clearEntity(savedKey)
      rooted.teaqlEntityRoot.setOriginalVersion(savedKey, version: saved.version)
    }
    return saved
  }

  /// Soft-deletes a loaded entity using its original optimistic version.
  /// Providers retain the row with a negative version; physical deletion is
  /// deliberately not part of the public entity lifecycle.
  public func delete(_ context: UserContext) async throws -> Entity {
    guard entity.id != 0 else {
      throw TeaQLError.execution("Delete requires a loaded entity ID")
    }
    let rooted = entity as? any TeaQLMutationRootedEntity
    if let rooted { rooted.teaqlEntityRoot.markAsDeleted(rooted.teaqlEntityKey) }
    let saved = try persistedEntity(from: await context.execute(
      Mutation(
        kind: .delete,
        entity: Entity.descriptor,
        id: .int(entity.id),
        expectedVersion: entity.version,
        auditReason: reason
      ), ledgerRoot: rooted?.teaqlEntityRoot, ledgerKey: rooted?.teaqlEntityKey))
    if let rooted { rooted.teaqlEntityRoot.clearEntity(rooted.teaqlEntityKey) }
    return saved
  }

  private func persistedEntity(from result: MutationResult) throws -> Entity {
    guard let record = result.persistedRecord else {
      throw TeaQLError.execution(
        "Mutation executor did not return authoritative persisted state for \(Entity.descriptor.name)")
    }
    return try Entity.from(record: record)
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

private struct RetainedIdSet: Sendable {
  let ids: [Int64]
  let expiresAt: Date
}

private actor IdSetStore {
  static let shared = IdSetStore()
  private var sets: [String: RetainedIdSet] = [:]
  private var builds: [String: Task<RetainedIdSet, Error>] = [:]

  func obtain(
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
  /// Application-owned tenant identity. It is never populated from generated
  /// query or federation payloads.
  public let trustedTenant: String?
  public let activeRoot: ContextEntityRef?
  public let queryExecutor: any QueryExecutor
  public let mutationExecutor: any MutationExecutor
  public let requestPolicy: RequestPolicy
  public let auditSink: (any AuditSink)?
  public let telemetrySink: (any RuntimeTelemetrySink)?
  public let runtimeTelemetry: any RuntimeTelemetry
  public private(set) var locale: TeaQLLocale
  public private(set) var i18nCatalog: I18nCatalog
  private let entityInitializers: [EntityInitializer]
  private let entityCreationObserver: EntityCreationObserver?
  private let continuousPageState: ContinuousPageState
  private let idSetObservationState: IdSetObservationState

  public init(
    runtime: TeaQLRuntime = TeaQLRuntime(),
    actor: String? = nil,
    trustedTenant: String? = nil,
    activeRoot: ContextEntityRef? = nil,
    queryExecutor: any QueryExecutor,
    mutationExecutor: any MutationExecutor,
    requestPolicy: RequestPolicy,
    auditSink: (any AuditSink)? = nil,
    telemetrySink: (any RuntimeTelemetrySink)? = nil,
    runtimeTelemetry: any RuntimeTelemetry = NoopRuntimeTelemetry(),
    locale: TeaQLLocale = .en,
    i18nCatalog: I18nCatalog = .builtin,
    entityInitializers: [EntityInitializer] = [],
    entityCreationObserver: EntityCreationObserver? = nil
  ) {
    self.runtime = runtime
    self.actor = actor
    self.trustedTenant = trustedTenant
    self.activeRoot = activeRoot
    self.queryExecutor = queryExecutor
    self.mutationExecutor = mutationExecutor
    self.requestPolicy = requestPolicy
    self.auditSink = auditSink
    self.telemetrySink = telemetrySink
    self.runtimeTelemetry = runtimeTelemetry
    self.locale = locale
    self.i18nCatalog = i18nCatalog
    self.entityInitializers = entityInitializers
    self.entityCreationObserver = entityCreationObserver
    self.continuousPageState = ContinuousPageState()
    self.idSetObservationState = IdSetObservationState()
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
    if let metadata = result.metadata { await telemetrySink?.record(metadata) }
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
      try await runtimeTelemetry.withOperation(
        RuntimeOperation(
          family: "relation_load", name: "\(validated.entity.name).\(relation.name)",
          attributes: [
            "teaql.entity.type": .string(validated.entity.name),
            "teaql.relation.name": .string(relation.name),
          ]
        )
      ) {
        let localValues = records.compactMap { $0[relation.localKey] }
        guard !localValues.isEmpty else { return }
        var child = relation.query.makeQuery()
        // Relation assembly groups child rows by the foreign key. A generated
        // child projection may select only business fields, so the runtime must
        // retain this structural key even when the caller did not request it.
        if !child.projection.isEmpty && !child.projection.contains(relation.foreignKey) {
          child.projection.append(relation.foreignKey)
        }
        child.comment = validated.comment
        child.purpose = validated.purpose
        if child.limit != nil {
          child.partitionBy = relation.foreignKey
        }
        let join = TeaQLExpression.inList(relation.foreignKey, localValues)
        child.filter = child.filter.map { .and([$0, join]) } ?? join
        let children = try await execute(child).records
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
    let security = "\(actor ?? "")|\(trustedTenant ?? "")|\(activeRoot.map { "\($0.entity):\($0.id)" } ?? "")|\(requestPolicy.idSetIdentity)|\(queryExecutor.providerKind)"
    let key = "teaql:id-set:v1:\(options.namespace):\(security):\(encoded.base64EncodedString())"
    let stableSnapshot = stable
    do {
      let (retained, built) = try await IdSetStore.shared.obtain(key: key) {
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
    if let checker = runtime.checker(named: validated.entity.name) {
      let violations = translateCheckResults(
        try checker.checkAndFix(context: self, mutation: &validated, now: Date()))
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
    if let metadata = result.metadata { await telemetrySink?.record(metadata) }
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
            occurredAt: Date()
          ))
      }
    }
    return result
  }
}
