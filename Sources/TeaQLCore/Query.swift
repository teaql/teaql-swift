import Foundation

public indirect enum TeaQLExpression: Sendable, Hashable, Codable {
  case equal(String, TeaQLValue)
  case notEqual(String, TeaQLValue)
  case greaterThan(String, TeaQLValue)
  case greaterThanOrEqual(String, TeaQLValue)
  case lessThan(String, TeaQLValue)
  case lessThanOrEqual(String, TeaQLValue)
  case between(String, TeaQLValue, TeaQLValue)
  case contains(String, String)
  case notContains(String, String)
  case startsWith(String, String)
  case notStartsWith(String, String)
  case endsWith(String, String)
  case notEndsWith(String, String)
  case soundingLike(String, String)
  case inList(String, [TeaQLValue])
  case notInList(String, [TeaQLValue])
  case inSubquery(String, RelationQueryPlan, String)
  case notInSubquery(String, RelationQueryPlan, String)
  case isNull(String)
  case isNotNull(String)
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

public enum AggregateFunction: String, Sendable, Hashable, Codable {
  case count, min, max, sum, avg
}

public struct QueryAggregate: Sendable, Hashable, Codable {
  public let function: AggregateFunction
  public let field: String
  public let alias: String

  public init(_ function: AggregateFunction, field: String, alias: String) {
    self.function = function
    self.field = field
    self.alias = alias
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

public struct RelationAggregateLoad: Sendable, Hashable, Codable {
  public let relationName: String
  public let foreignKey: String
  public let alias: String
  public let query: RelationQueryPlan
  public let singleResult: Bool

  public init(
    relationName: String, foreignKey: String, alias: String, query: SelectQuery,
    singleResult: Bool = true
  ) {
    self.relationName = relationName
    self.foreignKey = foreignKey
    self.alias = alias
    self.query = RelationQueryPlan(query)
    self.singleResult = singleResult
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
  public let groupBy: [String]
  public let aggregates: [QueryAggregate]
  public let partitionBy: String?

  public init(_ query: SelectQuery) {
    entity = query.entity
    filter = query.filter
    orderBy = query.orderBy
    offset = query.offset
    limit = query.limit
    hardLimit = query.hardLimit
    projection = query.projection
    groupBy = query.groupBy
    aggregates = query.aggregates
    partitionBy = query.partitionBy
  }

  public func makeQuery() -> SelectQuery {
    var query = SelectQuery(entity: entity)
    query.filter = filter
    query.orderBy = orderBy
    query.offset = offset
    query.limit = limit
    query.hardLimit = hardLimit
    query.projection = projection
    query.groupBy = groupBy
    query.aggregates = aggregates
    query.partitionBy = partitionBy
    return query
  }
}

public struct FacetRequest: Sendable, Hashable, Codable {
  public let name: String
  public let relationName: String
  public let query: RelationQueryPlan
  public let includeAllFacets: Bool

  public init(
    name: String, relationName: String, query: SelectQuery, includeAllFacets: Bool = true
  ) {
    self.name = name
    self.relationName = relationName
    self.query = RelationQueryPlan(query)
    self.includeAllFacets = includeAllFacets
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
  public var groupBy: [String] = []
  public var aggregates: [QueryAggregate] = []
  /// Internal relation-loading scope. When paired with a limit, the slice is
  /// applied independently to every distinct value of this field.
  public var partitionBy: String?
  public var relations: [RelationLoad] = []
  public var relationAggregates: [RelationAggregateLoad] = []
  public var facets: [FacetRequest] = []
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

  @discardableResult
  public mutating func relationAggregate(
    _ relationName: String, foreignKey: String, alias: String, query: SelectQuery,
    singleResult: Bool = true
  ) -> Self {
    relationAggregates.append(
      RelationAggregateLoad(
        relationName: relationName, foreignKey: foreignKey, alias: alias, query: query,
        singleResult: singleResult))
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
  case unsupportedQueryCapability(String)
}

public struct QueryResult: Sendable {
  public let records: [TeaQLRecord]
  public let backend: String
  public let trace: [TraceNode]
  public let metadata: SQLExecutionMetadata?
  public let facets: [String: SmartList<TeaQLRecord>]

  public init(
    records: [TeaQLRecord],
    backend: String,
    trace: [TraceNode] = [],
    metadata: SQLExecutionMetadata? = nil,
    facets: [String: SmartList<TeaQLRecord>] = [:]
  ) {
    self.records = records
    self.backend = backend
    self.trace = trace
    self.metadata = metadata
    self.facets = facets
  }
}

public struct TeaQLPage<Entity: Sendable>: Sendable {
  public let items: SmartList<Entity>
  public let total: Int
  public let offset: Int
  public let limit: Int

  public init(items: SmartList<Entity>, total: Int, offset: Int, limit: Int) {
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
