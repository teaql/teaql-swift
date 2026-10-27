import Foundation
import XCTest
import SotoS3
import TeaQLBlobReference
import TeaQLCore
import TeaQLObjectStorageS3
import TeaQLSQLite

private struct S3UploadPermission: BlobUploadAuthorization {
  let allowed: Bool
  func scope(for actor: UserContext) throws -> String { "f4-s3-upload" }
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec {
    try BlobFieldSpec(entity: "Asset", field: "file", extensions: ["pdf"],
      nullable: true, policyProfile: "default")
  }
  func authorize(actor: UserContext, target: BlobUploadTarget, action: String,
                 input: BlobUploadInput) async throws -> Bool {
    allowed && target.entity == "Asset" && target.field == "file"
      && ["Begin", "Write", "Confirm"].contains(action)
  }
  func currentOnLease(actor: UserContext, target: BlobUploadTarget, action: String,
                      input: BlobUploadInput, lease: any GraphPhysicalSQLLease)
    async throws -> BlobUploadAuthorizationSnapshot {
    BlobUploadAuthorizationSnapshot(scope: try scope(for: actor),
      field: try field(for: actor, target: target),
      allowed: try await authorize(actor: actor, target: target, action: action, input: input))
  }
}

private actor S3VerifierCalls {
  var count = 0
  func record() { count += 1 }
}

// This test parser accepts one known complete fixture; production parsing is a separate gate.
private struct S3FixturePDFVerifier: BlobContentVerifier {
  let calls: S3VerifierCalls
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    await calls.record()
    var bytes = Data()
    while true {
      let chunk = try await reader.read(upToCount: 4096)
      if chunk.isEmpty { break }
      bytes.append(chunk)
      guard Int64(bytes.count) <= maximumBytes else { throw TeaQLError.execution("invalid fixture") }
    }
    let expected = Data("%PDF-1.7\nreal S3 Blob upload\n%%EOF".utf8)
    guard ext == "pdf", bytes == expected else { throw TeaQLError.execution("invalid fixture") }
    return BlobVerifiedContent(sizeBytes: Int64(bytes.count),
      sha256: "eb3fd1e63912b62ea2e468cdc8176776dd75ddf882468dc0a4e257c7719f66f5",
      contentType: "application/pdf")
  }
}

private func s3UploadCatalogValue(_ context: UserContext, sql: String,
                                  key: String) async throws -> String? {
  try await context.executeGraphSave(comment: "inspect S3 Blob upload") { graph, session in
    try await graph.withPhysicalSQL(session) { lease in
      let rows = try await lease.query(sql, parameters: [.string(key)])
      return rows.first?.values.first?.stringValue
    }
  }
}

@MainActor
final class BlobUploadS3Tests: XCTestCase {
  func testRealSQLiteBlobUploadThroughS3() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["TEAQL_S3_TEST_BLOB_UPLOAD"] == "1" else {
      throw XCTSkip("explicit S3-compatible Blob upload gate required")
    }
    guard let endpoint = env["TEAQL_S3_TEST_ENDPOINT"], let bucket = env["TEAQL_S3_TEST_BUCKET"],
      let access = env["TEAQL_S3_TEST_ACCESS_KEY"], let secret = env["TEAQL_S3_TEST_SECRET_KEY"] else {
      XCTFail("explicit S3 test configuration required")
      return
    }
    let client = AWSClient(credentialProvider: .static(accessKeyId: access, secretAccessKey: secret),
      retryPolicy: .noRetry)
    let service = S3(client: client, region: .useast1, endpoint: endpoint,
      options: [.s3Disable100Continue])
    let provider = try S3ObjectStorage(service: service, bucket: bucket)
    let database = try SQLiteDataService(path: ":memory:")
    let context = UserContext(queryExecutor: database, mutationExecutor: database,
      requestPolicy: RequestPolicy { $0 }).withObjectStorage(provider)
      .withObjectStorageObserver { _ in }
    let storage = try context.objectStorage("verify S3 Blob upload")
    var objectKey: ObjectKey?
    do {
      let catalog = SQLiteBlobCatalog()
      try await context.executeGraphSave(comment: "install S3 Blob schema") { graph, session in
        try await catalog.installSchema(graph, session: session)
      }
      let calls = S3VerifierCalls()
      let upload = try SQLiteBlobUploadService(
        authorization: S3UploadPermission(allowed: true),
        verifier: S3FixturePDFVerifier(calls: calls), maximumBytes: 10_000)
      let data = Data("%PDF-1.7\nreal S3 Blob upload\n%%EOF".utf8)
      let session = try await upload.begin(context,
        target: BlobUploadTarget(entity: "Asset", entityID: "1", field: "file"),
        input: BlobUploadInput(fileName: "report.pdf", declaredSize: Int64(data.count),
          declaredContentType: "application/pdf"), replayKey: UUID().uuidString)
      let raw = try await s3UploadCatalogValue(context,
        sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key)
      objectKey = try ObjectKey(try XCTUnwrap(raw))
      let written = try await upload.write(context, uploadID: session.uploadID,
        source: ObjectDataReader(data))
      XCTAssertEqual(written, Int64(data.count))
      let revoked = try SQLiteBlobUploadService(
        authorization: S3UploadPermission(allowed: false),
        verifier: S3FixturePDFVerifier(calls: calls), maximumBytes: 10_000)
      do { _ = try await revoked.complete(context, uploadID: session.uploadID)
        XCTFail("revoked S3 Blob confirmation accepted") }
      catch let error as TeaQLError { XCTAssertEqual(error, .execution("BLOB_UPLOAD_DENIED")) }
      let reference = try await upload.complete(context, uploadID: session.uploadID)
      XCTAssertEqual(reference, session.reference)
      let replay = try await upload.complete(context, uploadID: session.uploadID)
      XCTAssertEqual(replay, reference)
      let verifierCount = await calls.count
      XCTAssertEqual(verifierCount, 1)
      let replayedLength = try await upload.write(context, uploadID: session.uploadID,
        source: ObjectDataReader(data))
      XCTAssertEqual(replayedLength, Int64(data.count))
      let stored = try await storage.getBytes(try XCTUnwrap(objectKey), maximumBytes: 10_000)
      XCTAssertEqual(stored, data)
      let head = try await storage.head(try XCTUnwrap(objectKey))
      let status = try await s3UploadCatalogValue(context,
        sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key)
      let version = try await s3UploadCatalogValue(context,
        sql: "SELECT content_version FROM teaql_blob_catalog WHERE key = ?", key: reference.key)
      XCTAssertEqual(status, "uploaded_unbound")
      XCTAssertEqual(version, head?.etag)
    } catch {
      if let objectKey { try? await storage.delete(objectKey) }
      try? await client.shutdown()
      throw error
    }
    if let objectKey { try await storage.delete(objectKey) }
    try await client.shutdown()
  }
}
