import Foundation

/// Immutable provider-loaded values. Sharing these never shares mutation ownership.
/// Record access returns a Swift value copy; callers cannot modify the stored record.
public final class LoadedEntitySnapshot: Sendable {
  public let key: EntityKey
  public let version: Int64
  public let record: TeaQLRecord

  fileprivate init(key: EntityKey, version: Int64, record: TeaQLRecord) {
    self.key = key; self.version = version; self.record = record
  }
}

/// A single query's immutable snapshot pool, not a Context-wide identity/ledger map.
/// Different versions or projections stay separate; do not union partial records.
public final class LoadedEntitySnapshots: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [EntityKey: [LoadedEntitySnapshot]] = [:]

  public init() {}

  public func capture(key: EntityKey, version: Int64, record: TeaQLRecord) -> LoadedEntitySnapshot {
    lock.withLock {
      if let snapshot = snapshots[key]?.first(where: { $0.version == version && $0.record == record }) {
        return snapshot
      }
      let snapshot = LoadedEntitySnapshot(key: key, version: version, record: record)
      snapshots[key, default: []].append(snapshot)
      return snapshot
    }
  }
}
