import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct FileSweepPermission: BlobMaintenanceAuthorization {
  let currentScope: String
  let allowed: Bool
  func scope(for actor: UserContext) throws -> String { currentScope }
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool { allowed }
}

@Test
func swiftSQLiteFileGenerationSweepCatalogScopeAndCurrentData() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-catalog-sweep-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let db = try SQLiteDataService(path: parent.appendingPathComponent("catalog.sqlite").path)
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  let context = UserContext(queryExecutor: db, mutationExecutor: db,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(file)
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install File sweep catalog") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let permission = FileSweepPermission(currentScope: "tenant-a", allowed: true)
  do {
    _ = try SQLiteBlobFileGenerationSweepService(catalog: catalog,
      authorization: permission, allWritersUpgraded: false)
    Issue.record("missing writer upgrade assertion accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_POLICY_INVALID")) }
  let service = try SQLiteBlobFileGenerationSweepService(catalog: catalog,
    authorization: permission, allWritersUpgraded: true, batchSize: 1)
  let store = try context.objectStorage("seed File generations")
  let bytes = Data("same bytes".utf8)
  var current: [String: String] = [:]
  for (name, scope, status, mode) in [
    ("blob_a_deleted", "tenant-a", "deleted", "server_stream"),
    ("blob_b_active", "tenant-a", "available", "server_stream"),
    ("blob_c_direct", "tenant-a", "available", "direct"),
    ("blob_d_other", "tenant-b", "available", "server_stream")
  ] {
    let key = try ObjectKey("objects/\(name)")
    _ = try await store.putBytes(key, data: bytes,
      options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
    let latest = try await store.putBytes(key, data: bytes,
      options: ObjectPutOptions(size: Int64(bytes.count), mode: .replace))
    current[name] = latest.etag
    try await context.executeGraphSave(comment: "seed trusted File catalog") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_catalog
          (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,upload_mode)
          VALUES (?,?,?,?,?,?,?,?,?)
          """, parameters: [.string(name), .string(scope), .string(key.value),
            .string(latest.etag!), .string("file.pdf"), .string("application/pdf"),
            .int(Int64(bytes.count)), .string(status), .string(mode)])
      }
    }
  }
  let denied = try SQLiteBlobFileGenerationSweepService(catalog: catalog,
    authorization: FileSweepPermission(currentScope: "tenant-a", allowed: false),
    allWritersUpgraded: true)
  do { _ = try await denied.runBatch(context, provider: file); Issue.record("revoked sweep accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_MAINTENANCE_DENIED")) }
  let first = try await service.runBatch(context, provider: file)
  #expect(first.outcomes.map(\.reference.key) == ["blob_a_deleted"])
  #expect(first.outcomes.map(\.removedGenerations) == [1])
  let second = try await service.runBatch(context, provider: file, cursor: first.next)
  #expect(second.outcomes.map(\.reference.key) == ["blob_b_active"])
  #expect(second.outcomes.map(\.removedGenerations) == [1])
  #expect(try await store.head(ObjectKey("objects/blob_b_active"))?.etag == current["blob_b_active"])
  let final = try await service.runBatch(context, provider: file, cursor: second.next)
  #expect(final.outcomes.isEmpty)
  #expect(try await file.sweepOldGenerations(ObjectKey("objects/blob_a_deleted")) == 0)
  #expect(try await file.sweepOldGenerations(ObjectKey("objects/blob_c_direct")) == 1)
  #expect(try await file.sweepOldGenerations(ObjectKey("objects/blob_d_other")) == 1)
  let wrong = try FileObjectStorage(root: parent.appendingPathComponent("wrong").path,
    signingKey: Data(repeating: 0x42, count: 32))
  do { _ = try await service.runBatch(context, provider: wrong); Issue.record("wrong provider accepted") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_CAPABILITY_MISSING")) }
  let otherScope = try SQLiteBlobFileGenerationSweepService(catalog: catalog,
    authorization: FileSweepPermission(currentScope: "tenant-b", allowed: true),
    allWritersUpgraded: true)
  do {
    _ = try await otherScope.runBatch(context, provider: file, cursor: first.next)
    Issue.record("foreign cursor accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_MAINTENANCE_DENIED")) }
  do {
    _ = try await context.executeGraphSave(comment: "reject nested File sweep") { graph, _ in
      try await service.runBatch(graph, provider: file)
    }
    Issue.record("nested File sweep accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_TRANSACTION_REQUIRED")) }
}
