import Crypto
import Foundation
import TeaQLCore

public struct DocumentEntitySnapshot: Sendable, Equatable {
  public let rowKey: String
  public let identity: ReferenceIdentity
  public let loadedFields: [String]
  public let writableFields: [String]
  public let allowedMutations: [String]
  public init(rowKey: String, identity: ReferenceIdentity, loadedFields: [String],
              writableFields: [String], allowedMutations: [String]) {
    self.rowKey = rowKey; self.identity = identity; self.loadedFields = loadedFields
    self.writableFields = writableFields; self.allowedMutations = allowedMutations
  }
}
public struct DocumentRelationSnapshot: Sendable, Equatable {
  public let name: String
  public let rowKeys: [String]
  public let completeness: String
  public let writable: Bool
  public let allowedMutations: [String]
  public init(name: String, rowKeys: [String], completeness: String, writable: Bool,
              allowedMutations: [String]) {
    self.name = name; self.rowKeys = rowKeys; self.completeness = completeness
    self.writable = writable; self.allowedMutations = allowedMutations
  }
}
public struct DocumentSnapshot: Sendable, Equatable {
  public let modelFingerprint: String
  public let businessID: String
  public let scope: ReferenceDocumentScope
  public let aggregate: ReferenceIdentity
  public let entities: [DocumentEntitySnapshot]
  public let relations: [DocumentRelationSnapshot]
  public init(modelFingerprint: String, businessID: String, scope: ReferenceDocumentScope,
              aggregate: ReferenceIdentity, entities: [DocumentEntitySnapshot],
              relations: [DocumentRelationSnapshot]) {
    self.modelFingerprint = modelFingerprint; self.businessID = businessID
    self.scope = scope; self.aggregate = aggregate; self.entities = entities; self.relations = relations
  }
}
public struct DocumentBlobBindingSnapshot: Sendable, Equatable {
  public let rowKey: String
  public let canonicalField: String
  public let entityType: String
  public let reference: BlobRef?
  public let bindingVersion: UInt64
  public let nullable: Bool
  public let writable: Bool
  public init(rowKey: String, canonicalField: String, entityType: String, reference: BlobRef?,
              bindingVersion: UInt64, nullable: Bool, writable: Bool) {
    self.rowKey = rowKey; self.canonicalField = canonicalField; self.entityType = entityType
    self.reference = reference; self.bindingVersion = bindingVersion
    self.nullable = nullable; self.writable = writable
  }
}
public struct BoundDocumentSnapshot: Sendable, Equatable {
  public let snapshot: DocumentSnapshot
  public let bindings: [DocumentBlobBindingSnapshot]
  public init(snapshot: DocumentSnapshot, bindings: [DocumentBlobBindingSnapshot]) {
    self.snapshot = snapshot; self.bindings = bindings
  }
}
public struct BlobSelectionTarget: Sendable, Equatable {
  public let scope: ReferenceDocumentScope
  public let targetEntity: String
  public let canonicalField: String
  public let kind: String
  public let targetKey: String
  public let commandID: String
  public init(scope: ReferenceDocumentScope, targetEntity: String, canonicalField: String,
              kind: String, targetKey: String, commandID: String) {
    self.scope = scope; self.targetEntity = targetEntity; self.canonicalField = canonicalField
    self.kind = kind; self.targetKey = targetKey; self.commandID = commandID
  }
}
public struct BlobSelectionClaim: Sendable, Equatable {
  public let target: BlobSelectionTarget
  public let reference: BlobRef
  public init(target: BlobSelectionTarget, reference: BlobRef) {
    self.target = target; self.reference = reference
  }
}
public struct VerifiedDocument<T: Sendable>: Sendable {
  public let document: T
  public let keyID: String
  public let issuedAt: Date
  public let expiresAt: Date
}

