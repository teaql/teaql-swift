import Foundation
import TeaQLCore

public protocol BlobMaintenanceAuthorization: Sendable {
  func scope(for actor: UserContext) throws -> String
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool
}

public struct BlobMaintenanceCursor: Sendable, CustomStringConvertible {
  public let scope: String
  public let after: String
  public init(scope: String, after: String) { self.scope = scope; self.after = after }
  public var description: String { "BlobMaintenanceCursor[masked]" }
}
public struct BlobMaintenanceOutcome: Sendable {
  public let reference: BlobRef
  public let status: String
  public let error: String?
  public init(reference: BlobRef, status: String, error: String? = nil) {
    self.reference = reference; self.status = status; self.error = error
  }
}
public struct BlobMaintenanceBatch: Sendable {
  public let outcomes: [BlobMaintenanceOutcome]
  public let next: BlobMaintenanceCursor?
}

/// Host-scheduled bounded cleanup of expired, uncompleted server-stream uploads only.
public struct SQLiteBlobMaintenanceService: Sendable {
  private let catalog: SQLiteBlobCatalog
  private let authorization: any BlobMaintenanceAuthorization
  private let batchSize: Int
  private let now: @Sendable () -> Date

  private struct Row: Sendable {
    let key: String
    let objectKey: String
    let version: String
    let writtenETag: String
    let status: String
    let uploadState: String
    let expiresMs: Int64
  }

