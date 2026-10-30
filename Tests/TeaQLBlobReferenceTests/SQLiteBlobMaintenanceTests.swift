import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct MaintenancePermission: BlobMaintenanceAuthorization {
  let allowed: Bool
  var onMaintain: (@Sendable () async throws -> Void)? = nil
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool {
    try await onMaintain?()
    return allowed
  }
}

private actor MaintenanceClaimRace {
  let context: UserContext
  var calls = 0
  init(_ context: UserContext) { self.context = context }
  func advance() async throws {
    calls += 1
    guard calls == 2 else { return }
    try await context.executeGraphSave(comment: "bind after retention scan") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_binding(scope,entity,entity_id,field,key,version)
          VALUES('tenant-a','Asset','9','file','blob_completed_race',1)
          """, parameters: [])
      }
    }
  }
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
func swiftSQLiteExpiredDirectUploadsRemainUntouchedWithoutQuiescence() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-direct-maintenance-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let db = try SQLiteDataService(path: parent.appendingPathComponent("catalog.sqlite").path)
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? file.close() }
  let context = UserContext(queryExecutor: db, mutationExecutor: db,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(file)
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install direct maintenance schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let store = try context.objectStorage("seed direct uploads")
  let bytes = Data("%PDF-".utf8)
  for (name, state, status) in [
    ("blob_direct_initiated", "initiated", "initiated"),
    ("blob_direct_written", "written", "initiated"),
    ("blob_direct_deleting", "initiated", "deleting")
  ] {
    let key = try ObjectKey("objects/" + name)
    _ = try await store.putBytes(key, data: bytes,
      options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
    try await addMaintenanceUpload(context, key: name, scope: "tenant-a", objectKey: key.value)
    try await context.executeGraphSave(comment: "mark direct upload catalog") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("UPDATE teaql_blob_catalog SET upload_mode='direct',status=? WHERE key=?",
          parameters: [.string(status), .string(name)])
        _ = try await sql.execute("UPDATE teaql_blob_upload SET state=? WHERE key=?",
          parameters: [.string(state), .string(name)])
      }
    }
  }
  let maintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: MaintenancePermission(allowed: true), batchSize: 10,
    now: { Date(timeIntervalSince1970: 2_000) })
  let batch = try await maintenance.runBatch(context)
  #expect(batch.outcomes.isEmpty)
  for name in ["blob_direct_initiated", "blob_direct_written", "blob_direct_deleting"] {
    #expect(try await maintenanceRow(context, key: name).0 != "deleted")
    #expect(try await store.head(ObjectKey("objects/" + name)) != nil)
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

@Test
func swiftSQLiteCompletedRetentionUsesRealFileVersionAndReceiptRecovery() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-completed-retention-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: parent) }
  let database = try SQLiteDataService(path: parent.appendingPathComponent("catalog.sqlite").path)
  let file = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? file.close() }
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(file)
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install completed retention schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
  }
  let maintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: MaintenancePermission(allowed: true), batchSize: 100,
    now: { Date(timeIntervalSince1970: 10) })
  let store = try context.objectStorage("seed completed Blob")
  let bytes = Data("%PDF-1.7\nretained\n%%EOF".utf8)

  func seed(_ name: String, status: String = "uploaded_unbound", last: Int64? = nil,
    floor: Int64? = nil, profile: String? = "default", mode: String = "server_stream",
    bound: Bool = false) async throws -> (ObjectKey, String) {
    let key = try ObjectKey("objects/" + name)
    let metadata = try await store.putBytes(key, data: bytes,
      options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
    let version = try #require(metadata.etag)
    try await context.executeGraphSave(comment: "seed completed retention row") { graph, session in
      try await graph.withPhysicalSQL(session) { sql in
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_catalog
          (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
           completed_at_ms,last_unbound_at_ms,policy_profile,upload_mode,
           unbound_retention_seconds,effective_unref_seconds,retention_floor_until_ms)
          VALUES (?,'tenant-a',?,?,'file.pdf','application/pdf',?,?,?,?,?, ?,1,2,?)
          """, parameters: [.string(name), .string(key.value), .string(version),
            .int(Int64(bytes.count)), .string(status), .int(9000),
            last.map { .int($0) } ?? .null, profile.map { .string($0) } ?? .null,
            .string(mode), floor.map { .int($0) } ?? .null])
        _ = try await sql.execute("""
          INSERT INTO teaql_blob_upload
          (upload_id,scope,replay_key,request_hash,key,entity,entity_id,field,file_name,
           extension,declared_size,expires_ms,state,written_etag)
          VALUES (?,'tenant-a',?, 'hash',?,'Asset','1','file','file.pdf','pdf',?,9000,
            'completed',?)
          """, parameters: [.string("bu_" + name), .string("replay_" + name),
            .string(name), .int(Int64(bytes.count)), .string(version)])
        if bound {
          _ = try await sql.execute("""
            INSERT INTO teaql_blob_binding(scope,entity,entity_id,field,key,version)
            VALUES('tenant-a','Asset',?,'file',?,1)
            """, parameters: [.string(name), .string(name)])
        }
      }
    }
    return (key, version)
  }

  let (expired, _) = try await seed("blob_completed_expired")
  let (former, _) = try await seed("blob_completed_former", status: "available",
    last: 7000, floor: 10000)
  let (active, _) = try await seed("blob_completed_active", status: "available", bound: true)
  let (floored, _) = try await seed("blob_completed_floor", status: "available",
    last: 7000, floor: 20000)
  let (legacy, _) = try await seed("blob_completed_legacy", profile: nil)
  let (direct, _) = try await seed("blob_completed_direct", mode: "direct")
  let first = try await maintenance.runBatch(context)
  #expect(first.outcomes.map(\.reference.key) == ["blob_completed_expired", "blob_completed_former"])
  #expect(first.outcomes.allSatisfy { $0.status == "deleted" })
  #expect(try await store.head(expired) == nil)
  #expect(try await store.head(former) == nil)
  for key in [active, floored, legacy, direct] { #expect(try await store.head(key) != nil) }

  let (staleKey, oldVersion) = try await seed("blob_completed_stale")
  let newer = try await store.putBytes(staleKey, data: bytes,
    options: ObjectPutOptions(size: Int64(bytes.count), mode: .replace))
  #expect(newer.etag != oldVersion)
  let stale = try await maintenance.runBatch(context)
  #expect(stale.outcomes.map(\.status) == ["version_conflict"])
  #expect(try await store.head(staleKey)?.etag == newer.etag)

  let (retryKey, _) = try await seed("blob_completed_retry")
  try await context.executeGraphSave(comment: "fail completed retention receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("""
        CREATE TRIGGER fail_completed_receipt BEFORE UPDATE OF status ON teaql_blob_catalog
          WHEN NEW.status='deleted' AND OLD.key='blob_completed_retry'
          BEGIN SELECT RAISE(ABORT,'receipt failure'); END
        """, parameters: [])
    }
  }
  let failed = try await maintenance.runBatch(context)
  #expect(failed.outcomes.contains { $0.reference.key == "blob_completed_retry" && $0.status == "failed" })
  #expect(try await maintenanceRow(context, key: "blob_completed_retry").0 == "deleting")
  #expect(try await store.head(retryKey) == nil)
  try await context.executeGraphSave(comment: "repair completed retention receipt") { graph, session in
    try await graph.withPhysicalSQL(session) { sql in
      _ = try await sql.execute("DROP TRIGGER fail_completed_receipt", parameters: [])
    }
  }
  let retried = try await maintenance.runBatch(context)
  #expect(retried.outcomes.contains {
    $0.reference.key == "blob_completed_retry" && $0.status == "already_missing"
  })
  #expect(try await maintenanceRow(context, key: "blob_completed_retry").0 == "deleted")

  let (racedKey, _) = try await seed("blob_completed_race")
  let race = MaintenanceClaimRace(context)
  let raceMaintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
    authorization: MaintenancePermission(allowed: true, onMaintain: { try await race.advance() }),
    batchSize: 100, now: { Date(timeIntervalSince1970: 10) })
  let raced = try await raceMaintenance.runBatch(context)
  #expect(raced.outcomes.contains {
    $0.reference.key == "blob_completed_race" && $0.status == "not_eligible"
  })
  #expect(try await maintenanceRow(context, key: "blob_completed_race").0 == "uploaded_unbound")
  #expect(try await store.head(racedKey) != nil)
}
