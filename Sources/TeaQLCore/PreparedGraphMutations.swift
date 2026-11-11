import Foundation

/// Values reviewed by policy belong to this invocation, not to UserContext or
/// a mutable entity. Execution consumes a frozen post-Fix value exactly once.
package final class PreparedGraphMutations: @unchecked Sendable {
  private enum Key: Hashable {
    case ledger(ObjectIdentifier?, EntityKey)
    case value(String, EntityDescriptor, TeaQLValue?, Int64?)
  }
  private struct Entry {
    let original: Mutation
    let fixed: Mutation
    let ledger: EntityRoot?
    let ledgerKey: EntityKey?
    var state: EntityRoot.MutationSnapshot?
    let references: [String: Reference]
    let baseline: LoadedEntitySnapshot?
    let restored: TeaQLRecord
    var isNoOp: Bool { baseline != nil && fixed.kind == .update && fixed.values.isEmpty }
  }
  private struct Reference {
    let target: Key
    let entity: EntityDescriptor
    let key: EntityKey
  }
  private struct Queue {
    var entries: [Entry] = []
    var consumed = 0
  }
  private let lock = NSLock()
  private var required = false
  private var sealed = false
  private var fixesPublished = false
  private var queues: [Key: Queue] = [:]
  private var declaredReferences: [Key: [String: Reference]] = [:]
  private var assignedIDs: [Key: TeaQLValue] = [:]

  package func requireSnapshots() { lock.withLock { required = true } }

  package func bind(source: EntityKey, field: String, target: EntityKey,
    targetEntity: EntityDescriptor, ledger: EntityRoot) throws {
    try lock.withLock {
      guard required && !sealed else { throw MutationPolicyError.preflightAfterReview }
      let sourceIdentity = Key.ledger(ObjectIdentifier(ledger), source)
      let targetIdentity = Key.ledger(ObjectIdentifier(ledger), target)
      guard let queue = queues[targetIdentity], queue.entries.count == 1,
        queue.entries[0].original.kind == .create,
        queue.entries[0].original.entity == targetEntity,
        target.entity == targetEntity.name, case .int(let id) = target.id, id < 0,
        ledger.isNew(target) else { throw MutationPolicyError.operationOutsideReviewedPlan }
      if let old = declaredReferences[sourceIdentity]?[field] {
        guard old.target == targetIdentity && old.entity == targetEntity else {
          throw MutationPolicyError.operationOutsideReviewedPlan
        }
        return
      }
      guard queues[sourceIdentity] == nil else { throw MutationPolicyError.preflightAfterReview }
      declaredReferences[sourceIdentity, default: [:]][field] = Reference(
        target: targetIdentity, entity: targetEntity, key: target)
    }
  }

  package func policyReferences(ledger: EntityRoot?, key: EntityKey?) -> [String: MutationPolicyReference]? {
    lock.withLock {
      guard let ledger, let key,
        let references = declaredReferences[.ledger(ObjectIdentifier(ledger), key)], !references.isEmpty else { return nil }
      return references.mapValues { MutationPolicyReference(entity: $0.key.entity, id: $0.key.id) }
    }
  }

  package func record(original: Mutation, fixed: Mutation, ledger: EntityRoot?,
    ledgerKey: EntityKey?, state: EntityRoot.MutationSnapshot?,
    baseline: LoadedEntitySnapshot? = nil, restored: TeaQLRecord = [:]) throws {
    try lock.withLock {
      guard !sealed else { throw MutationPolicyError.preflightAfterReview }
      if let ledger, let ledgerKey, let state,
        !state.matches(ledger.mutationSnapshot(ledgerKey)) {
        throw MutationPolicyError.operationOutsideReviewedPlan
      }
      let identity = key(original, ledger: ledger, ledgerKey: ledgerKey)
      let references = declaredReferences[identity] ?? [:]
      for (field, reference) in references {
        guard let property = original.entity.property(named: field), property.isRelation,
          property.referencedEntity == reference.entity.name,
          original.values[field] == reference.key.id, fixed.values[field] == reference.key.id else {
          throw MutationPolicyError.operationOutsideReviewedPlan
        }
      }
      queues[identity, default: Queue()].entries.append(
        Entry(original: original, fixed: fixed, ledger: ledger, ledgerKey: ledgerKey, state: state,
          references: references, baseline: baseline, restored: restored))
    }
  }

  package func sealAndValidate() throws {
    try lock.withLock { sealed = true; try validateLedgersLocked() }
  }

  package func validateLedgers() throws { try lock.withLock { try validateLedgersLocked() } }

  package var isEmptyPlan: Bool { lock.withLock {
    required && sealed && queues.values.allSatisfy { $0.entries.allSatisfy(\.isNoOp) }
  } }
  package func wasNormalized(ledger: EntityRoot, key: EntityKey) -> Bool { lock.withLock {
    queues[.ledger(ObjectIdentifier(ledger), key)]?.entries.contains { !$0.restored.isEmpty } ?? false
  } }

  /// Policy first sees the immutable post-Fix plan while the caller's ledger
  /// still contains its original intent. Only an approved plan may publish
  /// successful Fix values, before provider access. Advance the guarded
  /// snapshot at the same boundary so these runtime-owned changes do not
  /// weaken detection of customer edits during review or execution.
  package func publishFixesAfterReview() throws {
    try lock.withLock {
      guard !fixesPublished else { return }
      try validateLedgersLocked()
      for identity in Array(queues.keys) {
        guard var queue = queues[identity], let first = queue.entries.first,
          let ledger = first.ledger, let key = first.ledgerKey, let state = first.state else { continue }
        var differences: TeaQLRecord = [:]
        for entry in queue.entries {
          guard key.entity == entry.original.entity.name,
            entry.original.kind == .create || entry.original.id == key.id else { continue }
          for (field, value) in entry.fixed.values {
            guard let property = entry.original.entity.property(named: field),
              field == (property.modelName ?? property.name), !property.isID, !property.isVersion,
              !sameMutationRecord([field: value], entry.original.values[field].map { [field: $0] } ?? [:]) else { continue }
            differences[field] = value
          }
          for (field, value) in entry.restored { differences[field] = value }
        }
        let published = try ledger.publishValidatedFix(differences, key: key, expected: state,
          restoring: first.baseline, descriptor: first.original.entity)
        for i in queue.entries.indices { queue.entries[i].state = published }
        queues[identity] = queue
      }
      fixesPublished = true
    }
  }

  package func consume(_ proposed: Mutation, ledger: EntityRoot?, ledgerKey: EntityKey?,
    rootComment: String) throws -> Mutation? {
    try lock.withLock {
      // Explicit low-level graphs without a preparation callback retain their
      // ordinary single-execution Checker path. A prepared graph cannot use it.
      if !required && queues.isEmpty { sealed = true; return nil }
      sealed = true
      let identity = key(proposed, ledger: ledger, ledgerKey: ledgerKey)
      guard var queue = queues[identity], queue.consumed < queue.entries.count else {
        throw MutationPolicyError.operationOutsideReviewedPlan
      }
      let entry = queue.entries[queue.consumed]
      guard !entry.isNoOp else { throw MutationPolicyError.operationOutsideReviewedPlan }
      guard proposed.kind == entry.original.kind, proposed.entity == entry.original.entity,
        proposed.id == entry.original.id, proposed.expectedVersion == entry.original.expectedVersion,
        (sameMutationRecord(proposed.values, entry.original.values)
          || sameMutationRecord(proposed.values, entry.fixed.values)),
        sameMutationRecord(proposed.loadedValues, entry.original.loadedValues),
        proposed.auditReason == entry.original.auditReason || proposed.auditReason == rootComment else {
        throw MutationPolicyError.operationOutsideReviewedPlan
      }
      try validateLedgersLocked()
      queue.consumed += 1; queues[identity] = queue
      var mutation = entry.fixed
      // Resolve only the declared, reviewed relationship. The caller's values
      // and ledger remain untouched, and arbitrary execution-time FKs still fail.
      for (field, reference) in entry.references {
        guard let assigned = assignedIDs[reference.target], mutation.values[field] == reference.key.id else {
          throw MutationPolicyError.operationOutsideReviewedPlan
        }
        mutation.values[field] = assigned
      }
      // The generated traversal supplies the actual session-owned ancestry;
      // only responsibility metadata changes, never reviewed business values.
      mutation.auditReason = proposed.auditReason
      mutation.mutationLineage = proposed.mutationLineage
      return mutation
    }
  }

  package func recordAssignedID(_ mutation: Mutation, result: MutationResult,
    ledger: EntityRoot?, source: EntityKey?) throws {
    try lock.withLock {
      guard mutation.kind == .create, result.affectedRows > 0, let ledger, let source,
        case .int(let temporary) = source.id, temporary < 0 else { return }
      let identity = Key.ledger(ObjectIdentifier(ledger), source)
      guard let queue = queues[identity], queue.consumed == 1, queue.entries.count == 1,
        queue.entries[0].original.entity == mutation.entity else { return }
      let property = mutation.entity.idProperty
      let aliases = property.map { [$0.name, $0.modelName ?? $0.name, $0.column] } ?? ["id"]
      guard let record = result.persistedRecord,
        let value = aliases.lazy.compactMap({ record[$0] }).first,
        case .int(let id) = value, id > 0,
        result.generatedValues["id"].map({ $0 == value }) ?? true else {
        throw MutationPolicyError.operationOutsideReviewedPlan
      }
      guard assignedIDs[identity] == nil else { throw MutationPolicyError.operationOutsideReviewedPlan }
      assignedIDs[identity] = value
    }
  }

  package func clear() { lock.withLock { queues = [:]; declaredReferences = [:]; assignedIDs = [:]; fixesPublished = false } }

  private func key(_ mutation: Mutation, ledger: EntityRoot?, ledgerKey: EntityKey?) -> Key {
    if let ledgerKey { return .ledger(ledger.map(ObjectIdentifier.init), ledgerKey) }
    return .value(mutation.kind.rawValue, mutation.entity, mutation.id, mutation.expectedVersion)
  }

  private func validateLedgersLocked() throws {
    for queue in queues.values {
      for entry in queue.entries {
        if let ledger = entry.ledger, let key = entry.ledgerKey, let state = entry.state,
          !state.matches(ledger.mutationSnapshot(key)) {
          throw MutationPolicyError.operationOutsideReviewedPlan
        }
      }
    }
  }
}

// A Fix may repair NaN. Equality of a submitted snapshot must remain reflexive
// even for such rejected/repaired inputs; normal Double.nan == .nan is false.
package func sameMutationRecord(_ left: TeaQLRecord, _ right: TeaQLRecord) -> Bool {
  left.count == right.count && left.allSatisfy { field, value in
    right[field].map { sameMutationValue(value, $0) } == true
  }
}
private func sameMutationValue(_ left: TeaQLValue, _ right: TeaQLValue) -> Bool {
  switch (left, right) {
  case (.double(let a), .double(let b)): return a.bitPattern == b.bitPattern
  case (.date(let a), .date(let b)): return a.timeIntervalSinceReferenceDate.bitPattern == b.timeIntervalSinceReferenceDate.bitPattern
  case (.decimal(let a), .decimal(let b)):
    return a.isNaN && b.isNaN || a == b && a.exponent == b.exponent && a.sign == b.sign
  case (.array(let a), .array(let b)): return a.count == b.count && zip(a, b).allSatisfy { sameMutationValue($0, $1) }
  case (.object(let a), .object(let b)): return sameMutationRecord(a, b)
  default: return left == right
  }
}
