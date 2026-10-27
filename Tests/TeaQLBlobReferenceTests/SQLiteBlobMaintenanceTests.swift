import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct MaintenancePermission: BlobMaintenanceAuthorization {
  let allowed: Bool
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool { allowed }
}

private func maintenanceRow(_ actor: UserContext, key: String) async throws -> (String, String) {
  try await actor.executeGraphSave(comment: "inspect maintenance row") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      let rows = try await sql.query("SELECT status,content_version FROM teaql_blob_catalog WHERE key=?",
        parameters: [.string(key)])
      return (rows[0]["status"]!.stringValue!, rows[0]["content_version"]!.stringValue!)
    }
  }
}

private func addMaintenanceUpload(_ actor: UserContext, key: String, scope: String,
                                  objectKey: String, version: String = "") async throws {
  try await actor.executeGraphSave(comment: "seed expired upload") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_catalog
        (key,scope,object_key,content_version,file_name,content_type,size_bytes,status)
        VALUES (?,?,?,?,?,?,?,?)
        """, parameters: [.string(key), .string(scope), .string(objectKey), .string(version),
          .string("test.pdf"), .string("application/pdf"), .int(5), .string("initiated")])
      _ = try await sql.execute("""
        INSERT INTO teaql_blob_upload
        (upload_id,scope,replay_key,request_hash,key,entity,entity_id,field,file_name,
         extension,declared_size,expires_ms,state)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, parameters: [.string("bu_" + key), .string(scope), .string(key),
          .string("hash"), .string(key), .string("Asset"), .string("1"), .string("file"),
          .string("test.pdf"), .string("pdf"), .int(5), .int(1_000_000), .string("initiated")])
    }
  }
}

@Test
func swiftSQLiteExpiredUploadMaintenanceDeletesFileAndRecoversFailedReceipt() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-maintenance-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let db = try SQLiteDataService(path: parent.appendingPathComponent("catalog.sqlite").path)
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  let context = UserContext(queryExecutor: db, mutationExecutor: db,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(file)
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install maintenance schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let maintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: MaintenancePermission(allowed: true), batchSize: 2,
    now: { Date(timeIntervalSince1970: 2_000) })
  let store = try context.objectStorage("seed file")
  let bytes = Data("%PDF-".utf8)
  let key = try ObjectKey("blob/expired-one")
  _ = try await store.putBytes(key, data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
  try await addMaintenanceUpload(context, key: "blob_expired_one", scope: "tenant-a",
    objectKey: key.value)
  try await addMaintenanceUpload(context, key: "blob_other_scope", scope: "tenant-b",
    objectKey: "blob/other-scope")

  try await context.executeGraphSave(comment: "fail first deletion receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER fail_maintenance_receipt BEFORE UPDATE OF status ON teaql_blob_catalog
        WHEN NEW.status='deleted' BEGIN SELECT RAISE(ABORT,'receipt-failure'); END
        """, parameters: [])
    }
  }
  let first = try await maintenance.runBatch(context)
  #expect(first.outcomes.count == 1)
  #expect(first.outcomes[0].status == "failed")
  let (claimedStatus, claimedVersion) = try await maintenanceRow(context, key: "blob_expired_one")
  #expect(claimedStatus == "deleting")
  #expect(!claimedVersion.isEmpty)
  #expect(try await store.head(key)?.size == nil)
  try await context.executeGraphSave(comment: "repair deletion receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("DROP TRIGGER fail_maintenance_receipt", parameters: [])
    }
  }
  let retry = try await maintenance.runBatch(context)
  #expect(retry.outcomes.map(\.status) == ["already_missing"])
  #expect(try await maintenanceRow(context, key: "blob_expired_one").0 == "deleted")
  #expect(try await maintenanceRow(context, key: "blob_other_scope").0 == "initiated")

  let staleKey = try ObjectKey("blob/stale-version")
  let old = try await store.putBytes(staleKey, data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
  try await addMaintenanceUpload(context, key: "blob_stale_version", scope: "tenant-a",
    objectKey: staleKey.value, version: old.etag!)
  let newer = try await store.putBytes(staleKey, data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .replace))
  #expect(newer.etag != old.etag)
  let stale = try await maintenance.runBatch(context)
  #expect(stale.outcomes.map(\.status) == ["version_conflict"])
  #expect(try await store.head(staleKey)?.etag == newer.etag)

  let denied = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: MaintenancePermission(allowed: false))
  do { _ = try await denied.runBatch(context); Issue.record("maintenance permission bypassed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_MAINTENANCE_DENIED")) }
  do {
    _ = try await context.executeGraphSave(comment: "reject nested maintenance") { graph, _ in
      try await maintenance.runBatch(graph)
    }
    Issue.record("nested maintenance accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_TRANSACTION_REQUIRED")) }
}
