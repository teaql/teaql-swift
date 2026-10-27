import Foundation
import FoundationNetworking
import XCTest
import SotoS3
import TeaQLBlobReference
import TeaQLCore
import TeaQLObjectStorageS3
import TeaQLSQLite

private struct S3UploadPermission: BlobUploadAuthorization {
  let allowed: Bool
  let fileExtension: String
  func scope(for actor: UserContext) throws -> String { "f4-s3-upload" }
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec {
    try BlobFieldSpec(entity: "Asset", field: "file", extensions: [fileExtension],
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

private struct S3CountingVerifier: BlobContentVerifier {
  let base: any BlobContentVerifier
  let calls: S3VerifierCalls
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    await calls.record()
    return try await base.verify(reader: reader, extension: ext, maximumBytes: maximumBytes)
  }
}

private struct S3BindingPermission: BlobBindingAuthorization {
  func scope(for actor: UserContext) throws -> String { "f4-s3-upload" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    target.entity == "Asset" && target.entityID == "1" && target.field == "file"
      && previous == nil && next != nil && action == "Create"
  }
}

private struct S3ReadPermission: BlobReadAuthorization {
  let allowed: Bool
  func authorize(actor: UserContext, slot: AuthorizedBlobSlot) async throws -> Bool { allowed }
}

private struct S3ViewAuthorizer: ResponseGraphAuthorizer {
  let reference: BlobRef
  let version: Int64
  func authorize(context: UserContext, result: any Sendable, options: ViewOptions)
    async throws -> AuthorizedResponseGraph {
    AuthorizedResponseGraph(presentation: .object(["document": .blob(reference)]),
      blobSlots: [AuthorizedBlobSlot(path: [.field("document")], entity: "Asset",
        entityID: "1", field: "file", scope: "f4-s3-upload",
        bindingVersion: version, reference: reference)])
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
    try await runBlobUpload(realImage: false)
  }

  func testRealJPEGBlobUploadThroughS3() async throws {
    guard ProcessInfo.processInfo.environment["TEAQL_S3_TEST_REAL_IMAGE"] == "1" else {
      throw XCTSkip("explicit real-image S3 gate required")
    }
    try await runBlobUpload(realImage: true)
  }

  private func runBlobUpload(realImage: Bool) async throws {
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
    let asset = EntityDescriptor(name: "Asset", table: "asset", properties: [
      PropertyDescriptor(name: "id", type: .int, isID: true),
      PropertyDescriptor(name: "version", type: .int, isVersion: true),
      PropertyDescriptor(name: "name", type: .string),
    ])
    let context = UserContext(queryExecutor: database, mutationExecutor: database,
      requestPolicy: RequestPolicy { $0 }).withObjectStorage(provider)
      .withObjectStorageObserver { _ in }
    let storage = try context.objectStorage("verify S3 Blob upload")
    var objectKey: ObjectKey?
    do {
      try await context.ensureSchema(RuntimeModule(name: "s3-upload-test", entities: [asset]))
      let catalog = SQLiteBlobCatalog()
      try await context.executeGraphSave(comment: "install S3 Blob schema") { graph, session in
        try await catalog.installSchema(graph, session: session)
      }
      let calls = S3VerifierCalls()
      let decoder: any BlobContentVerifier
      if realImage { decoder = try StbImageBlobContentVerifier() }
      else { decoder = S3FixturePDFVerifier(calls: S3VerifierCalls()) }
      let upload = try SQLiteBlobUploadService(
        authorization: S3UploadPermission(allowed: true,
          fileExtension: realImage ? "jpg" : "pdf"),
        verifier: S3CountingVerifier(base: decoder, calls: calls), maximumBytes: 10_000)
      let data: Data
      if realImage {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sample", withExtension: "jpg",
          subdirectory: "fixtures"))
        data = try Data(contentsOf: url)
      } else {
        data = Data("%PDF-1.7\nreal S3 Blob upload\n%%EOF".utf8)
      }
      let filename = realImage ? "sample.jpg" : "report.pdf"
      let contentType = realImage ? "image/jpeg" : "application/pdf"
      let session = try await upload.begin(context,
        target: BlobUploadTarget(entity: "Asset", entityID: "1", field: "file"),
        input: BlobUploadInput(fileName: filename, declaredSize: Int64(data.count),
          declaredContentType: contentType), replayKey: UUID().uuidString)
      let raw = try await s3UploadCatalogValue(context,
        sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key)
      objectKey = try ObjectKey(try XCTUnwrap(raw))
      let written = try await upload.write(context, uploadID: session.uploadID,
        source: ObjectDataReader(data))
      XCTAssertEqual(written, Int64(data.count))
      let revoked = try SQLiteBlobUploadService(
        authorization: S3UploadPermission(allowed: false,
          fileExtension: realImage ? "jpg" : "pdf"),
        verifier: S3CountingVerifier(base: decoder, calls: calls), maximumBytes: 10_000)
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
      let catalogContentType = try await s3UploadCatalogValue(context,
        sql: "SELECT content_type FROM teaql_blob_catalog WHERE key = ?", key: reference.key)
      XCTAssertEqual(catalogContentType, contentType)
      try await context.executeGraphSave(comment: "bind S3 Blob in business graph") { actor, session in
        _ = try await actor.execute(Mutation(kind: .create, entity: asset,
          values: ["id": .int(1), "name": .string("document")],
          auditReason: session.intent.comment))
        let bound = try await catalog.bind(actor, session: session,
          change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "1",
            field: "file"), next: reference, expectedVersion: 0, nextVersion: 1,
            action: "Create"), authorization: S3BindingPermission())
        XCTAssertEqual(bound, 1)
      }
      let businessName = try await s3UploadCatalogValue(context,
        sql: "SELECT name FROM asset WHERE CAST(id AS TEXT) = ?", key: "1")
      let boundStatus = try await s3UploadCatalogValue(context,
        sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key)
      XCTAssertEqual(businessName, "document")
      XCTAssertEqual(boundStatus, "available")

