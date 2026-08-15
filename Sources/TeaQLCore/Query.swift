import Foundation

public indirect enum TeaQLExpression: Sendable, Hashable, Codable {
  case equal(String, TeaQLValue)
  case greaterThanOrEqual(String, TeaQLValue)
  case lessThanOrEqual(String, TeaQLValue)
  case contains(String, String)
  case inList(String, [TeaQLValue])
  case and([TeaQLExpression])
  case or([TeaQLExpression])
}

public enum SortDirection: String, Sendable, Codable { case ascending, descending }

public struct OrderBy: Sendable, Hashable, Codable {
  public let field: String
  public let direction: SortDirection

  public init(_ field: String, _ direction: SortDirection) {
    self.field = field
    self.direction = direction
  }
}

public struct RelationLoad: Sendable, Hashable, Codable {
  public let name: String
  public let localKey: String
  public let foreignKey: String
  public let many: Bool
  public let query: RelationQueryPlan

  public init(
    name: String, localKey: String, foreignKey: String, many: Bool, query: SelectQuery
  ) {
    self.name = name
    self.localKey = localKey
    self.foreignKey = foreignKey
    self.many = many
    self.query = RelationQueryPlan(query)
  }
}

/// A non-recursive child-query snapshot. Runtime hydration deliberately loads
/// one relation level per plan so SelectQuery remains a value type.
public struct RelationQueryPlan: Sendable, Hashable, Codable {
  public let entity: EntityDescriptor
  public let filter: TeaQLExpression?
  public let orderBy: [OrderBy]
  public let offset: Int
  public let limit: Int?
  public let hardLimit: Int
  public let projection: [String]

  public init(_ query: SelectQuery) {
    entity = query.entity
    filter = query.filter
    orderBy = query.orderBy
    offset = query.offset
    limit = query.limit
    hardLimit = query.hardLimit
    projection = query.projection
  }

  public func makeQuery() -> SelectQuery {
    var query = SelectQuery(entity: entity)
    query.filter = filter
    query.orderBy = orderBy
    query.offset = offset
    query.limit = limit
    query.hardLimit = hardLimit
    query.projection = projection
    return query
  }
}

public struct SelectQuery: Sendable, Hashable, Codable {
  public static let defaultHardLimit = 10_000

  public let entity: EntityDescriptor
  public var filter: TeaQLExpression?
  public var orderBy: [OrderBy] = []
  public var offset: Int = 0
  public var limit: Int?
  public var hardLimit: Int = Self.defaultHardLimit
  public var projection: [String] = []
  public var relations: [RelationLoad] = []
  public var comment: String?
  public var purpose: String?

  public init(entity: EntityDescriptor) { self.entity = entity }

  @discardableResult
  public mutating func relationQuery(
    _ name: String, localKey: String, foreignKey: String, many: Bool = true,
    query: SelectQuery
  ) -> Self {
    relations.append(
      RelationLoad(
        name: name, localKey: localKey, foreignKey: foreignKey, many: many, query: query))
    return self
  }

  public func validatedForExecution() throws -> Self {
    guard let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TeaQLError.missingComment
    }
    guard let purpose, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TeaQLError.missingPurpose
    }
    guard hardLimit > 0, hardLimit <= Self.defaultHardLimit else {
      throw TeaQLError.invalidHardLimit(hardLimit)
    }
    if let limit {
      guard limit > 0 else { throw TeaQLError.invalidLimit(limit) }
      guard limit <= hardLimit else {
        throw TeaQLError.hardLimitExceeded(limit: limit, hardLimit: hardLimit)
      }
    }
    guard offset >= 0 else { throw TeaQLError.invalidOffset(offset) }
    return self
  }
}

public enum TeaQLError: Error, Sendable, Equatable {
  case missingComment
  case missingPurpose
  case missingAuditReason
  case missingResource(String)
  case invalidHardLimit(Int)
  case invalidLimit(Int)
  case hardLimitExceeded(limit: Int, hardLimit: Int)
  case invalidOffset(Int)
  case unknownEntity(String)
  case unknownProperty(entity: String, property: String)
  case optimisticLock(entity: String, id: TeaQLValue, expectedVersion: Int64)
  case execution(String)
}

public struct QueryResult: Sendable {
  public let records: [TeaQLRecord]
  public let backend: String
  public let trace: [TraceNode]
  public let metadata: SQLExecutionMetadata?

  public init(
    records: [TeaQLRecord],
    backend: String,
    trace: [TraceNode] = [],
    metadata: SQLExecutionMetadata? = nil
  ) {
    self.records = records
    self.backend = backend
    self.trace = trace
    self.metadata = metadata
  }
}

public struct TeaQLPage<Entity: Sendable>: Sendable {
  public let items: [Entity]
  public let total: Int
  public let offset: Int
  public let limit: Int

  public init(items: [Entity], total: Int, offset: Int, limit: Int) {
    self.items = items
    self.total = total
    self.offset = offset
    self.limit = limit
  }
}

public struct TraceNode: Sendable, Hashable, Codable {
  public let entity: String
  public let comment: String
  public let purpose: String

  public init(entity: String, comment: String, purpose: String) {
    self.entity = entity
    self.comment = comment
    self.purpose = purpose
  }
}