enum DocumentWire {
  static func projection() -> ReferenceError { ReferenceError("DOCUMENT_PROJECTION_VIOLATION") }
  static func text(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= 16_384 else { throw ReferenceWire.invalid() }
  }
  static func count(_ value: Int, maximum: Int, into output: inout [UInt8]) throws {
    guard value >= 0, value <= maximum else { throw projection() }
    let number = UInt32(value)
    for shift in stride(from: 24, through: 0, by: -8) {
      output.append(UInt8(truncatingIfNeeded: number >> shift))
    }
  }
  static func putText(_ value: String, into output: inout [UInt8]) throws {
    try text(value); let bytes = Array(value.utf8)
    try count(bytes.count, maximum: 16_384, into: &output); output += bytes
  }
  static func putScope(_ value: ReferenceDocumentScope, into output: inout [UInt8]) throws {
    try ReferenceWire.scope(value)
    for text in [value.documentID, value.purpose, value.aggregateType] { try putText(text, into: &output) }
    ReferenceWire.putU64(value.aggregateID, into: &output)
    ReferenceWire.putI64(value.aggregateRevision, into: &output)
  }
  static func putIdentity(_ value: ReferenceIdentity, into output: inout [UInt8]) throws {
    try ReferenceWire.identity(value); try putText(value.entityType, into: &output)
    ReferenceWire.putU64(value.id, into: &output); ReferenceWire.putI64(value.version, into: &output)
  }
  static func byteLess(_ left: String, _ right: String) -> Bool {
    left.utf8.lexicographicallyPrecedes(right.utf8)
  }
  static func putSet(_ values: [String], maximum: Int, into output: inout [UInt8]) throws {
    guard values.count <= maximum, Set(values).count == values.count else { throw projection() }
    try count(values.count, maximum: maximum, into: &output)
    for value in values.sorted(by: byteLess) { try putText(value, into: &output) }
  }
  static let mutationCodes: [String: UInt8] = ["UPDATE": 1, "CREATE_CHILD": 2, "REMOVE_CHILD": 3]
  static let mutationNames: [UInt8: String] = [1: "UPDATE", 2: "CREATE_CHILD", 3: "REMOVE_CHILD"]
  static func putMutations(_ values: [String], into output: inout [UInt8]) throws {
    guard values.count <= 3, Set(values).count == values.count,
      values.allSatisfy({ mutationCodes[$0] != nil }) else { throw projection() }
    try count(values.count, maximum: 3, into: &output)
    output += values.compactMap { mutationCodes[$0] }.sorted()
  }
  static func encodeSnapshot(_ snapshot: DocumentSnapshot, version: UInt8, actor: [UInt8],
                             issued: Int64, expires: Int64) throws -> [UInt8] {
    try ReferenceWire.scope(snapshot.scope); try ReferenceWire.identity(snapshot.aggregate)
    guard snapshot.aggregate.entityType == snapshot.scope.aggregateType,
      snapshot.aggregate.id == snapshot.scope.aggregateID,
      snapshot.aggregate.version == snapshot.scope.aggregateRevision,
      snapshot.entities.count <= 10_000, snapshot.relations.count <= 1024 else { throw projection() }
    var output = [version] + actor
    ReferenceWire.putI64(issued, into: &output); ReferenceWire.putI64(expires, into: &output)
    try putText(snapshot.modelFingerprint, into: &output); try putText(snapshot.businessID, into: &output)
    try putScope(snapshot.scope, into: &output); try putIdentity(snapshot.aggregate, into: &output)
    try count(snapshot.entities.count, maximum: 10_000, into: &output)
    var rowKeys = Set<String>()
    for entity in snapshot.entities {
      guard rowKeys.insert(entity.rowKey).inserted, !entity.allowedMutations.isEmpty,
        Set(entity.writableFields).isSubset(of: Set(entity.loadedFields)) else { throw projection() }
      try putText(entity.rowKey, into: &output); try putIdentity(entity.identity, into: &output)
      try putSet(entity.loadedFields, maximum: 1024, into: &output)
      try putSet(entity.writableFields, maximum: 1024, into: &output)
      try putMutations(entity.allowedMutations, into: &output)
    }
    try count(snapshot.relations.count, maximum: 1024, into: &output)
    for relation in snapshot.relations {
      guard relation.rowKeys.count <= 10_000, Set(relation.rowKeys).count == relation.rowKeys.count,
        Set(relation.rowKeys).isSubset(of: rowKeys), relation.writable || relation.allowedMutations.isEmpty
      else { throw projection() }
      try putText(relation.name, into: &output)
      switch relation.completeness {
      case "COMPLETE": output.append(1)
      case "PARTIAL": output.append(2)
      default: throw projection()
      }
      output.append(relation.writable ? 1 : 0)
      try putMutations(relation.allowedMutations, into: &output)
      try count(relation.rowKeys.count, maximum: 10_000, into: &output)
      for rowKey in relation.rowKeys { try putText(rowKey, into: &output) }
    }
    return output
  }
  static func decodeSnapshot(_ reader: inout ReferenceReader, version: UInt8) throws ->
    (DocumentSnapshot, [UInt8], Int64, Int64) {
    guard try reader.byte() == version else { throw ReferenceWire.invalid() }
    let actor = try reader.take(32)
    let issued = try reader.i64(); let expires = try reader.i64()
    let fingerprint = try reader.text32(); let businessID = try reader.text32()
    let scope = try reader.scope(); let aggregate = try reader.identity()
    var entities: [DocumentEntitySnapshot] = []
    for _ in 0..<(try reader.count(10_000)) {
      entities.append(try DocumentEntitySnapshot(rowKey: reader.text32(), identity: reader.identity(),
        loadedFields: reader.set(1024), writableFields: reader.set(1024),
        allowedMutations: reader.mutations()))
    }
    var relations: [DocumentRelationSnapshot] = []
    for _ in 0..<(try reader.count(1024)) {
      let name = try reader.text32(); let code = try reader.byte()
      let completeness: String
      switch code { case 1: completeness = "COMPLETE"; case 2: completeness = "PARTIAL"
      default: throw ReferenceWire.invalid() }
      let writable = try reader.flag(); let mutations = try reader.mutations()
      var rows: [String] = []
      for _ in 0..<(try reader.count(10_000)) { rows.append(try reader.text32()) }
      relations.append(DocumentRelationSnapshot(name: name, rowKeys: rows, completeness: completeness,
        writable: writable, allowedMutations: mutations))
    }
    let snapshot = DocumentSnapshot(modelFingerprint: fingerprint, businessID: businessID,
      scope: scope, aggregate: aggregate, entities: entities, relations: relations)
    do { _ = try encodeSnapshot(snapshot, version: version, actor: actor, issued: issued, expires: expires) }
    catch { throw ReferenceWire.invalid() }
    return (snapshot, actor, issued, expires)
  }
  static func validateBindings(_ document: BoundDocumentSnapshot) throws {
    guard document.bindings.count <= 10_000 else { throw projection() }
    var previous: (String, String)?
    for binding in document.bindings {
      for value in [binding.rowKey, binding.canonicalField, binding.entityType] {
        try text(value)
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw projection() }
      }
      if let previous {
        guard byteLess(previous.0, binding.rowKey) ||
          (previous.0 == binding.rowKey && byteLess(previous.1, binding.canonicalField)) else { throw projection() }
      }
      previous = (binding.rowKey, binding.canonicalField)
      guard let entity = document.snapshot.entities.first(where: { $0.rowKey == binding.rowKey }),
        entity.identity.entityType == binding.entityType,
        entity.loadedFields.contains(binding.canonicalField),
        !binding.writable || entity.writableFields.contains(binding.canonicalField) else { throw projection() }
    }
  }
  static func encodeBound(_ document: BoundDocumentSnapshot, actor: [UInt8],
                          issued: Int64, expires: Int64) throws -> [UInt8] {
    try validateBindings(document)
    var output = try encodeSnapshot(document.snapshot, version: 2, actor: actor, issued: issued, expires: expires)
    try count(document.bindings.count, maximum: 10_000, into: &output)
    for binding in document.bindings {
      try putText(binding.rowKey, into: &output); try putText(binding.canonicalField, into: &output)
      try putText(binding.entityType, into: &output)
      output.append(binding.reference == nil ? 0 : 1)
      if let reference = binding.reference { try putText(reference.key, into: &output) }
      ReferenceWire.putU64(binding.bindingVersion, into: &output)
      output.append(binding.nullable ? 1 : 0); output.append(binding.writable ? 1 : 0)
    }
    return output
  }
  static func decodeBound(_ payload: [UInt8]) throws -> (BoundDocumentSnapshot, [UInt8], Int64, Int64) {
    var reader = ReferenceReader(data: payload)
    let (snapshot, actor, issued, expires) = try decodeSnapshot(&reader, version: 2)
    var bindings: [DocumentBlobBindingSnapshot] = []
    for _ in 0..<(try reader.count(10_000)) {
      let row = try reader.text32(); let field = try reader.text32(); let entity = try reader.text32()
      let reference: BlobRef?
      if try reader.flag() {
        do { reference = try BlobRef(reader.text32()) }
        catch { throw ReferenceWire.invalid() }
      } else { reference = nil }
      bindings.append(DocumentBlobBindingSnapshot(rowKey: row, canonicalField: field, entityType: entity,
        reference: reference, bindingVersion: try reader.u64(), nullable: try reader.flag(),
        writable: try reader.flag()))
    }
    try reader.end()
    let document = BoundDocumentSnapshot(snapshot: snapshot, bindings: bindings)
    do { try validateBindings(document) } catch { throw ReferenceWire.invalid() }
    return (document, actor, issued, expires)
  }
  static func validateTarget(_ target: BlobSelectionTarget) throws {
    try ReferenceWire.scope(target.scope)
    for value in [target.targetEntity, target.canonicalField, target.targetKey, target.commandID] {
      try text(value)
      guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw ReferenceWire.invalid() }
    }
    guard target.kind == "EXISTING_ROW" || target.kind == "NEW_CLIENT_KEY" else { throw ReferenceWire.invalid() }
  }
  static func requireTarget(_ document: BoundDocumentSnapshot, _ target: BlobSelectionTarget) throws {
    try validateTarget(target)
    guard document.snapshot.scope == target.scope else { throw ReferenceWire.mismatch() }
    let allowed: Bool
    if target.kind == "EXISTING_ROW" {
      allowed = document.snapshot.entities.contains { row in
        row.rowKey == target.targetKey && row.identity.entityType == target.targetEntity &&
          row.writableFields.contains(target.canonicalField)
      } && document.bindings.contains { binding in
        binding.rowKey == target.targetKey && binding.canonicalField == target.canonicalField && binding.writable
      }
    } else {
      allowed = document.snapshot.relations.contains { relation in
        relation.completeness == "COMPLETE" && relation.writable && relation.allowedMutations.contains("CREATE_CHILD")
      }
    }
    guard allowed else { throw projection() }
  }
  static func encodeSelection(_ claim: BlobSelectionClaim, actor: [UInt8],
                              issued: Int64, expires: Int64) throws -> [UInt8] {
    try validateTarget(claim.target)
    var output = [UInt8(1)] + actor
    ReferenceWire.putI64(issued, into: &output); ReferenceWire.putI64(expires, into: &output)
    try putScope(claim.target.scope, into: &output)
    try putText(claim.target.targetEntity, into: &output)
    try putText(claim.target.canonicalField, into: &output)
    output.append(claim.target.kind == "EXISTING_ROW" ? 1 : 2)
    try putText(claim.target.targetKey, into: &output)
    try putText(claim.reference.key, into: &output)
    try putText(claim.target.commandID, into: &output)
    return output
  }
  static func decodeSelection(_ payload: [UInt8]) throws -> (BlobSelectionClaim, [UInt8], Int64, Int64) {
    var reader = ReferenceReader(data: payload)
    guard try reader.byte() == 1 else { throw ReferenceWire.invalid() }
    let actor = try reader.take(32)
    let issued = try reader.i64(); let expires = try reader.i64()
    let scope = try reader.scope(); let entity = try reader.text32(); let field = try reader.text32()
    let code = try reader.byte(); let kind: String
    switch code { case 1: kind = "EXISTING_ROW"; case 2: kind = "NEW_CLIENT_KEY"
    default: throw ReferenceWire.invalid() }
    let row = try reader.text32()
    let reference: BlobRef
    do { reference = try BlobRef(reader.text32()) }
    catch { throw ReferenceWire.invalid() }
    let command = try reader.text32(); try reader.end()
    let target = BlobSelectionTarget(scope: scope, targetEntity: entity, canonicalField: field,
      kind: kind, targetKey: row, commandID: command)
    try validateTarget(target)
    return (BlobSelectionClaim(target: target, reference: reference), actor, issued, expires)
  }
}

