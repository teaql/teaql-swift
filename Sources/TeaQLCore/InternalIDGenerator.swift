import Foundation

/// Reserves identity, not business data. Errors propagate without fallback.
/// Applications select a generator through trusted UserContext initialization.
public protocol InternalIDGenerator: Sendable {
  func nextID(for entity: String, context: UserContext) async throws -> Int64
}

public enum InternalIDError: Error, Sendable, Equatable {
  case invalidEntityName
  case unavailable
  case invalidValue(Int64)
  case exhausted(String)
  case activeGraph
}

/// Explicit opt-in for isolated in-memory consumers and tests. Persistent
/// applications use their provider's durable allocator instead.
public actor InMemoryInternalIDGenerator: InternalIDGenerator {
  private let initialFloor: Int64
  private var levels: [String: Int64] = [:]

  public init(initialFloor: Int64 = 0) throws {
    guard initialFloor >= 0 else { throw InternalIDError.invalidValue(initialFloor) }
    self.initialFloor = initialFloor
  }

  public func nextID(for entity: String, context: UserContext) throws -> Int64 {
    try Task.checkCancellation()
    guard !entity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw InternalIDError.invalidEntityName
    }
    let current = levels[entity] ?? initialFloor
    guard current < Int64.max else { throw InternalIDError.exhausted(entity) }
    let next = current + 1
    levels[entity] = next
    return next
  }
}