  private static func fail(_ code: String) -> TeaQLError { .execution(code) }
  private static func validText(_ value: String, maximum: Int = 256) -> Bool {
    !value.isEmpty && value.utf8.count <= maximum && value != "*"
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  private func millis() throws -> Int64 {
    let value = now().timeIntervalSince1970 * 1000
    guard value >= 0, value < Double(Int64.max) else { throw Self.fail("BLOB_POLICY_INVALID") }
    return Int64(value)
  }

  public init(catalog: SQLiteBlobCatalog = SQLiteBlobCatalog(),
              authorization: any BlobMaintenanceAuthorization, batchSize: Int = 100,
              now: @escaping @Sendable () -> Date = { Date() }) throws {
    guard (1...1000).contains(batchSize) else { throw Self.fail("BLOB_POLICY_INVALID") }
    self.catalog = catalog; self.authorization = authorization
    self.batchSize = batchSize; self.now = now
  }

  private func authorize(_ actor: UserContext, expected: String? = nil) async throws -> String {
    let scope: String
    let allowed: Bool
    do {
      scope = try authorization.scope(for: actor)
      allowed = try await authorization.canMaintain(actor: actor, scope: scope)
    } catch { throw Self.fail("BLOB_MAINTENANCE_DENIED") }
    guard Self.validText(scope), expected.map({ $0 == scope }) ?? true, allowed else {
      throw Self.fail("BLOB_MAINTENANCE_DENIED")
    }
    return scope
  }

  private func read(_ sql: any GraphPhysicalSQLLease, scope: String, key: String) async throws -> Row? {
    let rows: [TeaQLRecord]
    do { rows = try await sql.query("""
      SELECT c.object_key,c.content_version,c.status,u.state,u.expires_ms,u.written_etag
      FROM teaql_blob_catalog c JOIN teaql_blob_upload u ON u.key=c.key AND u.scope=c.scope
      WHERE c.scope=? AND c.key=?
      """, parameters: [.string(scope), .string(key)]) }
    catch { throw Self.fail("BLOB_CATALOG_FAILED") }
    guard rows.count <= 1 else { throw Self.fail("BLOB_CATALOG_FAILED") }
    guard let value = rows.first else { return nil }
    guard let objectKey = value["object_key"]?.stringValue, Self.validText(objectKey, maximum: 1024),
      let version = value["content_version"]?.stringValue,
      version.isEmpty || Self.validText(version),
      let status = value["status"]?.stringValue,
      let state = value["state"]?.stringValue,
      let expires = value["expires_ms"]?.int64Value else { throw Self.fail("BLOB_CATALOG_FAILED") }
    let written = value["written_etag"]?.stringValue ?? ""
    guard written.isEmpty || Self.validText(written), state != "written" || !written.isEmpty else {
      throw Self.fail("BLOB_CATALOG_FAILED")
    }
    return Row(key: key, objectKey: objectKey, version: version,
      writtenETag: written, status: status, uploadState: state, expiresMs: expires)
  }

  private func eligible(_ row: Row?, now: Int64) -> Bool {
    guard let row else { return false }
    return row.expiresMs <= now && ["initiated", "written"].contains(row.uploadState)
      && ["initiated", "deleting"].contains(row.status)
  }

  private func count(_ sql: any GraphPhysicalSQLLease, _ query: String,
                     _ value: String) async throws -> Int64 {
    let rows: [TeaQLRecord]
    do { rows = try await sql.query(query, parameters: [.string(value)]) }
    catch { throw Self.fail("BLOB_CATALOG_FAILED") }
    guard rows.count == 1, let result = rows[0]["n"]?.int64Value, result >= 0 else {
      throw Self.fail("BLOB_CATALOG_FAILED")
    }
    return result
  }

  private func claim(_ actor: UserContext, scope: String, key: String, at time: Int64) async throws -> Row? {
    try await actor.executeGraphSave(comment: "claim expired Blob upload") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        let row = try await read(sql, scope: scope, key: key)
        guard eligible(row, now: time), let row else { return nil }
        guard try await count(sql, "SELECT count(*) AS n FROM teaql_blob_binding WHERE key=?", key) == 0 else { return nil }
        guard try await count(sql, "SELECT count(*) AS n FROM teaql_blob_catalog WHERE object_key=?", row.objectKey) == 1 else {
          throw Self.fail("BLOB_CATALOG_FAILED")
        }
        if row.status == "initiated" {
          let changed = try await sql.execute("""
            UPDATE teaql_blob_catalog SET status='deleting'
            WHERE key=? AND scope=? AND status='initiated'
            """, parameters: [.string(key), .string(scope)])
          guard changed == 1 else { throw Self.fail("BLOB_CATALOG_FAILED") }
        }
        return row
      }
    }
  }

  private func capture(_ actor: UserContext, scope: String, claim: Row,
                       version: String, at time: Int64) async throws {
    guard Self.validText(version) else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
    try await actor.executeGraphSave(comment: "capture expired Blob version") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        guard let row = try await read(sql, scope: scope, key: claim.key), eligible(row, now: time),
          row.status == "deleting", row.objectKey == claim.objectKey,
          row.version.isEmpty || row.version == version,
          row.writtenETag.isEmpty || row.writtenETag == version,
          try await count(sql, "SELECT count(*) AS n FROM teaql_blob_binding WHERE key=?", claim.key) == 0 else {
          throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
        }
        if row.version.isEmpty {
          let changed = try await sql.execute("""
            UPDATE teaql_blob_catalog SET content_version=?
            WHERE key=? AND scope=? AND status='deleting' AND content_version=''
            """, parameters: [.string(version), .string(claim.key), .string(scope)])
          guard changed == 1 else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
        }
      }
    }
  }

  private func finish(_ actor: UserContext, scope: String, claim: Row,
                      version: String, at time: Int64) async throws {
    try await actor.executeGraphSave(comment: "finish expired Blob deletion") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        guard let row = try await read(sql, scope: scope, key: claim.key),
          row.objectKey == claim.objectKey, row.version == version else {
          throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
        }
        if row.status == "deleted" { return }
        guard eligible(row, now: time), row.status == "deleting",
          try await count(sql, "SELECT count(*) AS n FROM teaql_blob_binding WHERE key=?", claim.key) == 0 else {
          throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
        }
        let changed = try await sql.execute("""
          UPDATE teaql_blob_catalog SET status='deleted'
          WHERE key=? AND scope=? AND status='deleting' AND content_version=?
          """, parameters: [.string(claim.key), .string(scope), .string(version)])
        guard changed == 1 else { throw Self.fail("BLOB_CATALOG_FAILED") }
      }
    }
  }

  private func collect(_ actor: UserContext, scope: String, key: String,
                       storage: ObjectStorage) async throws -> BlobMaintenanceOutcome {
    let reference = try BlobRef(key)
    do {
      _ = try await authorize(actor, expected: scope)
      guard let row = try await claim(actor, scope: scope, key: key, at: millis()) else {
        return BlobMaintenanceOutcome(reference: reference, status: "not_eligible")
      }
      _ = try await authorize(actor, expected: scope)
      let objectKey = try ObjectKey(row.objectKey)
      let version: String
      if !row.version.isEmpty {
        version = row.version
        guard row.writtenETag.isEmpty || row.writtenETag == version else {
          throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
        }
      } else {
        let observed: ObjectMetadata?
        do { observed = try await storage.head(objectKey) }
        catch { throw Self.fail("BLOB_STORE_FAILED") }
        guard let observed else {
          _ = try await authorize(actor, expected: scope)
          try await finish(actor, scope: scope, claim: row, version: "", at: millis())
          return BlobMaintenanceOutcome(reference: reference, status: "already_missing")
        }
        guard let found = observed.etag, Self.validText(found),
          row.writtenETag.isEmpty || row.writtenETag == found else {
          throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT")
        }
        version = found
        _ = try await authorize(actor, expected: scope)
        try await capture(actor, scope: scope, claim: row, version: version, at: millis())
      }
      _ = try await authorize(actor, expected: scope)
      let deleted: ObjectConditionalDeleteResult
      do { deleted = try await storage.deleteIfVersion(objectKey, contentVersion: version) }
      catch { throw Self.fail("BLOB_STORE_FAILED") }
      guard deleted != .versionMismatch else { throw Self.fail("BLOB_IDEMPOTENCY_CONFLICT") }
      _ = try await authorize(actor, expected: scope)
      try await finish(actor, scope: scope, claim: row, version: version, at: millis())
      return BlobMaintenanceOutcome(reference: reference,
        status: deleted == .deleted ? "deleted" : "already_missing")
    } catch let error as TeaQLError {
      guard case .execution(let code) = error else {
        return BlobMaintenanceOutcome(reference: reference, status: "failed", error: "BLOB_STORE_FAILED")
      }
      if code == "BLOB_MAINTENANCE_DENIED" || code == "BLOB_TRANSACTION_REQUIRED" { throw error }
      if code == "BLOB_IDEMPOTENCY_CONFLICT" {
        return BlobMaintenanceOutcome(reference: reference, status: "version_conflict",
          error: "BLOB_IDEMPOTENCY_CONFLICT")
      }
      return BlobMaintenanceOutcome(reference: reference, status: "failed",
        error: ["BLOB_CATALOG_FAILED", "BLOB_CATALOG_ERROR"].contains(code)
          ? "BLOB_CATALOG_FAILED" : "BLOB_STORE_FAILED")
    } catch {
      return BlobMaintenanceOutcome(reference: reference, status: "failed", error: "BLOB_STORE_FAILED")
    }
  }

  public func runBatch(_ actor: UserContext,
                       cursor: BlobMaintenanceCursor? = nil) async throws -> BlobMaintenanceBatch {
    let scope = try await authorize(actor)
    guard cursor.map({ $0.scope == scope }) ?? true else { throw Self.fail("BLOB_MAINTENANCE_DENIED") }
    try actor.requireNoActiveGraphSQL()
    let storage: ObjectStorage
    do { storage = try actor.objectStorage("collect expired Blob upload") }
    catch { throw Self.fail("BLOB_CAPABILITY_MISSING") }
    guard storage.supportsVersionConditionalDelete else { throw Self.fail("BLOB_CAPABILITY_MISSING") }
    let time = try millis()
    let keys: [String] = try await actor.executeGraphSave(comment: "scan expired Blob uploads") { graph, session in
      try await catalog.validateSchema(graph, session: session)
      return try await graph.withPhysicalSQL(session) { sql in
        let rows = try await sql.query("""
          SELECT DISTINCT c.key FROM teaql_blob_catalog c JOIN teaql_blob_upload u
            ON u.key=c.key AND u.scope=c.scope
          WHERE c.scope=? AND c.key>? AND u.expires_ms<=?
            AND u.state IN ('initiated','written') AND c.status IN ('initiated','deleting')
            AND NOT EXISTS (SELECT 1 FROM teaql_blob_binding b WHERE b.key=c.key)
          ORDER BY c.key LIMIT ?
          """, parameters: [.string(scope), .string(cursor?.after ?? ""), .int(time), .int(Int64(batchSize))])
        return try rows.map { value in
          guard let key = value["key"]?.stringValue, (try? BlobRef(key)) != nil else {
            throw Self.fail("BLOB_CATALOG_FAILED")
          }
          return key
        }
      }
    }
    var outcomes: [BlobMaintenanceOutcome] = []
    for key in keys { outcomes.append(try await collect(actor, scope: scope, key: key, storage: storage)) }
    return BlobMaintenanceBatch(outcomes: outcomes,
      next: keys.count == batchSize ? BlobMaintenanceCursor(scope: scope, after: keys.last!) : nil)
  }
}