extension ReferenceReader {
  mutating func byte() throws -> UInt8 { try take(1)[0] }
  mutating func count(_ maximum: Int) throws -> Int {
    let bytes = try take(4)
    let number = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard number <= maximum else { throw ReferenceWire.invalid() }
    return Int(number)
  }
  mutating func text32() throws -> String {
    let bytes = try take(count(16_384))
    guard let value = String(bytes: bytes, encoding: .utf8) else { throw ReferenceWire.invalid() }
    try DocumentWire.text(value); return value
  }
  mutating func flag() throws -> Bool {
    let value = try byte(); guard value <= 1 else { throw ReferenceWire.invalid() }
    return value == 1
  }
  mutating func scope() throws -> ReferenceDocumentScope {
    let value = try ReferenceDocumentScope(documentID: text32(), purpose: text32(),
      aggregateType: text32(), aggregateID: u64(), aggregateRevision: i64())
    try ReferenceWire.scope(value); return value
  }
  mutating func identity() throws -> ReferenceIdentity {
    let value = try ReferenceIdentity(entityType: text32(), id: u64(), version: i64())
    try ReferenceWire.identity(value); return value
  }
  mutating func set(_ maximum: Int) throws -> [String] {
    let total = try count(maximum); var values: [String] = []
    for _ in 0..<total { values.append(try text32()) }
    guard Set(values).count == total else { throw ReferenceWire.invalid() }
    return values
  }
  mutating func mutations() throws -> [String] {
    let total = try count(3); var values: [String] = []
    for _ in 0..<total {
      guard let value = DocumentWire.mutationNames[try byte()] else { throw ReferenceWire.invalid() }
      values.append(value)
    }
    guard Set(values).count == total else { throw ReferenceWire.invalid() }
    return values
  }
}

