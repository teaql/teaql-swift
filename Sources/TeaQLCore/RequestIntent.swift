import Foundation

public struct RequestIntentError: Error, Sendable, Equatable, CustomStringConvertible {
  public let code: String
  public let field: String
  public let requestKind: String
  public init(code: String, field: String, requestKind: String) {
    self.code = code; self.field = field; self.requestKind = requestKind
  }
  public var description: String {
    "\(code): \(requestKind) request requires a non-blank \(field); supply it on this request"
  }
}

// Rust Unicode White_Space semantics. Foundation's character sets are not the
// contract: BOM and zero-width space are not blank intent, NEL is blank intent.
private func requiredIntent(_ text: String?, kind: String, field: String) throws -> String {
  func whitespace(_ value: UInt32) -> Bool {
    switch value {
    case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
      0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
    default: false
    }
  }
  guard let text, !text.unicodeScalars.allSatisfy({ whitespace($0.value) }) else {
    throw RequestIntentError(code: field == "purpose" ? "QUERY_PURPOSE_REQUIRED" : "REQUEST_COMMENT_REQUIRED",
      field: field, requestKind: kind)
  }
  return text
}

public struct QueryIntent: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
  public let comment: String
  public let purpose: String
  public init(comment: String?, purpose: String?) throws {
    self.comment = try requiredIntent(comment, kind: "query", field: "comment")
    self.purpose = try requiredIntent(purpose, kind: "query", field: "purpose")
  }
  private enum CodingKeys: String, CodingKey { case comment, purpose }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(comment: try? values.decode(String.self, forKey: .comment),
      purpose: try? values.decode(String.self, forKey: .purpose))
  }
  public var description: String { "QueryIntent(<redacted>)" }
  public var debugDescription: String { description }
}

public struct MutationIntent: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
  public let comment: String
  public var auditReason: String { comment }
  public init(comment: String?) throws {
    self.comment = try requiredIntent(comment, kind: "mutation", field: "comment")
  }
  private enum CodingKeys: String, CodingKey { case comment }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(comment: try? values.decode(String.self, forKey: .comment))
  }
  public func readbackIntent() throws -> QueryIntent {
    try QueryIntent(comment: comment, purpose: "verify the persisted mutation result")
  }
  public var description: String { "MutationIntent(<redacted>)" }
  public var debugDescription: String { description }
}

/// Request ownership is independent of Context, optional trace and builder copies.
public struct QueryRequest: Sendable {
  private let payload: SelectQuery
  public let intent: QueryIntent
  public init(query: SelectQuery) throws {
    self.init(query: query, intent: try QueryIntent(comment: query.comment, purpose: query.purpose))
  }
  public init(query: SelectQuery, intent: QueryIntent) {
    self.payload = query
    self.intent = intent
  }
  public var query: SelectQuery {
    var value = payload
    value.comment = intent.comment
    value.purpose = intent.purpose
    return value
  }
  public func withQuery(_ query: SelectQuery) -> Self { Self(query: query, intent: intent) }
}

/// The root comment is the audit reason; no second required purpose is added.
public struct MutationRequest: Sendable {
  private let payload: Mutation
  public let intent: MutationIntent
  public init(mutation: Mutation) throws {
    self.init(mutation: mutation, intent: try MutationIntent(comment: mutation.auditReason))
  }
  public init(mutation: Mutation, comment: String?) throws {
    self.init(mutation: mutation, intent: try MutationIntent(comment: comment))
  }
  public init(mutation: Mutation, intent: MutationIntent) {
    self.payload = mutation
    self.intent = intent
  }
  public var mutation: Mutation {
    var value = payload
    value.auditReason = intent.auditReason
    return value
  }
  public func withMutation(_ mutation: Mutation) -> Self { Self(mutation: mutation, intent: intent) }
}

/// A graph callback cannot use a child's reason to fill a missing root reason.
public struct GraphMutationRequest: Sendable {
  public let intent: MutationIntent
  public init(comment: String?) throws { intent = try MutationIntent(comment: comment) }
}
