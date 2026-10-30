import Foundation
import TeaQLCore

public struct BlobFileGenerationSweepCursor: Sendable, CustomStringConvertible {
  let owner: UUID
  let scope: String
  let after: String
  init(owner: UUID, scope: String, after: String) {
    self.owner = owner; self.scope = scope; self.after = after
  }
  public var description: String { "BlobFileGenerationSweepCursor[masked]" }
}

public struct BlobFileGenerationSweepOutcome: Sendable {
  public let reference: BlobRef
  public let status: String
  public let removedGenerations: Int
  public let error: String?
}

public struct BlobFileGenerationSweepBatch: Sendable {
  public let outcomes: [BlobFileGenerationSweepOutcome]
  public let next: BlobFileGenerationSweepCursor?
}

/// Host-scheduled cleanup of inaccessible immutable File generations.
public struct SQLiteBlobFileGenerationSweepService: Sendable {
  private let catalog: SQLiteBlobCatalog
  private let authorization: any BlobMaintenanceAuthorization
  private let batchSize: Int
  private let identity = UUID()

  private static func fail(_ code: String) -> TeaQLError { .execution(code) }
  private static func validScope(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 256
      && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  public init(catalog: SQLiteBlobCatalog = SQLiteBlobCatalog(),
              authorization: any BlobMaintenanceAuthorization,
              allWritersUpgraded: Bool, batchSize: Int = 100) throws {
    guard allWritersUpgraded, (1...1000).contains(batchSize) else {
      throw Self.fail("BLOB_POLICY_INVALID")
    }
    self.catalog = catalog; self.authorization = authorization; self.batchSize = batchSize
  }

  private func authorize(_ actor: UserContext, expected: String? = nil) async throws -> String {
    let scope: String
    let allowed: Bool
    do {
      scope = try authorization.scope(for: actor)
      allowed = try await authorization.canMaintain(actor: actor, scope: scope)
    } catch { throw Self.fail("BLOB_MAINTENANCE_DENIED") }
    guard Self.validScope(scope), expected.map({ $0 == scope }) ?? true, allowed else {
      throw Self.fail("BLOB_MAINTENANCE_DENIED")
    }
    return scope
  }

  public func runBatch(_ actor: UserContext, provider: FileObjectStorage,
                       cursor: BlobFileGenerationSweepCursor? = nil) async throws
    -> BlobFileGenerationSweepBatch {
    let scope = try await authorize(actor)
    guard cursor.map({ $0.owner == identity && $0.scope == scope }) ?? true else {
      throw Self.fail("BLOB_MAINTENANCE_DENIED")
    }
    try actor.requireNoActiveGraphSQL()
    guard actor.usesObjectStorageProvider(provider) else { throw Self.fail("BLOB_CAPABILITY_MISSING") }
    let candidates: [(BlobRef, ObjectKey)] = try await actor.executeGraphSave(
      comment: "scan Blob File generations") { graph, session in
      try await catalog.validateSchema(graph, session: session)
      return try await graph.withPhysicalSQL(session) { sql in
        let rows: [TeaQLRecord]
        do {
          rows = try await sql.query("""
            SELECT key,object_key FROM teaql_blob_catalog
            WHERE scope=? AND key>? AND upload_mode='server_stream'
            ORDER BY key LIMIT ?
            """, parameters: [.string(scope), .string(cursor?.after ?? ""),
              .int(Int64(batchSize))])
        } catch { throw Self.fail("BLOB_CATALOG_FAILED") }
        return try rows.map { row in
          guard let key = row["key"]?.stringValue,
            let object = row["object_key"]?.stringValue,
            let reference = try? BlobRef(key),
            let objectKey = try? ObjectKey(object) else {
            throw Self.fail("BLOB_CATALOG_FAILED")
          }
          return (reference, objectKey)
        }
      }
    }
    var outcomes: [BlobFileGenerationSweepOutcome] = []
    for (reference, key) in candidates {
      _ = try await authorize(actor, expected: scope)
      do {
        let removed = try await provider.sweepOldGenerations(key)
        guard removed >= 0 else { throw Self.fail("BLOB_STORE_FAILED") }
        outcomes.append(BlobFileGenerationSweepOutcome(reference: reference, status: "swept",
          removedGenerations: removed, error: nil))
      } catch {
        outcomes.append(BlobFileGenerationSweepOutcome(reference: reference, status: "failed",
          removedGenerations: 0, error: "BLOB_STORE_FAILED"))
      }
    }
    return BlobFileGenerationSweepBatch(outcomes: outcomes,
      next: candidates.count == batchSize
        ? BlobFileGenerationSweepCursor(owner: identity, scope: scope,
            after: candidates.last!.0.key) : nil)
  }
}
