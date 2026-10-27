import Foundation

/// Generator-only, pure reconstruction of the view returned by one graph save.
/// It has no Context, clock, provider or mutable caller-ledger dependency.
@_spi(Generated) public final class GraphReadback: Sendable {
  public let root = EntityRoot()
  public let snapshots = LoadedEntitySnapshots()
  private let records: [EntityKey: TeaQLRecord]

  package init(records: [EntityKey: TeaQLRecord]) { self.records = records }

  public func contains<Entity: TeaQLEntity>(_ entity: Entity) -> Bool {
    records[key(entity)] != nil
  }

  /// A loaded detail is reusable only if it still describes this exact FK.
  /// Missing details for a non-null FK stay NotLoaded, never loaded-null.
  public func forwardMatches<Entity: TeaQLEntity>(_ foreignKey: TeaQLValue?, related: SmartList<Entity>) -> Bool {
    guard related.isLoaded, let foreignKey else { return false }
    switch foreignKey {
    case .null: return related.isEmpty
    case .int(let id): return related.count == 1 && related.first?.id == id
    default: return false
    }
  }

  /// Overlay only originally selected scalars. Unchanged partial views must not
  /// become fully loaded just because another alias was written in this save.
  public func scalarRecord<Entity: TeaQLEntity>(for entity: Entity) throws -> TeaQLRecord {
    let identity = key(entity), submitted = entity.toMutationRecord()
    let snapshot = (entity as? any TeaQLMutationRootedEntity)?.teaqlLoadedSnapshot
    if let snapshot, snapshot.key != identity || snapshot.version != entity.version {
      throw TeaQLError.execution("ENTITY_VERSION_CONFLICT: returned graph must retain its loaded identity and version")
    }
    let persisted = records[identity]
    let original = snapshot?.record ?? submitted
    var result: TeaQLRecord = [:]
    for property in Entity.descriptor.properties {
      let aliases = [property.name, property.modelName ?? property.name, property.column]
      guard aliases.contains(where: { submitted[$0] != nil }) else { continue }
      let value = aliases.lazy.compactMap { (persisted ?? original)[$0] }.first
      if let value { result[property.name] = value }
      else if persisted != nil {
        throw TeaQLError.execution("PERSISTED_FIELD_MISSING: \(Entity.descriptor.name).\(property.modelName ?? property.name)")
      }
    }
    return result
  }

  private func key<Entity: TeaQLEntity>(_ entity: Entity) -> EntityKey {
    (entity as? any TeaQLMutationRootedEntity)?.teaqlEntityKey
      ?? EntityKey(entity: Entity.descriptor.name, id: .int(entity.id))
  }
}
