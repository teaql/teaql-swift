import Crypto
import Foundation
import TeaQLCore

public struct BlobUploadTarget: Sendable, Equatable {
  public let entity: String
  public let entityID: String
  public let field: String
  public init(entity: String, entityID: String, field: String) {
    self.entity = entity; self.entityID = entityID; self.field = field
  }
}

public struct BlobUploadInput: Sendable, Equatable {
  public let fileName: String
  public let declaredSize: Int64
  public let declaredContentType: String?
  public init(fileName: String, declaredSize: Int64, declaredContentType: String? = nil) {
    self.fileName = fileName; self.declaredSize = declaredSize
    self.declaredContentType = declaredContentType
  }
}

public struct BlobVerifiedContent: Sendable {
  public let sizeBytes: Int64
  public let sha256: String
  public let contentType: String
  public init(sizeBytes: Int64, sha256: String, contentType: String) {
    self.sizeBytes = sizeBytes; self.sha256 = sha256; self.contentType = contentType
  }
}

public struct BlobUploadSession: Sendable, CustomStringConvertible {
  public let uploadID: String
  public let reference: BlobRef
  public let expiresAt: Date
  public var description: String { "BlobUploadSession[masked]" }
}

public struct BlobUploadAuthorizationSnapshot: Sendable {
  public let scope: String
  public let field: BlobFieldSpec
  public let allowed: Bool
  public init(scope: String, field: BlobFieldSpec, allowed: Bool) {
    self.scope = scope; self.field = field; self.allowed = allowed
  }
}

/// Host policy must resolve the current model, scope and action on every stage.
public protocol BlobUploadAuthorization: Sendable {
  func scope(for actor: UserContext) throws -> String
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec
  func authorize(actor: UserContext, target: BlobUploadTarget, action: String,
                 input: BlobUploadInput) async throws -> Bool
  /// Resolve the current scope, modeled field and action on the upload's physical SQL owner.
  func currentOnLease(actor: UserContext, target: BlobUploadTarget, action: String,
                      input: BlobUploadInput, lease: any GraphPhysicalSQLLease)
    async throws -> BlobUploadAuthorizationSnapshot
}

/// Host-supplied parser must consume every stored byte and report actual format.
public protocol BlobContentVerifier: Sendable {
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent
}

