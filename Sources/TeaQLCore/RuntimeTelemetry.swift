import Foundation

public enum RuntimeTelemetryValue: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case double(Double)
  case boolean(Bool)
}

public struct RuntimeOperation: Sendable, Equatable {
  public let family: String
  public let name: String
  public let attributes: [String: RuntimeTelemetryValue]

  public init(
    family: String, name: String,
    attributes: [String: RuntimeTelemetryValue] = [:]
  ) {
    self.family = family
    self.name = name
    var safe: [String: RuntimeTelemetryValue] = [
      "teaql.operation.family": .string(family),
      "teaql.operation.name": .string(name),
    ]
    for (key, value) in attributes where !Self.forbiddenAttributes.contains(key) {
      safe[key] = value
    }
    self.attributes = safe
  }

  private static let forbiddenAttributes: Set<String> = [
    "teaql.entity.id", "teaql.user.id", "teaql.tenant.id",
    "teaql.query.parameters", "teaql.field.values", "teaql.audit.reason",
    "db.query.parameter_values", "http.request.body", "url.full",
  ]
}

public protocol RuntimeTelemetry: Sendable {
  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result
  func flush() async
  func shutdown() async
}

public extension RuntimeTelemetry {
  func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    try await withOperation(operation, completion: { _ in [:] }, body)
  }
}

public struct NoopRuntimeTelemetry: RuntimeTelemetry {
  public init() {}

  public func withOperation<Result: Sendable>(
    _ operation: RuntimeOperation,
    completion: @Sendable (Result) -> [String: RuntimeTelemetryValue],
    _ body: () async throws -> Result
  ) async rethrows -> Result {
    try await body()
  }

  public func flush() async {}
  public func shutdown() async {}
}
