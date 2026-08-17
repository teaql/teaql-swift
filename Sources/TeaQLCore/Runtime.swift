import Foundation

public protocol QueryExecutor: Sendable {
  func execute(_ query: SelectQuery) async throws -> QueryResult
  func count(_ query: SelectQuery) async throws -> Int
}

public extension QueryExecutor {
  func count(_ query: SelectQuery) async throws -> Int {
    throw TeaQLError.execution(
      "Exact count is not supported by the configured query executor for \(query.entity.name)")
  }
}

public enum MutationKind: String, Sendable, Codable { case create, update, delete, recover }

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

public protocol AuditSink: Sendable {
  func record(_ event: AuditEvent) async throws
}

public struct AuditedEntity<Entity: TeaQLEntity>: Sendable {
  public let entity: Entity
  public let reason: String

  public func save(_ context: UserContext) async throws -> Entity {
    var values = entity.toMutationRecord()
    let mutation: Mutation
    if entity.id == 0 {
      values.removeValue(forKey: Entity.descriptor.idProperty?.name ?? "id")
      mutation = Mutation(
        kind: .create,
        entity: Entity.descriptor,
        values: values,
        auditReason: reason
      )
    } else {
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
    return try persistedEntity(from: await context.execute(mutation))
  }

  /// Soft-deletes a loaded entity using its original optimistic version.
  /// Providers retain the row with a negative version; physical deletion is
  /// deliberately not part of the public entity lifecycle.
  public func delete(_ context: UserContext) async throws -> Entity {
    guard entity.id != 0 else {
      throw TeaQLError.execution("Delete requires a loaded entity ID")
    }
    return try persistedEntity(from: await context.execute(
      Mutation(
        kind: .delete,
        entity: Entity.descriptor,
        id: .int(entity.id),
        expectedVersion: entity.version,
        auditReason: reason
      )))
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

  public init(apply: @escaping @Sendable (SelectQuery) throws -> SelectQuery) {
    self.apply = apply
  }
}

public typealias EntityInitializer = @Sendable (
  _ context: UserContext, _ entityName: String, _ entity: inout any TeaQLEntity
) -> Void

public typealias EntityCreationObserver = @Sendable (
  _ context: UserContext, _ entityName: String, _ entity: any TeaQLEntity
) -> Void

public struct UserContext: Sendable {
  public let runtime: TeaQLRuntime
  public let actor: String?
  /// Application-owned tenant identity. It is never populated from generated
  /// query or federation payloads.
  public let trustedTenant: String?
  public let queryExecutor: any QueryExecutor
  public let mutationExecutor: any MutationExecutor
  public let requestPolicy: RequestPolicy
  public let auditSink: (any AuditSink)?
  public let telemetrySink: (any RuntimeTelemetrySink)?
  private let entityInitializers: [EntityInitializer]
  private let entityCreationObserver: EntityCreationObserver?

  public init(
    runtime: TeaQLRuntime = TeaQLRuntime(),
    actor: String? = nil,
    trustedTenant: String? = nil,
    queryExecutor: any QueryExecutor,
    mutationExecutor: any MutationExecutor,
    requestPolicy: RequestPolicy,
    auditSink: (any AuditSink)? = nil,
    telemetrySink: (any RuntimeTelemetrySink)? = nil,
    entityInitializers: [EntityInitializer] = [],
    entityCreationObserver: EntityCreationObserver? = nil
  ) {
    self.runtime = runtime
    self.actor = actor
    self.trustedTenant = trustedTenant
    self.queryExecutor = queryExecutor
    self.mutationExecutor = mutationExecutor
    self.requestPolicy = requestPolicy
    self.auditSink = auditSink
    self.telemetrySink = telemetrySink
    self.entityInitializers = entityInitializers
    self.entityCreationObserver = entityCreationObserver
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
    let validated = try requestPolicy.apply(query).validatedForExecution()
    var base = validated
    base.relations = []
    let result = try await queryExecutor.execute(base)
    if let metadata = result.metadata { await telemetrySink?.record(metadata) }
    guard !validated.relations.isEmpty, !result.records.isEmpty else { return result }

    var records = result.records
    for relation in validated.relations {
      let localValues = records.compactMap { $0[relation.localKey] }
      guard !localValues.isEmpty else { continue }
      var child = relation.query.makeQuery()
      child.comment = validated.comment
      child.purpose = validated.purpose
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
    return QueryResult(
      records: records, backend: result.backend, trace: result.trace, metadata: result.metadata)
  }

  public func count(_ query: SelectQuery) async throws -> Int {
    var validated = try requestPolicy.apply(query).validatedForExecution()
    validated.orderBy = []
    validated.offset = 0
    validated.limit = nil
    validated.projection = []
    validated.relations = []
    return try await queryExecutor.count(validated)
  }

  public func execute(_ mutation: Mutation) async throws -> MutationResult {
    var validated = try mutation.validatedForExecution()
    validated.actor = actor
    let result = try await mutationExecutor.execute(validated)
    if let metadata = result.metadata { await telemetrySink?.record(metadata) }
    if let auditSink, let reason = validated.auditReason {
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
    return result
  }
}