public extension ContextBoundReferenceRuntime {
  func issueDocumentSnapshot(_ actor: TrustedReferencePrincipal, snapshot: DocumentSnapshot,
                             lifetimeSeconds: Int64) throws -> String {
    try ReferenceWire.principal(actor)
    let (issued, expires) = try times(lifetimeSeconds: lifetimeSeconds)
    let key = try currentKey()
    let plain = try DocumentWire.encodeSnapshot(snapshot, version: 1,
      actor: actorFingerprint(key, actor), issued: issued, expires: expires)
    try authorizeDocument(actor, snapshot)
    return try seal(prefix: "tqd1", label: "document-snapshot-encryption", key: key,
      purpose: snapshot.scope.purpose, plain: plain, maximum: 256_000)
  }
  func consumeDocumentSnapshot(_ actor: TrustedReferencePrincipal, token: String,
                               aggregateType: String, purpose: String) throws -> VerifiedDocument<DocumentSnapshot> {
    try ReferenceWire.principal(actor); try DocumentWire.text(aggregateType); try DocumentWire.text(purpose)
    let (key, plain) = try open(prefix: "tqd1", label: "document-snapshot-encryption",
      purpose: purpose, token: token, maximum: 256_000)
    var reader = ReferenceReader(data: plain)
    let (snapshot, fingerprint, issued, expires) = try DocumentWire.decodeSnapshot(&reader, version: 1)
    try reader.end()
    let result = try verify(actor: actor, key: key, fingerprint: fingerprint, issued: issued,
      expires: expires, scope: snapshot.scope, aggregateType: aggregateType, purpose: purpose)
    try authorizeDocument(actor, snapshot)
    return VerifiedDocument(document: snapshot, keyID: key.keyID,
      issuedAt: result.0, expiresAt: result.1)
  }
  func issueBoundDocumentSnapshot(_ actor: TrustedReferencePrincipal, document: BoundDocumentSnapshot,
                                  lifetimeSeconds: Int64) throws -> String {
    try ReferenceWire.principal(actor)
    let (issued, expires) = try times(lifetimeSeconds: lifetimeSeconds)
    let key = try currentKey()
    let plain = try DocumentWire.encodeBound(document, actor: actorFingerprint(key, actor),
      issued: issued, expires: expires)
    try authorizeDocument(actor, document.snapshot)
    return try seal(prefix: "tqd2", label: "document-snapshot-v2-encryption", key: key,
      purpose: document.snapshot.scope.purpose, plain: plain, maximum: 256_000)
  }
  func consumeBoundDocumentSnapshot(_ actor: TrustedReferencePrincipal, token: String,
                                    aggregateType: String, purpose: String) throws -> VerifiedDocument<BoundDocumentSnapshot> {
    try ReferenceWire.principal(actor); try DocumentWire.text(aggregateType); try DocumentWire.text(purpose)
    let (key, plain) = try open(prefix: "tqd2", label: "document-snapshot-v2-encryption",
      purpose: purpose, token: token, maximum: 256_000)
    let (document, fingerprint, issued, expires) = try DocumentWire.decodeBound(plain)
    let result = try verify(actor: actor, key: key, fingerprint: fingerprint, issued: issued,
      expires: expires, scope: document.snapshot.scope, aggregateType: aggregateType, purpose: purpose)
    try authorizeDocument(actor, document.snapshot)
    return VerifiedDocument(document: document, keyID: key.keyID,
      issuedAt: result.0, expiresAt: result.1)
  }
  func issueBlobSelection(_ actor: TrustedReferencePrincipal, documentToken: String,
                          claim: BlobSelectionClaim, lifetimeSeconds: Int64) throws -> String {
    try DocumentWire.validateTarget(claim.target)
    let document = try consumeBoundDocumentSnapshot(actor, token: documentToken,
      aggregateType: claim.target.scope.aggregateType, purpose: claim.target.scope.purpose)
    try DocumentWire.requireTarget(document.document, claim.target)
    let (issued, expires) = try times(lifetimeSeconds: lifetimeSeconds)
    guard expires <= Int64(document.expiresAt.timeIntervalSince1970) else { throw ReferenceWire.invalid() }
    let key = try currentKey()
    let plain = try DocumentWire.encodeSelection(claim, actor: actorFingerprint(key, actor),
      issued: issued, expires: expires)
    return try seal(prefix: "tqs1", label: "blob-selection-v1-encryption", key: key,
      purpose: claim.target.scope.purpose, plain: plain, maximum: 256_000)
  }
  func consumeBlobSelection(_ actor: TrustedReferencePrincipal, documentToken: String,
                            token: String, expectedTarget: BlobSelectionTarget) throws -> VerifiedDocument<BlobSelectionClaim> {
    try DocumentWire.validateTarget(expectedTarget)
    let document = try consumeBoundDocumentSnapshot(actor, token: documentToken,
      aggregateType: expectedTarget.scope.aggregateType, purpose: expectedTarget.scope.purpose)
    try DocumentWire.requireTarget(document.document, expectedTarget)
    let (key, plain) = try open(prefix: "tqs1", label: "blob-selection-v1-encryption",
      purpose: expectedTarget.scope.purpose, token: token, maximum: 256_000)
    let (claim, fingerprint, issued, expires) = try DocumentWire.decodeSelection(plain)
    guard expires <= Int64(document.expiresAt.timeIntervalSince1970) else { throw ReferenceWire.invalid() }
    guard claim.target == expectedTarget else { throw ReferenceWire.mismatch() }
    let result = try verify(actor: actor, key: key, fingerprint: fingerprint, issued: issued,
      expires: expires, scope: claim.target.scope, aggregateType: expectedTarget.scope.aggregateType,
      purpose: expectedTarget.scope.purpose)
    return VerifiedDocument(document: claim, keyID: key.keyID,
      issuedAt: result.0, expiresAt: result.1)
  }
  private func authorizeDocument(_ actor: TrustedReferencePrincipal, _ snapshot: DocumentSnapshot) throws {
    try authorizeIdentity(actor, snapshot.scope, snapshot.aggregate)
    for entity in snapshot.entities { try authorizeIdentity(actor, snapshot.scope, entity.identity) }
  }
}
