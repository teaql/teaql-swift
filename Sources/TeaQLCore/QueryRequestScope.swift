import Foundation

/// Supplied by generated Q methods, never inferred from SQL or result aliases.
public struct QueryOperation: Sendable, Hashable {
  public let kind: String
  public let method: String
  public let alias: String?
  public let relation: String?
  public init(_ kind: String, method: String, alias: String? = nil, relation: String? = nil) {
    self.kind = kind; self.method = method; self.alias = alias; self.relation = relation
  }
  public var comment: String {
    if let alias { return "\(method)(\(String(reflecting: alias)))" }
    return "\(method)(...)"
  }
}

/// Immutable invocation-local ancestry; not query JSON, Context state or a ledger.
public final class QueryRequestScope: Sendable, Hashable, CustomStringConvertible {
  public let parent: QueryRequestScope?
  public let entity: String
  public let comment: String
  public let operation: QueryOperation?
  package let explicitComment: String?
  private let rootIntent: QueryIntent?
  private let facetRelation: String?
  public var root: QueryRequestScope { parent?.root ?? self }
  public var purpose: String { root.rootIntent!.purpose }
  public var description: String { "QueryRequestScope(<redacted>)" }
  public static func == (left: QueryRequestScope, right: QueryRequestScope) -> Bool { left === right }
  public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

  package init(entity: String, intent: QueryIntent) {
    self.entity = entity; comment = intent.comment; explicitComment = intent.comment
    rootIntent = intent; parent = nil; operation = nil; facetRelation = nil
  }
  private init(parent: QueryRequestScope, entity: String, comment: String,
    explicitComment: String?, operation: QueryOperation? = nil, facetRelation: String? = nil) {
    self.parent = parent; self.entity = entity; self.comment = comment
    self.explicitComment = explicitComment; self.operation = operation
    self.facetRelation = facetRelation; rootIntent = nil
  }
  public func derive(_ operation: QueryOperation) -> QueryRequestScope {
    QueryRequestScope(parent: self, entity: entity, comment: operation.comment,
      explicitComment: operation.comment, operation: operation)
  }
  package func helper(entity: String, comment: String) -> QueryRequestScope {
    QueryRequestScope(parent: self, entity: entity, comment: comment, explicitComment: nil)
  }
  package func child(entity: String, comment: String?) throws -> QueryRequestScope {
    let intent = try QueryIntent(comment: comment ?? "load \(entity)", purpose: purpose)
    return QueryRequestScope(parent: self, entity: entity, comment: intent.comment, explicitComment: comment)
  }
  package func facet(_ operation: QueryOperation?, relation: String, alias: String) -> QueryRequestScope {
    QueryRequestScope(parent: self, entity: entity,
      comment: operation?.comment ?? "facet(\(String(reflecting: alias)))", explicitComment: nil,
      operation: operation, facetRelation: operation?.relation ?? relation)
  }
  package var isFacet: Bool { facetRelation != nil }
  package var relation: String { facetRelation ?? operation?.relation ?? entity }
  public func recover() -> [TraceNode] {
    var values: [QueryRequestScope] = []; var cursor: QueryRequestScope? = self
    while let node = cursor { values.append(node); cursor = node.parent }
    return [TraceNode(entity: root.entity, comment: purpose, purpose: "", kind: "purpose")]
      + values.reversed().enumerated().map { index, node in
        TraceNode(entity: node.entity, comment: node.comment, purpose: "", level: index + 1,
          kind: "comment", name: node.operation?.method ?? node.entity)
      }
  }
}
