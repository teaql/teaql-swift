import Foundation

public struct EntityKey: Sendable, Hashable {
  public let entity: String
  public let id: TeaQLValue
  public init(entity: String, id: TeaQLValue) {
    precondition(!entity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.entity = entity
    self.id = id
  }
}

/// Pending mutation ledger shared by one generated object graph.
public final class EntityRoot: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [EntityKey: TeaQLRecord] = [:]
  private var originalVersions: [EntityKey: Int64] = [:]
  private var newKeys: Set<EntityKey> = []
  private var deletedKeys: Set<EntityKey> = []

  public init() {}

  public func set(_ key: EntityKey, field: String, value: TeaQLValue) {
    precondition(!field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    lock.lock(); defer { lock.unlock() }
    changes[key, default: [:]][field] = value
  }

  public func snapshot() -> [EntityKey: TeaQLRecord] {
    lock.lock(); defer { lock.unlock() }
    return changes
  }

  public func change(_ key: EntityKey) -> TeaQLRecord {
    lock.lock(); defer { lock.unlock() }; return changes[key] ?? [:]
  }

  public func merge(from other: EntityRoot) {
    if other === self { return }
    let state = other.fullSnapshot()
    lock.lock(); defer { lock.unlock() }
    for (key, values) in state.changes { for (field, value) in values { changes[key, default: [:]][field] = value } }
    for (key, version) in state.versions { originalVersions[key] = version }
    newKeys.formUnion(state.newKeys); deletedKeys.formUnion(state.deletedKeys)
  }

  private func fullSnapshot() -> (changes: [EntityKey: TeaQLRecord], versions: [EntityKey: Int64], newKeys: Set<EntityKey>, deletedKeys: Set<EntityKey>) {
    lock.lock(); defer { lock.unlock() }; return (changes, originalVersions, newKeys, deletedKeys)
  }

  public func rekey(_ oldKey: EntityKey, to newKey: EntityKey) {
    guard oldKey != newKey else { return }
    lock.lock(); defer { lock.unlock() }
    if let values = changes.removeValue(forKey: oldKey) { for (field, value) in values { changes[newKey, default: [:]][field] = value } }
    if let version = originalVersions.removeValue(forKey: oldKey) { originalVersions[newKey] = version }
    if newKeys.remove(oldKey) != nil { newKeys.insert(newKey) }
    if deletedKeys.remove(oldKey) != nil { deletedKeys.insert(newKey) }
  }

  public func clearEntity(_ key: EntityKey) {
    lock.lock(); defer { lock.unlock() }; changes.removeValue(forKey: key); newKeys.remove(key); deletedKeys.remove(key)
  }

  public func setOriginalVersion(_ key: EntityKey, version: Int64) {
    lock.lock(); defer { lock.unlock() }; originalVersions[key] = version
  }

  public func originalVersion(_ key: EntityKey) -> Int64? {
    lock.lock(); defer { lock.unlock() }; return originalVersions[key]
  }

  public func markAsNew(_ key: EntityKey) { lock.lock(); defer { lock.unlock() }; newKeys.insert(key) }
  public func markAsPersisted(_ key: EntityKey) { lock.lock(); defer { lock.unlock() }; newKeys.remove(key); deletedKeys.remove(key) }
  public func isNew(_ key: EntityKey) -> Bool { lock.lock(); defer { lock.unlock() }; return newKeys.contains(key) }
  public func markAsDeleted(_ key: EntityKey) {
    lock.lock(); defer { lock.unlock() }; changes.removeValue(forKey: key); deletedKeys.insert(key)
  }
  public func isDeleted(_ key: EntityKey) -> Bool { lock.lock(); defer { lock.unlock() }; return deletedKeys.contains(key) }

  public func clearCommitted() {
    lock.lock(); defer { lock.unlock() }
    changes.removeAll(); newKeys.removeAll(); deletedKeys.removeAll()
  }
}
