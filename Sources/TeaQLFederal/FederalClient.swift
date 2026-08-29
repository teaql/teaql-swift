import Foundation
import TeaQLCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public enum FederalError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidBaseURL(String)
  case missingComment
  case missingPurpose
  case missingAuditReason
  case unsupportedExpression(String)
  case transport(status: Int, message: String)
  case invalidResponse(String)

  public var description: String {
    switch self {
    case .invalidBaseURL(let value): "Invalid TeaQL federation base URL: \(value)"
    case .missingComment: "TeaQL federation query comment is required"
    case .missingPurpose: "TeaQL federation query purpose is required"
    case .missingAuditReason: "TeaQL federation mutation audit reason is required"
    case .unsupportedExpression(let value): "Unsupported TeaQL federation expression: \(value)"
    case .transport(let status, let message): "TeaQL federation HTTP \(status): \(message)"
    case .invalidResponse(let value): "Invalid TeaQL federation response: \(value)"
    }
  }
}

public struct FederalHTTPRequest: Sendable {
  public let url: URL
  public let headers: [String: String]
  public let body: Data

  public init(url: URL, headers: [String: String], body: Data) {
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct FederalHTTPResponse: Sendable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public protocol FederalTransport: Sendable {
  func send(_ request: FederalHTTPRequest) async throws -> FederalHTTPResponse
}

public struct URLSessionFederalTransport: FederalTransport {
  private let session: URLSession

  public init(session: URLSession = .shared) { self.session = session }

  public func send(_ request: FederalHTTPRequest) async throws -> FederalHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = "POST"
    urlRequest.httpBody = request.body
    for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
    let (body, response) = try await session.data(for: urlRequest)
    guard let response = response as? HTTPURLResponse else {
      throw FederalError.invalidResponse("missing HTTP response")
    }
    return FederalHTTPResponse(status: response.statusCode, body: body)
  }
}

public struct FederalQuery: Sendable {
  public var entity: String
  public var filters: [TeaQLExpression] = []
  public var limit: Int?
  public var offset: Int?
  public var orderBy: [OrderBy] = []
  public var select: [String] = []
  public var groupBy: [String] = []
  public var aggregates: [FederalAggregate] = []
  public var comment: String?
  public var purpose: String?

  public init(entity: String) { self.entity = entity }
}

public struct FederalAggregate: Sendable, Codable, Equatable {
  public let function: String
  public let field: String
  public let alias: String

  public init(function: String, field: String, alias: String) {
    self.function = function
    self.field = field
    self.alias = alias
  }
}

public struct FederalMutation: Sendable {
  public let entity: String
  public let action: MutationKind
  public let payload: TeaQLRecord
  public let id: TeaQLValue?
  public let expectedVersion: Int64?
  public let auditReason: String

  public init(
    entity: String,
    action: MutationKind,
    payload: TeaQLRecord,
    id: TeaQLValue? = nil,
    expectedVersion: Int64? = nil,
    auditReason: String
  ) {
    self.entity = entity
    self.action = action
    self.payload = payload
    self.id = id
    self.expectedVersion = expectedVersion
    self.auditReason = auditReason
  }
}

public struct FederalQueryResponse: Sendable, Decodable {
  public let data: [TeaQLRecord]
  public let resultCode: Int?
  public let status: String?
  public let execution: TeaQLRecord?
}

public struct FederalMutationResponse: Sendable, Decodable {
  public let affectedRows: Int
  public let data: [TeaQLRecord]
  public let resultCode: Int?
  public let status: String?
}

public struct TeaQLFederalClient: Sendable {
  public typealias HeaderProvider = @Sendable () async throws -> [String: String]

  private let baseURL: URL
  private let transport: any FederalTransport
  private let headerProvider: HeaderProvider?
  private let runtimeTelemetry: any RuntimeTelemetry

  public init(
    baseURL: URL,
    transport: any FederalTransport = URLSessionFederalTransport(),
    headerProvider: HeaderProvider? = nil,
    runtimeTelemetry: any RuntimeTelemetry = NoopRuntimeTelemetry()
  ) {
    self.baseURL = baseURL
    self.transport = transport
    self.headerProvider = headerProvider
    self.runtimeTelemetry = runtimeTelemetry
  }

