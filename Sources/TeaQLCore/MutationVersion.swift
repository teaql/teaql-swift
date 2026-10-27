/// A typed, value-free diagnostic. Trusted code can inspect the submitted
/// version without accidentally putting its value into user-facing logs.
public struct MutationVersionError: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Code: String, Sendable { case invalidState = "INVALID_VERSION_STATE", exhausted = "VERSION_EXHAUSTED" }
  public let code: Code
  public let operation: MutationKind
  public let originalVersion: Int64?
  public var description: String { "\(code.rawValue): invalid \(operation.rawValue) version transition" }
}

/// Optimistic versions have one signed-64-bit lifecycle on every provider.
/// Arithmetic is admitted before customer Fix/policy and before provider I/O.
public enum MutationVersion {
  public static func next(for operation: MutationKind, original: Int64? = nil) throws -> Int64 {
    if operation == .create { return 1 }
    guard let version = original else {
      throw MutationVersionError(code: .invalidState, operation: operation, originalVersion: original)
    }
    if operation == .recover {
      guard version < 0 else {
        throw MutationVersionError(code: .invalidState, operation: operation, originalVersion: version)
      }
      guard version >= Int64.min + 2 else {
        throw MutationVersionError(code: .exhausted, operation: operation, originalVersion: version)
      }
      return -version + 1
    }
    guard version > 0 else {
      throw MutationVersionError(code: .invalidState, operation: operation, originalVersion: version)
    }
    // Do not evaluate -(version + 1): deleting Int64.max is legal and must
    // produce Int64.min without overflowing the intermediate expression.
    if operation == .delete { return -version - 1 }
    guard version < Int64.max else {
      throw MutationVersionError(code: .exhausted, operation: operation, originalVersion: version)
    }
    return version + 1
  }

  public static func validate(_ mutation: Mutation) throws {
    // Preserve versionless trusted updates; do not invent a blind-delete API.
    if mutation.kind == .update && mutation.entity.versionProperty == nil && mutation.expectedVersion == nil { return }
    _ = try next(for: mutation.kind, original: mutation.expectedVersion)
  }
}