private actor HashingBlobReader: ObjectByteReader {
  struct Snapshot: Sendable { let count: Int64; let eof: Bool; let sha256: String }
  let source: any ObjectByteReader
  let maximum: Int64
  var digest = SHA256()
  var count: Int64 = 0
  var eof = false
  init(_ source: any ObjectByteReader, maximum: Int64) { self.source = source; self.maximum = maximum }
  func read(upToCount amount: Int) async throws -> Data {
    guard amount >= 0 else { throw StorageError(.invalidInput) }
    let bytes = try await source.read(upToCount: amount)
    guard bytes.count <= amount else { throw StorageError(.io) }
    guard Int64(bytes.count) <= maximum - count else { throw StorageError(.tooLarge) }
    count += Int64(bytes.count)
    if bytes.isEmpty && amount > 0 { eof = true }
    digest.update(data: bytes)
    return bytes
  }
  func close() async throws { try await source.close() }
  func snapshot() -> Snapshot {
    Snapshot(count: count, eof: eof,
      sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

/// Host-invoked SQLite upload journal; schema installation and parser selection are explicit.
public struct SQLiteBlobUploadService: Sendable {
  private let authorization: any BlobUploadAuthorization
  private let verifier: any BlobContentVerifier
  private let maximumBytes: Int64
  private let leaseSeconds: Int
  private let now: @Sendable () -> Date

  private struct Row: Sendable {
    let id: String, scope: String, key: String, entity: String, entityID: String
    let field: String, fileName: String, ext: String, state: String
    let declaredSize: Int64, expiresMs: Int64
    let writtenSHA256: String?, writtenETag: String?
  }

  private static func fail(_ code: String) -> TeaQLError { .execution(code) }
  private static func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
  private static func token() -> String {
    Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
  private static func validText(_ value: String, maximum: Int) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= maximum
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  private static func validID(_ value: String) -> Bool {
    value.isEmpty || (UInt64(value).map { $0 > 0 && String($0) == value } ?? false)
  }
  private static func validUploadID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 35 && bytes.starts(with: Array("bu_".utf8))
      && bytes.dropFirst(3).allSatisfy { (48...57).contains($0) || (65...90).contains($0)
        || (97...122).contains($0) || $0 == 45 || $0 == 95 }
  }
  private static func extensionOf(_ name: String) -> String {
    String(name.split(separator: ".", omittingEmptySubsequences: false).last ?? "").lowercased()
  }
  private func millis() -> Int64 { Int64(now().timeIntervalSince1970 * 1000) }

  public init(authorization: any BlobUploadAuthorization, verifier: any BlobContentVerifier,
              maximumBytes: Int64, leaseSeconds: Int = 900,
              now: @escaping @Sendable () -> Date = { Date() }) throws {
    guard (1...ObjectPutOptions.maximumSize).contains(maximumBytes),
      (1...3600).contains(leaseSeconds) else { throw Self.fail("BLOB_POLICY_INVALID") }
    self.authorization = authorization; self.verifier = verifier
    self.maximumBytes = maximumBytes; self.leaseSeconds = leaseSeconds; self.now = now
  }

  private func normalize(_ input: BlobUploadInput) throws -> (BlobUploadInput, String) {
    guard input.declaredSize >= 0, input.declaredSize <= maximumBytes else {
      throw Self.fail("BLOB_SIZE_EXCEEDED")
    }
    guard Self.validText(input.fileName, maximum: 1024) else {
      throw Self.fail("BLOB_FORMAT_NOT_ALLOWED")
    }
    let normalized = input.fileName.replacingOccurrences(of: "\\", with: "/")
    let name = String(normalized.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    let ext = Self.extensionOf(name)
    guard Self.validText(name, maximum: 512), BlobFieldSpec.mime(forExtension: ext) != nil else {
      throw Self.fail("BLOB_FORMAT_NOT_ALLOWED")
    }
    let declared = input.declaredContentType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let declared, !declared.isEmpty, !Self.validText(declared, maximum: 128) {
      throw Self.fail("BLOB_FORMAT_NOT_ALLOWED")
    }
    return (BlobUploadInput(fileName: name, declaredSize: input.declaredSize,
      declaredContentType: declared), ext)
  }

  private func current(_ actor: UserContext, target: BlobUploadTarget, action: String,
                       input: BlobUploadInput, expectedScope: String? = nil,
                       lease: (any GraphPhysicalSQLLease)? = nil) async throws -> String {
    guard Self.validText(target.entity, maximum: 256),
      target.entity.unicodeScalars.count <= 128,
      Self.validText(target.field, maximum: 256),
      target.field.unicodeScalars.count <= 128, Self.validID(target.entityID) else {
      throw Self.fail("BLOB_REFERENCE_INVALID")
    }
    let scope: String
    let field: BlobFieldSpec
    let allowed: Bool
    do {
      if let lease {
        let snapshot = try await authorization.currentOnLease(actor: actor, target: target,
          action: action, input: input, lease: lease)
        scope = snapshot.scope; field = snapshot.field; allowed = snapshot.allowed
      } else {
        scope = try authorization.scope(for: actor)
        field = try authorization.field(for: actor, target: target)
        allowed = try await authorization.authorize(actor: actor, target: target,
          action: action, input: input)
      }
    } catch { throw Self.fail("BLOB_UPLOAD_DENIED") }
    guard Self.validText(scope, maximum: 256), expectedScope.map({ $0 == scope }) ?? true,
      field.entity == target.entity, field.field == target.field, allowed else {
      throw Self.fail("BLOB_UPLOAD_DENIED")
    }
    guard field.allowedExtensions.contains(Self.extensionOf(input.fileName)) else {
      throw Self.fail("BLOB_FORMAT_NOT_ALLOWED")
    }
    return scope
  }

  public func begin(_ actor: UserContext, target: BlobUploadTarget, input: BlobUploadInput,
                    replayKey: String) async throws -> BlobUploadSession {
    let (normalized, ext) = try normalize(input)
    guard Self.validText(replayKey, maximum: 256) else { throw Self.fail("BLOB_REFERENCE_INVALID") }
    let scope = try await current(actor, target: target, action: "Begin", input: normalized)
    let parts = [target.entity, target.entityID, target.field, normalized.fileName,
      String(normalized.declaredSize), normalized.declaredContentType ?? ""]
    let requestHash = Self.hex(SHA256.hash(data: try JSONEncoder().encode(parts)))
    return try await actor.executeGraphSave(comment: "begin Blob upload") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await current(graph, target: target, action: "Begin", input: normalized,
          expectedScope: scope, lease: sql)
        let rows: [TeaQLRecord]
        do { rows = try await sql.query("""
          SELECT upload_id,key,request_hash,expires_ms FROM teaql_blob_upload
          WHERE scope = ? AND replay_key = ?
          """, parameters: [.string(scope), .string(replayKey)]) }
        catch { throw Self.fail("BLOB_CATALOG_FAILED") }
        guard rows.count <= 1 else { throw Self.fail("BLOB_CATALOG_FAILED") }
        if let old = rows.first {
          guard old["request_hash"]?.stringValue == requestHash else {
            throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
          }
          _ = try await current(graph, target: target, action: "Begin", input: normalized,
            expectedScope: scope, lease: sql)
          guard let id = old["upload_id"]?.stringValue,
            let key = old["key"]?.stringValue,
            let expiry = old["expires_ms"]?.int64Value,
            let reference = try? BlobRef(key) else { throw Self.fail("BLOB_CATALOG_FAILED") }
          guard millis() < expiry else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
          return BlobUploadSession(uploadID: id, reference: reference,
            expiresAt: Date(timeIntervalSince1970: Double(expiry) / 1000))
        }
        let reference = try BlobRef("blob_" + Self.token())
        let id = "bu_" + Self.token(), objectKey = "blob/" + Self.token()
        let expiry = millis() + Int64(leaseSeconds) * 1000
        _ = try await current(graph, target: target, action: "Begin", input: normalized,
          expectedScope: scope, lease: sql)
        do {
          _ = try await sql.execute("""
            INSERT INTO teaql_blob_catalog
            (key,scope,object_key,content_version,file_name,content_type,size_bytes,status)
            VALUES (?,?,?,?,?,?,?,?)
            """, parameters: [.string(reference.key), .string(scope), .string(objectKey),
              .string(""), .string(normalized.fileName), .string(""), .int(0), .string("initiated")])
          _ = try await sql.execute("""
            INSERT INTO teaql_blob_upload
            (upload_id,scope,replay_key,request_hash,key,entity,entity_id,field,file_name,
             extension,declared_size,expires_ms,state) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, parameters: [.string(id), .string(scope), .string(replayKey),
              .string(requestHash), .string(reference.key), .string(target.entity),
              .string(target.entityID), .string(target.field), .string(normalized.fileName),
              .string(ext), .int(normalized.declaredSize), .int(expiry), .string("initiated")])
        } catch { throw Self.fail("BLOB_CATALOG_FAILED") }
        return BlobUploadSession(uploadID: id, reference: reference,
          expiresAt: Date(timeIntervalSince1970: Double(expiry) / 1000))
      }
    }
  }

  private func row(_ actor: UserContext, uploadID: String, action: String,
                   lease: any GraphPhysicalSQLLease) async throws -> Row {
    guard Self.validUploadID(uploadID) else { throw Self.fail("BLOB_UPLOAD_DENIED") }
    let scope: String
    do { scope = try authorization.scope(for: actor) }
    catch { throw Self.fail("BLOB_UPLOAD_DENIED") }
    guard Self.validText(scope, maximum: 256) else { throw Self.fail("BLOB_UPLOAD_DENIED") }
    let rows: [TeaQLRecord]
    do { rows = try await lease.query("""
      SELECT upload_id,scope,key,entity,entity_id,field,file_name,extension,
        declared_size,expires_ms,state,written_sha256,written_etag
      FROM teaql_blob_upload WHERE scope = ? AND upload_id = ?
      """, parameters: [.string(scope), .string(uploadID)]) }
    catch { throw Self.fail("BLOB_CATALOG_FAILED") }
    guard rows.count == 1 else { throw Self.fail("BLOB_UPLOAD_DENIED") }
    let r = rows[0]
    guard let id = r["upload_id"]?.stringValue, let rowScope = r["scope"]?.stringValue,
      let key = r["key"]?.stringValue, let entity = r["entity"]?.stringValue,
      let entityID = r["entity_id"]?.stringValue, let field = r["field"]?.stringValue,
      let fileName = r["file_name"]?.stringValue, let ext = r["extension"]?.stringValue,
      let size = r["declared_size"]?.int64Value, let expiry = r["expires_ms"]?.int64Value,
      let state = r["state"]?.stringValue else { throw Self.fail("BLOB_CATALOG_FAILED") }
    let found = Row(id: id, scope: rowScope, key: key, entity: entity, entityID: entityID,
      field: field, fileName: fileName, ext: ext, state: state, declaredSize: size,
      expiresMs: expiry, writtenSHA256: r["written_sha256"]?.stringValue,
      writtenETag: r["written_etag"]?.stringValue)
    _ = try await current(actor, target: BlobUploadTarget(entity: found.entity,
      entityID: found.entityID, field: found.field), action: action,
      input: BlobUploadInput(fileName: found.fileName, declaredSize: found.declaredSize),
      expectedScope: scope, lease: lease)
    guard millis() < found.expiresMs else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
    guard found.declaredSize >= 0, found.declaredSize <= maximumBytes else {
      throw Self.fail("BLOB_SIZE_EXCEEDED")
    }
    guard found.ext == Self.extensionOf(found.fileName), found.scope == scope else {
      throw Self.fail("BLOB_CATALOG_FAILED")
    }
    return found
  }

  private func objectKey(_ row: Row, lease: any GraphPhysicalSQLLease) async throws -> ObjectKey {
    let rows: [TeaQLRecord]
    do { rows = try await lease.query("""
      SELECT object_key,status FROM teaql_blob_catalog WHERE key = ? AND scope = ?
      """, parameters: [.string(row.key), .string(row.scope)]) }
    catch { throw Self.fail("BLOB_CATALOG_FAILED") }
    guard rows.count == 1, rows[0]["status"]?.stringValue == "initiated",
      let raw = rows[0]["object_key"]?.stringValue,
      let key = try? ObjectKey(raw) else { throw Self.fail("BLOB_CATALOG_FAILED") }
    return key
  }

  public func write(_ actor: UserContext, uploadID: String,
                    source: any ObjectByteReader) async throws -> Int64 {
    do {
      return try await actor.executeGraphSave(comment: "journal Blob write") { graph, session in
        try await graph.withPhysicalSQL(session) { sql in
          let entry = try await row(actor, uploadID: uploadID, action: "Write", lease: sql)
          guard entry.state == "initiated" else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
          let key = try await objectKey(entry, lease: sql)
          guard let mime = BlobFieldSpec.mime(forExtension: entry.ext) else {
            throw Self.fail("BLOB_FORMAT_NOT_ALLOWED")
          }
          let reader = HashingBlobReader(source, maximum: entry.declaredSize)
          let metadata: ObjectMetadata
          do {
            metadata = try await actor.objectStorage("write Blob upload").put(key, content: reader,
              options: ObjectPutOptions(size: entry.declaredSize, mode: .createOnly,
                contentType: mime))
          } catch { throw Self.fail("BLOB_STORE_FAILED") }
          _ = try await current(actor, target: BlobUploadTarget(entity: entry.entity,
            entityID: entry.entityID, field: entry.field), action: "Write",
            input: BlobUploadInput(fileName: entry.fileName, declaredSize: entry.declaredSize),
            expectedScope: entry.scope, lease: sql)
          guard millis() < entry.expiresMs else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
          let observed = await reader.snapshot()
          guard observed.eof, observed.count == entry.declaredSize,
            metadata.size == observed.count, let etag = metadata.etag, !etag.isEmpty else {
            throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
          }
          let nowMs = millis()
          guard nowMs < entry.expiresMs else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
          let affected: Int
          do { affected = try await sql.execute("""
            UPDATE teaql_blob_upload SET state = 'written',written_sha256 = ?,written_etag = ?
            WHERE upload_id = ? AND scope = ? AND state = 'initiated' AND expires_ms > ?
              AND EXISTS (SELECT 1 FROM teaql_blob_catalog
                WHERE key = teaql_blob_upload.key AND scope = teaql_blob_upload.scope
                  AND status = 'initiated')
            """, parameters: [.string(observed.sha256), .string(etag),
              .string(uploadID), .string(entry.scope), .int(nowMs)]) }
          catch { throw Self.fail("BLOB_CATALOG_FAILED") }
          guard affected == 1 else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
          return observed.count
        }
      }
    } catch {
      try? await source.close()
      throw error
    }
  }

  public func complete(_ actor: UserContext, uploadID: String) async throws -> BlobRef {
    try await actor.executeGraphSave(comment: "confirm Blob upload") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let entry = try await row(actor, uploadID: uploadID, action: "Confirm", lease: sql)
        if entry.state == "completed" {
          guard let writtenHash = entry.writtenSHA256, writtenHash.utf8.count == 64,
            writtenHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let writtenETag = entry.writtenETag, !writtenETag.isEmpty,
            let mime = BlobFieldSpec.mime(forExtension: entry.ext) else {
            throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
          }
          let rows: [TeaQLRecord]
          do { rows = try await sql.query("""
            SELECT object_key,content_version,content_type,size_bytes,status
            FROM teaql_blob_catalog WHERE key = ? AND scope = ?
            """, parameters: [.string(entry.key), .string(entry.scope)]) }
          catch { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
          guard rows.count == 1, let raw = rows[0]["object_key"]?.stringValue,
            let key = try? ObjectKey(raw),
            rows[0]["content_version"]?.stringValue == writtenETag,
            rows[0]["content_type"]?.stringValue == mime,
            rows[0]["size_bytes"]?.int64Value == entry.declaredSize,
            ["uploaded_unbound", "available"].contains(rows[0]["status"]?.stringValue ?? "") else {
            throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
          }
          let store: ObjectStorage
          do { store = try actor.objectStorage("recheck completed Blob upload") }
          catch { throw Self.fail("BLOB_STORE_FAILED") }
          do {
            guard let head = try await store.head(key), head.size == entry.declaredSize,
              head.etag == writtenETag else { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
          } catch { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
          _ = try await current(actor, target: BlobUploadTarget(entity: entry.entity,
            entityID: entry.entityID, field: entry.field), action: "Confirm",
            input: BlobUploadInput(fileName: entry.fileName, declaredSize: entry.declaredSize,
              declaredContentType: mime), expectedScope: entry.scope, lease: sql)
          guard millis() < entry.expiresMs else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
          return try BlobRef(entry.key)
        }
        guard entry.state == "written", let writtenHash = entry.writtenSHA256,
          let writtenETag = entry.writtenETag, !writtenHash.isEmpty, !writtenETag.isEmpty else {
          throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
        }
        let key = try await objectKey(entry, lease: sql)
        let store: ObjectStorage
        do { store = try actor.objectStorage("verify Blob upload") }
        catch { throw Self.fail("BLOB_STORE_FAILED") }
        let before: ObjectMetadata
        do {
          guard let head = try await store.head(key), head.size == entry.declaredSize,
            head.etag == writtenETag else { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
          before = head
        } catch { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
        let content: ObjectContent
        do { content = try await store.get(key) }
        catch { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
        let verified: BlobVerifiedContent
        do {
          guard content.metadata.size == before.size, content.metadata.etag == before.etag else {
            throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
          }
          let reader = HashingBlobReader(content.reader, maximum: maximumBytes)
          verified = try await verifier.verify(reader: reader, extension: entry.ext,
            maximumBytes: maximumBytes)
          let observed = await reader.snapshot()
          guard observed.eof, observed.count == before.size, verified.sizeBytes == observed.count,
            verified.sha256 == observed.sha256, verified.sha256 == writtenHash,
            verified.contentType == BlobFieldSpec.mime(forExtension: entry.ext) else {
            throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
          }
          try await content.close()
        } catch {
          try? await content.close()
          throw Self.fail("BLOB_UPLOAD_INCOMPLETE")
        }
        do {
          guard let after = try await store.head(key), after.size == before.size,
            after.etag == before.etag else { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
        } catch { throw Self.fail("BLOB_UPLOAD_INCOMPLETE") }
        _ = try await current(actor, target: BlobUploadTarget(entity: entry.entity,
          entityID: entry.entityID, field: entry.field), action: "Confirm",
          input: BlobUploadInput(fileName: entry.fileName, declaredSize: entry.declaredSize,
            declaredContentType: verified.contentType), expectedScope: entry.scope, lease: sql)
        let nowMs = millis()
        guard nowMs < entry.expiresMs else { throw Self.fail("BLOB_UPLOAD_EXPIRED") }
        let completed: Int
        do { completed = try await sql.execute("""
          UPDATE teaql_blob_upload SET state = 'completed'
          WHERE upload_id = ? AND scope = ? AND state = 'written'
            AND written_sha256 = ? AND written_etag = ? AND expires_ms > ?
          """, parameters: [.string(uploadID), .string(entry.scope),
            .string(writtenHash), .string(writtenETag), .int(nowMs)]) }
        catch { throw Self.fail("BLOB_CATALOG_FAILED") }
        guard completed == 1 else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
        let promoted: Int
        do { promoted = try await sql.execute("""
          UPDATE teaql_blob_catalog SET content_version = ?,content_type = ?,size_bytes = ?,
            status = 'uploaded_unbound' WHERE key = ? AND scope = ? AND status = 'initiated'
          """, parameters: [.string(writtenETag), .string(verified.contentType),
            .int(verified.sizeBytes), .string(entry.key), .string(entry.scope)]) }
        catch { throw Self.fail("BLOB_CATALOG_FAILED") }
        guard promoted == 1 else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
        return try BlobRef(entry.key)
      }
    }
  }
}
