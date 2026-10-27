import Crypto
import Foundation

public struct ReferenceError: Error, Sendable, Equatable, CustomStringConvertible {
  public let code: String
  public var description: String { code }
  public init(_ code: String) { self.code = code }
}

public struct TrustedReferencePrincipal: Sendable, Equatable {
  public let authenticationRealm: String
  public let subject: String
  public let domainRootType: String
  public let domainRootID: UInt64
  public init(authenticationRealm: String, subject: String, domainRootType: String, domainRootID: UInt64) {
    self.authenticationRealm = authenticationRealm; self.subject = subject
    self.domainRootType = domainRootType; self.domainRootID = domainRootID
  }
}
public struct ReferenceDocumentScope: Sendable, Equatable {
  public let documentID: String
  public let purpose: String
  public let aggregateType: String
  public let aggregateID: UInt64
  public let aggregateRevision: Int64
  public init(documentID: String, purpose: String, aggregateType: String,
              aggregateID: UInt64, aggregateRevision: Int64) {
    self.documentID = documentID; self.purpose = purpose; self.aggregateType = aggregateType
    self.aggregateID = aggregateID; self.aggregateRevision = aggregateRevision
  }
}
public struct ReferenceIdentity: Sendable, Equatable {
  public let entityType: String
  public let id: UInt64
  public let version: Int64
  public init(entityType: String, id: UInt64, version: Int64) {
    self.entityType = entityType; self.id = id; self.version = version
  }
}
public struct VerifiedEntityReference: Sendable {
  public let identity: ReferenceIdentity
  public let keyID: String
  public let issuedAt: Date
  public let expiresAt: Date
}

public struct ReferenceKey: Sendable, CustomStringConvertible {
  public let keyID: String
  private let secret: [UInt8]
  public var description: String { "ReferenceKey(\(keyID),[REDACTED])" }
  public init(keyID: String, masterKey: [UInt8]) throws {
    guard ReferenceWire.validKeyID(keyID), masterKey.count == 32 else {
      throw ReferenceError("ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID")
    }
    self.keyID = keyID; self.secret = masterKey
  }
  fileprivate var masterKey: [UInt8] { secret }
}
public protocol ReferenceKeyProvider: Sendable {
  func currentKey() throws -> ReferenceKey
  func key(id: String) throws -> ReferenceKey?
}
public struct StaticReferenceKeyProvider: ReferenceKeyProvider {
  private let current: String
  private let keys: [String: ReferenceKey]
  public init(current: String, keys: [ReferenceKey]) throws {
    guard ReferenceWire.validKeyID(current), Set(keys.map(\.keyID)).count == keys.count else {
      throw ReferenceError("ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID")
    }
    let mapping = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
    guard mapping[current] != nil else { throw ReferenceError("ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID") }
    self.current = current; self.keys = mapping
  }
  public func currentKey() throws -> ReferenceKey {
    guard let key = keys[current] else { throw ReferenceError("ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID") }
    return key
  }
  public func key(id: String) throws -> ReferenceKey? { keys[id] }
}

