import Foundation
import TeaQLCore

public struct BlobBindingTarget: Sendable, Equatable {
  public let entity: String
  public let entityID: String
  public let field: String

  public init(entity: String, entityID: String, field: String) {
    self.entity = entity
    self.entityID = entityID
    self.field = field
  }
}

public struct BlobBindingChange: Sendable {
  public let target: BlobBindingTarget
  public let next: BlobRef?
  public let expectedVersion: Int64
  public let nextVersion: Int64
  public let action: String

  public init(target: BlobBindingTarget, next: BlobRef?, expectedVersion: Int64,
              nextVersion: Int64, action: String) {
    self.target = target
    self.next = next
    self.expectedVersion = expectedVersion
    self.nextVersion = nextVersion
    self.action = action
  }
}

public struct BlobCatalogRead: Sendable {
  public let objectKey: String
  public let contentVersion: String
  public let fileName: String
  public let contentType: String
  public let sizeBytes: Int64
}

public protocol BlobBindingAuthorization: Sendable {
  func scope(for actor: UserContext) throws -> String
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool
}

/// An explicit SQLite schema and binding component; the host owns installation and graph calls.
public struct SQLiteBlobCatalog: Sendable {
  public init() {}

  public func installSchema(_ actor: UserContext, session: GraphMutationSession) async throws {
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TABLE IF NOT EXISTS teaql_blob_catalog (
          key TEXT PRIMARY KEY, scope TEXT NOT NULL, object_key TEXT NOT NULL,
          content_version TEXT NOT NULL, file_name TEXT NOT NULL,
          content_type TEXT NOT NULL, size_bytes BIGINT NOT NULL,
          status TEXT NOT NULL CHECK (status IN
            ('initiated','uploaded_unbound','available','deleting','deleted')))
        """, parameters: [])
      _ = try await sql.execute("""
        CREATE TABLE IF NOT EXISTS teaql_blob_binding (
          scope TEXT NOT NULL, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
          field TEXT NOT NULL, key TEXT, version BIGINT NOT NULL,
          PRIMARY KEY (scope,entity,entity_id,field),
          FOREIGN KEY (key) REFERENCES teaql_blob_catalog(key))
        """, parameters: [])
      _ = try await sql.execute("CREATE INDEX IF NOT EXISTS teaql_blob_binding_key ON teaql_blob_binding(key)",
        parameters: [])
      _ = try await sql.execute("""
        CREATE TABLE IF NOT EXISTS teaql_blob_upload (
          upload_id TEXT PRIMARY KEY, scope TEXT NOT NULL, replay_key TEXT NOT NULL,
          request_hash TEXT NOT NULL, key TEXT NOT NULL, entity TEXT NOT NULL,
          entity_id TEXT NOT NULL, field TEXT NOT NULL, file_name TEXT NOT NULL,
          extension TEXT NOT NULL, declared_size BIGINT NOT NULL,
          expires_ms BIGINT NOT NULL, state TEXT NOT NULL CHECK
            (state IN ('initiated','written','completed')),
          written_sha256 TEXT, written_etag TEXT,
          UNIQUE(scope,replay_key), FOREIGN KEY(key) REFERENCES teaql_blob_catalog(key))
        """, parameters: [])
    }
  }

  public func validateSchema(_ actor: UserContext, session: GraphMutationSession) async throws {
    try await actor.withPhysicalSQL(session) { sql in
      _ = try await sql.query("""
        SELECT key,scope,object_key,content_version,file_name,content_type,size_bytes,status
        FROM teaql_blob_catalog WHERE 1 = 0
        """, parameters: [])
      _ = try await sql.query("""
        SELECT scope,entity,entity_id,field,key,version FROM teaql_blob_binding WHERE 1 = 0
        """, parameters: [])
      _ = try await sql.query("""
        SELECT upload_id,scope,replay_key,request_hash,key,entity,entity_id,field,file_name,
          extension,declared_size,expires_ms,state,written_sha256,written_etag
        FROM teaql_blob_upload WHERE 1 = 0
        """, parameters: [])
      let columns = try await sql.query("PRAGMA table_info(teaql_blob_binding)", parameters: [])
      guard columns.first(where: { $0["name"]?.stringValue == "key" })?["notnull"]?.int64Value == 0,
        columns.first(where: { $0["name"]?.stringValue == "version" })?["notnull"]?.int64Value == 1
      else { throw TeaQLError.execution("BLOB_SCHEMA_MISSING") }
    }
  }

  /// Start a fresh owner transaction after business completion to reread the exact binding.
  public func currentRead(_ actor: UserContext, slot: AuthorizedBlobSlot) async throws -> BlobCatalogRead {
    guard Self.validScope(slot.scope), Self.validName(slot.entity),
      Self.validEntityID(slot.entityID), Self.validName(slot.field), slot.bindingVersion > 0 else {
      throw ViewPreparationError("BLOB_READ_DENIED")
    }
    return try await actor.executeGraphSave(comment: "recheck current Blob binding") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let rows: [TeaQLRecord]
        do {
          rows = try await sql.query("""
            SELECT c.object_key,c.content_version,c.file_name,c.content_type,c.size_bytes
            FROM teaql_blob_binding b JOIN teaql_blob_catalog c ON c.key = b.key
            WHERE b.scope = ? AND b.entity = ? AND b.entity_id = ? AND b.field = ?
              AND b.key = ? AND b.version = ?
              AND c.scope = b.scope AND c.status = 'available'
            """, parameters: [.string(slot.scope), .string(slot.entity),
              .string(slot.entityID), .string(slot.field), .string(slot.reference.key),
              .int(slot.bindingVersion)])
        } catch { throw ViewPreparationError("BLOB_CATALOG_FAILED") }
        guard rows.count == 1 else { throw ViewPreparationError("BLOB_READ_DENIED") }
        let row = rows[0]
        guard let objectKey = row["object_key"]?.stringValue, !objectKey.isEmpty,
          let version = row["content_version"]?.stringValue, !version.isEmpty,
          let fileName = row["file_name"]?.stringValue, !fileName.isEmpty,
          let contentType = row["content_type"]?.stringValue, !contentType.isEmpty,
          let size = row["size_bytes"]?.int64Value, size >= 0 else {
          throw ViewPreparationError("BLOB_CATALOG_FAILED")
        }
        return BlobCatalogRead(objectKey: objectKey, contentVersion: version,
          fileName: fileName, contentType: contentType, sizeBytes: size)
      }
    }
  }

  public func bind(_ actor: UserContext, session: GraphMutationSession,
                   change: BlobBindingChange, authorization: any BlobBindingAuthorization) async throws -> Int64 {
    try await actor.withPhysicalSQL(session) { sql in
      let target = change.target
      guard Self.validName(target.entity), Self.validName(target.field),
        Self.validEntityID(target.entityID), change.expectedVersion >= 0,
        change.nextVersion > change.expectedVersion,
        ["Create", "Update", "Delete"].contains(change.action),
        !(change.action == "Create" && change.expectedVersion != 0),
        !(change.action == "Delete" && change.next != nil)
      else { throw TeaQLError.execution("BLOB_REFERENCE_INVALID") }
      let scope: String
      do { scope = try authorization.scope(for: actor) }
      catch { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      guard Self.validScope(scope) else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      let identity: [TeaQLValue] = [.string(scope), .string(target.entity),
        .string(target.entityID), .string(target.field)]
      let rows = try await sql.query("""
        SELECT key,version FROM teaql_blob_binding
        WHERE scope = ? AND entity = ? AND entity_id = ? AND field = ?
        """, parameters: identity)
      guard rows.count <= 1 else { throw TeaQLError.execution("BLOB_CATALOG_FAILED") }
      let row = rows.first
      let version = row?["version"]?.int64Value ?? 0
      guard version >= 0, version == change.expectedVersion else {
        throw TeaQLError.execution("BLOB_BIND_DENIED")
      }
      var previous: BlobRef?
      if let key = row?["key"], key != .null {
        guard let raw = key.stringValue, let reference = try? BlobRef(raw) else {
          throw TeaQLError.execution("BLOB_CATALOG_FAILED")
        }
        previous = reference
      }
      let allowed: Bool
      do {
        allowed = try await authorization.authorize(actor: actor, target: target,
          previous: previous, next: change.next, action: change.action)
      } catch { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      guard allowed else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      if let next = change.next {
        let available = try await sql.query("""
          SELECT key FROM teaql_blob_catalog
          WHERE key = ? AND scope = ? AND status IN ('uploaded_unbound','available')
          """, parameters: [.string(next.key), .string(scope)])
        guard available.count == 1 else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      }
      let next: TeaQLValue = change.next.map { .string($0.key) } ?? .null
      let affected: Int
      if row != nil {
        affected = try await sql.execute("""
          UPDATE teaql_blob_binding SET key = ?, version = ?
          WHERE scope = ? AND entity = ? AND entity_id = ? AND field = ? AND version = ?
          """, parameters: [next, .int(change.nextVersion)] + identity + [.int(version)])
      } else {
        affected = try await sql.execute("""
          INSERT INTO teaql_blob_binding (scope,entity,entity_id,field,key,version)
          VALUES (?,?,?,?,?,?)
          """, parameters: identity + [next, .int(change.nextVersion)])
      }
      guard affected == 1 else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      if let next = change.next {
        let promoted = try await sql.execute("""
          UPDATE teaql_blob_catalog SET status = 'available'
          WHERE key = ? AND scope = ? AND status IN ('uploaded_unbound','available')
          """, parameters: [.string(next.key), .string(scope)])
        guard promoted == 1 else { throw TeaQLError.execution("BLOB_BIND_DENIED") }
      }
      if let previous, previous != change.next {
        _ = try await sql.execute("""
          UPDATE teaql_blob_catalog SET status = 'uploaded_unbound'
          WHERE key = ? AND scope = ? AND status = 'available'
            AND NOT EXISTS (SELECT 1 FROM teaql_blob_binding WHERE key = ?)
          """, parameters: [.string(previous.key), .string(scope), .string(previous.key)])
      }
      return change.nextVersion
    }
  }

  private static func validName(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.unicodeScalars.count <= 128
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validScope(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && value.utf8.count <= 256
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validEntityID(_ value: String) -> Bool {
    guard let id = UInt64(value), id > 0 else { return false }
    return String(id) == value
  }
}
