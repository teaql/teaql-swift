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
      let columns = try await sql.query("PRAGMA table_info(teaql_blob_binding)", parameters: [])
      guard columns.first(where: { $0["name"]?.stringValue == "key" })?["notnull"]?.int64Value == 0,
        columns.first(where: { $0["name"]?.stringValue == "version" })?["notnull"]?.int64Value == 1
      else { throw TeaQLError.execution("BLOB_SCHEMA_MISSING") }
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
          WHERE key = ? AND scope = ? AND status = 'available'
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