enum ReferenceWire {
  static func invalid() -> ReferenceError { ReferenceError("ROUND_TRIP_REFERENCE_INVALID") }
  static func config() -> ReferenceError { ReferenceError("ROUND_TRIP_REFERENCE_CONFIGURATION_INVALID") }
  static func expired() -> ReferenceError { ReferenceError("ROUND_TRIP_REFERENCE_EXPIRED") }
  static func mismatch() -> ReferenceError { ReferenceError("ROUND_TRIP_REFERENCE_SCOPE_MISMATCH") }
  static func denied() -> ReferenceError { ReferenceError("ROUND_TRIP_REFERENCE_AUTHORIZATION_REQUIRED") }
  static func validKeyID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return (1...64).contains(bytes.count) && bytes.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }
  }
  static func text(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 4096,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { throw invalid() }
  }
  static func principal(_ value: TrustedReferencePrincipal) throws {
    try text(value.authenticationRealm); try text(value.subject); try text(value.domainRootType)
    guard value.domainRootID != 0 else { throw invalid() }
  }
  static func scope(_ value: ReferenceDocumentScope) throws {
    try text(value.documentID); try text(value.purpose); try text(value.aggregateType)
    guard value.aggregateID != 0, value.aggregateRevision >= 0 else { throw invalid() }
  }
  static func identity(_ value: ReferenceIdentity) throws {
    try text(value.entityType)
    guard value.id != 0, value.version >= 0 else { throw invalid() }
  }
  static func putText16(_ value: String, into output: inout [UInt8]) throws {
    try text(value); let bytes = Array(value.utf8)
    guard bytes.count <= UInt16.max else { throw invalid() }
    putU16(UInt16(bytes.count), into: &output); output += bytes
  }
  static func putU16(_ value: UInt16, into output: inout [UInt8]) {
    output.append(UInt8(truncatingIfNeeded: value >> 8)); output.append(UInt8(truncatingIfNeeded: value))
  }
  static func putU64(_ value: UInt64, into output: inout [UInt8]) {
    for shift in stride(from: 56, through: 0, by: -8) {
      output.append(UInt8(truncatingIfNeeded: value >> shift))
    }
  }
  static func putI64(_ value: Int64, into output: inout [UInt8]) { putU64(UInt64(bitPattern: value), into: &output) }
  static func encodeBase64(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  static func decodeBase64(_ value: String) throws -> [UInt8] {
    guard !value.isEmpty, value.utf8.allSatisfy({ byte in
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
    }) else { throw invalid() }
    let padded = value.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let data = Data(base64Encoded: padded), encodeBase64(Array(data)) == value else { throw invalid() }
    return Array(data)
  }
}

struct ReferenceReader {
  let data: [UInt8]
  var offset = 0
  mutating func take(_ count: Int) throws -> [UInt8] {
    guard count >= 0, count <= data.count - offset else { throw ReferenceWire.invalid() }
    defer { offset += count }; return Array(data[offset..<(offset + count)])
  }
  mutating func u16() throws -> UInt16 {
    let bytes = try take(2); return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
  }
  mutating func u64() throws -> UInt64 {
    try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }
  mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
  mutating func text16() throws -> String {
    let bytes = try take(Int(u16()))
    guard let text = String(bytes: bytes, encoding: .utf8) else { throw ReferenceWire.invalid() }
    try ReferenceWire.text(text); return text
  }
  func end() throws { guard offset == data.count else { throw ReferenceWire.invalid() } }
}

public struct ContextBoundReferenceRuntime: Sendable {
  let service: String
  let environment: String
  let keys: any ReferenceKeyProvider
  let authorize: @Sendable (TrustedReferencePrincipal, ReferenceDocumentScope, ReferenceIdentity) -> Bool
  let now: @Sendable () -> Date
  let nonce: @Sendable () -> [UInt8]

