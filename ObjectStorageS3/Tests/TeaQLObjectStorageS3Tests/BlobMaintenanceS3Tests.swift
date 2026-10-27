import Foundation
import XCTest
import SotoS3
import TeaQLBlobReference
import TeaQLCore
import TeaQLObjectStorageS3
import TeaQLSQLite

private struct S3MaintenancePermission: BlobMaintenanceAuthorization {
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func canMaintain(actor: UserContext, scope: String) async throws -> Bool { scope == "tenant-a" }
}

@MainActor
final class BlobMaintenanceS3Tests: XCTestCase {
  func testRealS3CompletedBlobRetention() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["TEAQL_S3_TEST_BLOB_MAINTENANCE"] == "1" else {
      throw XCTSkip("explicit disposable S3 maintenance gate required")
    }
    guard let endpoint = env["TEAQL_S3_TEST_ENDPOINT"], let bucket = env["TEAQL_S3_TEST_BUCKET"],
      let access = env["TEAQL_S3_TEST_ACCESS_KEY"], let secret = env["TEAQL_S3_TEST_SECRET_KEY"] else {
      XCTFail("disposable S3 endpoint, bucket, and credentials required")
      return
    }
    let client = AWSClient(credentialProvider: .static(accessKeyId: access, secretAccessKey: secret),
      retryPolicy: .noRetry)
    let service = S3(client: client, region: .useast1, endpoint: endpoint,
      options: [.s3Disable100Continue])
    let provider = try S3ObjectStorage(service: service, bucket: bucket)
    let parent = FileManager.default.temporaryDirectory
      .appendingPathComponent("teaql-swift-s3-completed-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let database = try SQLiteDataService(path: parent.appendingPathComponent("catalog.sqlite").path)
    let context = UserContext(queryExecutor: database, mutationExecutor: database,
      requestPolicy: RequestPolicy { $0 }).withObjectStorage(provider)
      .withObjectStorageObserver { _ in }
    let store = try context.objectStorage("real S3 completed Blob retention")
    let catalog = SQLiteBlobCatalog()
    let maintenance = try SQLiteBlobMaintenanceService(catalog: catalog,
      authorization: S3MaintenancePermission(), batchSize: 10,
      now: { Date(timeIntervalSince1970: 10) })
    let prefix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var keys: [ObjectKey] = []

    func seed(_ suffix: String, status: String = "uploaded_unbound", last: Int64? = nil,
      floor: Int64? = nil, profile: String? = "default", mode: String = "server_stream",
      bound: Bool = false) async throws -> (String, ObjectKey) {
      let reference = "blob_\(prefix)_\(suffix)"
      let key = try ObjectKey("f4/swift/completed-retention/\(prefix)/\(suffix)")
      keys.append(key)
      let bytes = Data("%PDF-1.7\n\(suffix)\n%%EOF".utf8)
      let created = try await store.putBytes(key, data: bytes,
        options: ObjectPutOptions(size: Int64(bytes.count), mode: .createOnly))
      let version = try XCTUnwrap(created.etag)
      try await context.executeGraphSave(comment: "seed S3 completed retention") { graph, session in
        try await graph.withPhysicalSQL(session) { sql in
          _ = try await sql.execute("""
            INSERT INTO teaql_blob_catalog
            (key,scope,object_key,content_version,file_name,content_type,size_bytes,status,
             completed_at_ms,last_unbound_at_ms,policy_profile,upload_mode,
             unbound_retention_seconds,effective_unref_seconds,retention_floor_until_ms)
            VALUES (?,'tenant-a',?,?,'file.pdf','application/pdf',?,?,?,?,?, ?,1,2,?)
            """, parameters: [.string(reference), .string(key.value), .string(version),
              .int(Int64(bytes.count)), .string(status), .int(9000),
              last.map { .int($0) } ?? .null, profile.map { .string($0) } ?? .null,
              .string(mode), floor.map { .int($0) } ?? .null])
          _ = try await sql.execute("""
            INSERT INTO teaql_blob_upload
            (upload_id,scope,replay_key,request_hash,key,entity,entity_id,field,file_name,
             extension,declared_size,expires_ms,state,written_etag)
            VALUES (?,'tenant-a',?, 'hash',?,'Asset','1','file','file.pdf','pdf',?,9000,
              'completed',?)
            """, parameters: [.string("bu_" + reference), .string("replay_" + reference),
              .string(reference), .int(Int64(bytes.count)), .string(version)])
          if bound {
            _ = try await sql.execute("""
              INSERT INTO teaql_blob_binding(scope,entity,entity_id,field,key,version)
              VALUES('tenant-a','Asset',?,'file',?,1)
              """, parameters: [.string(reference), .string(reference)])
          }
        }
      }
      return (reference, key)
    }

    func rowStatus(_ reference: String) async throws -> String? {
      try await context.executeGraphSave(comment: "inspect S3 retention receipt") { graph, session in
        try await graph.withPhysicalSQL(session) { sql in
          let rows = try await sql.query("SELECT status FROM teaql_blob_catalog WHERE key=?",
            parameters: [.string(reference)])
          return rows.first?["status"]?.stringValue
        }
      }
    }

    do {
      try await context.executeGraphSave(comment: "install S3 retention schema") { graph, session in
        try await catalog.installSchema(graph, session: session)
      }
      let expired = try await seed("expired")
      let former = try await seed("former", status: "available", last: 7000, floor: 10000)
      let active = try await seed("active", status: "available", bound: true)
      let floored = try await seed("floored", status: "available", last: 7000, floor: 20000)
      let legacy = try await seed("legacy", profile: nil)
      let direct = try await seed("direct", mode: "direct")
      let batch = try await maintenance.runBatch(context)
      XCTAssertEqual(batch.outcomes.filter { $0.status == "deleted" }.map(\.reference.key),
        [expired.0, former.0])
      XCTAssertTrue(batch.outcomes.allSatisfy { ["deleted", "not_eligible"].contains($0.status) })
      for item in [expired, former] {
        let head = try await store.head(item.1)
        XCTAssertNil(head)
        let status = try await rowStatus(item.0)
        XCTAssertEqual(status, "deleted")
      }
      for item in [active, floored, legacy, direct] {
        let head = try await store.head(item.1)
        XCTAssertNotNil(head)
        let status = try await rowStatus(item.0)
        XCTAssertNotEqual(status, "deleted")
      }
    } catch {
      for key in keys { try? await store.delete(key) }
      try? await client.shutdown()
      throw error
    }
    for key in keys { try? await store.delete(key) }
    try await client.shutdown()
  }
}