  public func execute(_ query: FederalQuery) async throws -> FederalQueryResponse {
    guard let comment = nonBlank(query.comment) else { throw FederalError.missingComment }
    guard let purpose = nonBlank(query.purpose) else { throw FederalError.missingPurpose }
    if let limit = query.limit, limit < 1 {
      throw TeaQLError.execution("Federation limit must be positive")
    }
    if let offset = query.offset, offset < 0 { throw TeaQLError.invalidOffset(offset) }

    var payload: [String: TeaQLValue] = [
      "entity": .string(query.entity),
      "orderItems": .array(
        query.orderBy.map {
          .object([
            "field": .string($0.field),
            "direction": .string($0.direction == .ascending ? "Asc" : "Desc"),
          ])
        }),
      "selectItems": .array(query.select.map(TeaQLValue.string)),
      "groupByItems": .array(query.groupBy.map(TeaQLValue.string)),
      "aggregateItems": .array(
        query.aggregates.map {
          .object([
            "function": .string($0.function), "field": .string($0.field),
            "alias": .string($0.alias),
          ])
        }),
      "commentText": .string(comment),
      "purposeText": .string(purpose),
    ]
    let filters = try query.filters.map(encodeExpression)
    if filters.count == 1 { payload["filterCondition"] = filters[0] }
    else if !filters.isEmpty { payload["filterCondition"] = .object(["$and": .array(filters)]) }
    if let limit = query.limit { payload["limitValue"] = .int(Int64(limit)) }
    if let offset = query.offset { payload["offsetValue"] = .int(Int64(offset)) }
    return try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "tfp", name: "client.query",
        attributes: ["teaql.tfp.role": .string("client")]
      )
    ) {
      try await post(path: "query", payload: payload, as: FederalQueryResponse.self)
    }
  }

  public func execute(_ mutation: FederalMutation) async throws -> FederalMutationResponse {
    guard let reason = nonBlank(mutation.auditReason) else { throw FederalError.missingAuditReason }
    var payload: [String: TeaQLValue] = [
      "entity": .string(mutation.entity),
      "action": .string(actionName(mutation.action)),
      "payload": .object(mutation.payload),
      "comment": .string(reason),
    ]
    if let id = mutation.id { payload["id"] = id }
    if let version = mutation.expectedVersion { payload["expectedVersion"] = .int(version) }
    return try await runtimeTelemetry.withOperation(
      RuntimeOperation(
        family: "tfp", name: "client.mutation",
        attributes: ["teaql.tfp.role": .string("client")]
      )
    ) {
      try await post(path: "mutate", payload: payload, as: FederalMutationResponse.self)
    }
  }

  private func post<Response: Decodable>(
    path: String,
    payload: [String: TeaQLValue],
    as type: Response.Type
  ) async throws -> Response {
    var headers = ["Content-Type": "application/json", "Accept": "application/json"]
    if let supplied = try await headerProvider?() {
      for (name, value) in supplied { headers[name] = value }
    }
    runtimeTelemetry.inject(&headers)
    let request = FederalHTTPRequest(
      url: baseURL.appendingPathComponent(path),
      headers: headers,
      body: try JSONEncoder().encode(payload)
    )
    let response = try await transport.send(request)
    guard (200..<300).contains(response.status) else {
      let message = String(data: response.body, encoding: .utf8) ?? "non-text response"
      throw FederalError.transport(status: response.status, message: message)
    }
    do { return try JSONDecoder().decode(type, from: response.body) } catch {
      throw FederalError.invalidResponse(String(describing: error))
    }
  }

  private func encodeExpression(_ expression: TeaQLExpression) throws -> TeaQLValue {
    switch expression {
    case .equal(let field, let value): return .object([field: .object(["$eq": value])])
    case .greaterThanOrEqual(let field, let value):
      return .object([field: .object(["$gte": value])])
    case .lessThanOrEqual(let field, let value): return .object([field: .object(["$lte": value])])
    case .contains(let field, let value):
      return .object([field: .object(["$contains": .string(value)])])
    case .inList(let field, let values): return .object([field: .object(["$in": .array(values)])])
    case .notEqual, .greaterThan, .lessThan, .between, .notContains,
         .startsWith, .notStartsWith, .endsWith, .notEndsWith, .notInList,
         .isNull, .isNotNull, .soundingLike, .inSubquery, .notInSubquery:
      throw FederalError.unsupportedExpression(String(describing: expression))
    case .and(let values): return .object(["$and": .array(try values.map(encodeExpression))])
    case .or(let values): return .object(["$or": .array(try values.map(encodeExpression))])
    }
  }

  private func nonBlank(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func actionName(_ kind: MutationKind) -> String {
    switch kind {
    case .create: "Create"
    case .update: "Update"
    case .delete: "Delete"
    case .recover: "Recover"
    }
  }
}

/// Adapts the canonical TeaQL Federal Protocol to the same executors used by
/// generated requests and audited entity saves. Trusted policy remains in the
/// caller's `UserContext`; it is applied before this adapter receives a query.
public struct FederalDataService: QueryExecutor, MutationExecutor, Sendable {
  public let client: TeaQLFederalClient

  public init(client: TeaQLFederalClient) { self.client = client }

  public func execute(_ query: SelectQuery) async throws -> QueryResult {
    var federal = FederalQuery(entity: query.entity.name)
    if let filter = query.filter { federal.filters = [filter] }
    federal.limit = query.limit
    federal.offset = query.offset == 0 ? nil : query.offset
    federal.orderBy = query.orderBy
    federal.select = query.projection
    federal.comment = query.comment
    federal.purpose = query.purpose
    let response = try await client.execute(federal)
    return QueryResult(
      records: response.data,
      backend: "teaql-federal",
      trace: [
        TraceNode(
          entity: query.entity.name,
          comment: query.comment ?? "",
          purpose: query.purpose ?? ""
        )
      ]
    )
  }

  public func execute(_ mutation: Mutation) async throws -> MutationResult {
    let response = try await client.execute(
      FederalMutation(
        entity: mutation.entity.name,
        action: mutation.kind,
        payload: mutation.values,
        id: mutation.id,
        auditReason: mutation.auditReason ?? ""
      ))
    return MutationResult(
      affectedRows: response.affectedRows,
      generatedValues: response.data.first ?? [:],
      persistedRecord: response.data.first
    )
  }
}
