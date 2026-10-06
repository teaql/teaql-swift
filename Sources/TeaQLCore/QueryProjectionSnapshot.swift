/// Query-only aliases retained independently of modeled fields and mutation ownership.
/// TeaQLValue has value semantics, including nested arrays/objects: reads cannot
/// mutate this snapshot. Missing is distinct from an explicit null or zero.
public struct QueryProjectionSnapshot: Sendable {
  private let values: TeaQLRecord

  public init(record: TeaQLRecord = [:], excluding fields: Set<String> = []) {
    values = record.filter { !fields.contains($0.key) }
  }

  public func contains(_ alias: String) -> Bool { values[alias] != nil }

  public func get(_ alias: String) throws -> TeaQLValue {
    guard let value = values[alias] else {
      throw QueryProjectionNotLoaded(alias: alias)
    }
    return value
  }
}

public struct QueryProjectionNotLoaded: Error, Sendable, Equatable, CustomStringConvertible {
  public let alias: String
  public init(alias: String) { self.alias = alias }
  public var description: String {
    "Query projection '\(alias)' is NotLoaded; request the alias in the query before reading it"
  }
}