      let permitted = context.withResponseGraphAuthorizer(
        S3ViewAuthorizer(reference: reference, version: 1))
        .withBlobResponseContributor(try SQLiteBlobResponseContributor(catalog: catalog,
          authorization: S3ReadPermission(allowed: true), maximumURLSeconds: 3))
      let options = ViewOptions(mode: .ordinary, businessOutcome: .readOnly,
        expiresAt: Date().addingTimeInterval(60))
      let prepared = try await ViewPreparationService().prepare(context: permitted,
        result: "unused", options: options)
      guard case let .object(fields) = prepared.presentation,
        let document = fields["document"], case let .string(urlText) = document,
        let url = URL(string: urlText) else {
        throw TeaQLError.execution("S3 Blob signed view missing")
      }
      XCTAssertEqual(prepared.cacheControl, "private, no-store")
      var request = URLRequest(url: url)
      request.setValue("bytes=0-7", forHTTPHeaderField: "Range")
      let (partial, response) = try await URLSession.shared.data(for: request)
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
      XCTAssertEqual(partial, data.prefix(8))
      XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
        contentType)
      XCTAssertTrue((response as? HTTPURLResponse)?
        .value(forHTTPHeaderField: "Content-Disposition")?.contains(filename) == true)
      let revokedRead = permitted.withBlobResponseContributor(
        try SQLiteBlobResponseContributor(catalog: catalog,
          authorization: S3ReadPermission(allowed: false), maximumURLSeconds: 3))
      do {
        _ = try await ViewPreparationService().prepare(context: revokedRead,
          result: "unused", options: options)
        XCTFail("revoked S3 Blob view signed")
      } catch let error as ViewPreparationError { XCTAssertEqual(error.code, "BLOB_READ_DENIED") }
      let staleRead = permitted.withResponseGraphAuthorizer(
        S3ViewAuthorizer(reference: reference, version: 0))
      do {
        _ = try await ViewPreparationService().prepare(context: staleRead,
          result: "unused", options: ViewOptions(mode: .ordinary,
            businessOutcome: .committed, expiresAt: Date().addingTimeInterval(60)))
        XCTFail("stale S3 Blob binding signed")
      } catch let error as ViewPreparationError {
        XCTAssertEqual(error.code, "BLOB_READ_DENIED")
        XCTAssertEqual(error.businessState, "committed")
      }
    } catch {
      if let objectKey { try? await storage.delete(objectKey) }
      try? await client.shutdown()
      throw error
    }
    if let objectKey { try await storage.delete(objectKey) }
    try await client.shutdown()
  }
}