  public init(service: String, environment: String, keys: any ReferenceKeyProvider,
              authorize: @escaping @Sendable (TrustedReferencePrincipal, ReferenceDocumentScope, ReferenceIdentity) -> Bool,
              now: @escaping @Sendable () -> Date = { Date() },
              nonce: @escaping @Sendable () -> [UInt8] = {
                var generator = SystemRandomNumberGenerator()
                return (0..<12).map { _ in UInt8.random(in: 0...255, using: &generator) }
              }) throws {
    do { try ReferenceWire.text(service); try ReferenceWire.text(environment); _ = try keys.currentKey() }
    catch { throw ReferenceWire.config() }
    self.service = service; self.environment = environment; self.keys = keys
    self.authorize = authorize; self.now = now; self.nonce = nonce
  }
  func currentKey() throws -> ReferenceKey { try keys.currentKey() }
  func authorizeIdentity(_ actor: TrustedReferencePrincipal, _ scope: ReferenceDocumentScope,
                         _ identity: ReferenceIdentity) throws {
    guard authorize(actor, scope, identity) else { throw ReferenceWire.denied() }
  }
  func derive(_ key: ReferenceKey, label: String) throws -> [UInt8] {
    var info: [UInt8] = []
    for value in [label, service, environment, key.keyID] { try ReferenceWire.putText16(value, into: &info) }
    let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.masterKey),
      salt: Data("teaql.round-trip-reference.v1".utf8), info: Data(info), outputByteCount: 32)
    return derived.withUnsafeBytes { Array($0) }
  }
  func actorFingerprint(_ key: ReferenceKey, _ actor: TrustedReferencePrincipal) throws -> [UInt8] {
    var canonical: [UInt8] = []
    for value in [actor.authenticationRealm, actor.subject, actor.domainRootType] {
      try ReferenceWire.putText16(value, into: &canonical)
    }
    ReferenceWire.putU64(actor.domainRootID, into: &canonical)
    return Array(HMAC<SHA256>.authenticationCode(for: Data(canonical),
      using: SymmetricKey(data: try derive(key, label: "actor-fingerprint"))))
  }
  func aad(prefix: String, key: ReferenceKey, purpose: String) throws -> [UInt8] {
    var output: [UInt8] = []
    for value in [prefix, key.keyID, service, environment, purpose] {
      if prefix == "tqr1" { try ReferenceWire.putText16(value, into: &output) }
      else { try DocumentWire.putText(value, into: &output) }
    }
    return output
  }
  func seal(prefix: String, label: String, key: ReferenceKey, purpose: String,
            plain: [UInt8], maximum: Int) throws -> String {
    let nonceBytes = nonce()
    guard nonceBytes.count == 12 else { throw ReferenceWire.config() }
    let sealed = try AES.GCM.seal(Data(plain), using: SymmetricKey(data: try derive(key, label: label)),
      nonce: AES.GCM.Nonce(data: Data(nonceBytes)), authenticating: Data(try aad(prefix: prefix, key: key, purpose: purpose)))
    let token = prefix + "." + key.keyID + "." + ReferenceWire.encodeBase64(
      nonceBytes + Array(sealed.ciphertext) + Array(sealed.tag))
    guard token.utf8.count <= maximum else { throw ReferenceWire.invalid() }
    return token
  }
  func open(prefix: String, label: String, purpose: String, token: String, maximum: Int) throws -> (ReferenceKey, [UInt8]) {
    guard token.utf8.count <= maximum else { throw ReferenceWire.invalid() }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == Substring(prefix), ReferenceWire.validKeyID(String(parts[1])),
      let key = try keys.key(id: String(parts[1])), key.keyID == parts[1] else { throw ReferenceWire.invalid() }
    let envelope = try ReferenceWire.decodeBase64(String(parts[2]))
    guard envelope.count >= 28 else { throw ReferenceWire.invalid() }
    let ciphertext = Array(envelope[12..<(envelope.count - 16)])
    do {
      let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(envelope[0..<12])),
        ciphertext: Data(ciphertext), tag: Data(envelope[(envelope.count - 16)...]))
      let plain = try AES.GCM.open(box, using: SymmetricKey(data: try derive(key, label: label)),
        authenticating: Data(try aad(prefix: prefix, key: key, purpose: purpose)))
      return (key, Array(plain))
    } catch { throw ReferenceWire.invalid() }
  }
  func times(lifetimeSeconds: Int64) throws -> (Int64, Int64) {
    guard lifetimeSeconds > 0 else { throw ReferenceWire.invalid() }
    let issued = Int64(now().timeIntervalSince1970.rounded(.down))
    let (expires, overflow) = issued.addingReportingOverflow(lifetimeSeconds)
    guard !overflow else { throw ReferenceWire.invalid() }
    return (issued, expires)
  }
  func verify(actor: TrustedReferencePrincipal, key: ReferenceKey, fingerprint: [UInt8],
              issued: Int64, expires: Int64, scope: ReferenceDocumentScope,
              aggregateType: String, purpose: String) throws -> (Date, Date) {
    let current = Int64(now().timeIntervalSince1970.rounded(.down))
    if expires <= current { throw ReferenceWire.expired() }
    if issued > current + 60 { throw ReferenceWire.invalid() }
    let expected = try actorFingerprint(key, actor)
    var difference: UInt8 = UInt8(truncatingIfNeeded: fingerprint.count ^ expected.count)
    for (left, right) in zip(fingerprint, expected) { difference |= left ^ right }
    guard difference == 0, scope.aggregateType == aggregateType, scope.purpose == purpose else {
      throw ReferenceWire.mismatch()
    }
    return (Date(timeIntervalSince1970: TimeInterval(issued)), Date(timeIntervalSince1970: TimeInterval(expires)))
  }
  public func issue(_ actor: TrustedReferencePrincipal, scope: ReferenceDocumentScope,
                    identity: ReferenceIdentity, lifetimeSeconds: Int64) throws -> String {
    try ReferenceWire.principal(actor); try ReferenceWire.scope(scope); try ReferenceWire.identity(identity)
    try authorizeIdentity(actor, scope, identity)
    let key = try currentKey(); let (issued, expires) = try times(lifetimeSeconds: lifetimeSeconds)
    var plain = try actorFingerprint(key, actor)
    try ReferenceWire.putText16(identity.entityType, into: &plain)
    ReferenceWire.putU64(identity.id, into: &plain); ReferenceWire.putI64(identity.version, into: &plain)
    try ReferenceWire.putText16(scope.documentID, into: &plain)
    try ReferenceWire.putText16(scope.aggregateType, into: &plain)
    ReferenceWire.putU64(scope.aggregateID, into: &plain)
    ReferenceWire.putI64(scope.aggregateRevision, into: &plain)
    ReferenceWire.putI64(issued, into: &plain); ReferenceWire.putI64(expires, into: &plain)
    return try seal(prefix: "tqr1", label: "entity-reference-encryption", key: key,
      purpose: scope.purpose, plain: plain, maximum: 24_000)
  }
  public func consume(_ actor: TrustedReferencePrincipal, scope: ReferenceDocumentScope,
                      token: String, expectedEntityType: String) throws -> VerifiedEntityReference {
    try ReferenceWire.principal(actor); try ReferenceWire.scope(scope); try ReferenceWire.text(expectedEntityType)
    let (key, plain) = try open(prefix: "tqr1", label: "entity-reference-encryption",
      purpose: scope.purpose, token: token, maximum: 24_000)
    var reader = ReferenceReader(data: plain)
    let fingerprint = try reader.take(32)
    let identity = try ReferenceIdentity(entityType: reader.text16(), id: reader.u64(), version: reader.i64())
    let documentID = try reader.text16(); let aggregateType = try reader.text16()
    let aggregateID = try reader.u64(); let revision = try reader.i64()
    let issued = try reader.i64(); let expires = try reader.i64(); try reader.end()
    try ReferenceWire.identity(identity)
    let current = Int64(now().timeIntervalSince1970.rounded(.down))
    if expires <= current { throw ReferenceWire.expired() }
    if issued > current + 60 { throw ReferenceWire.invalid() }
    let expected = try actorFingerprint(key, actor)
    var difference: UInt8 = UInt8(truncatingIfNeeded: fingerprint.count ^ expected.count)
    for (left, right) in zip(fingerprint, expected) { difference |= left ^ right }
    guard difference == 0, documentID == scope.documentID, aggregateType == scope.aggregateType,
      aggregateID == scope.aggregateID, revision == scope.aggregateRevision,
      identity.entityType == expectedEntityType else { throw ReferenceWire.mismatch() }
    try authorizeIdentity(actor, scope, identity)
    return VerifiedEntityReference(identity: identity, keyID: key.keyID,
      issuedAt: Date(timeIntervalSince1970: TimeInterval(issued)),
      expiresAt: Date(timeIntervalSince1970: TimeInterval(expires)))
  }
}
