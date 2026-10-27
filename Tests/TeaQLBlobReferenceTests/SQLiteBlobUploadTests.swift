import Crypto
import Foundation
import TeaQLBlobReference
import TeaQLCore
import TeaQLSQLite
import Testing

private struct UploadPermission: BlobUploadAuthorization {
  let tenant: String
  let allowed: Bool
  func scope(for actor: UserContext) throws -> String { tenant }
  func field(for actor: UserContext, target: BlobUploadTarget) throws -> BlobFieldSpec {
    try BlobFieldSpec(entity: "Asset", field: "file", extensions: ["pdf"],
      nullable: true, policyProfile: "default")
  }
  func authorize(actor: UserContext, target: BlobUploadTarget, action: String,
                 input: BlobUploadInput) async throws -> Bool {
    allowed && target.entity == "Asset" && target.field == "file"
      && ["Begin", "Write", "Confirm"].contains(action)
  }
}

private struct UploadBindingPermission: BlobBindingAuthorization {
  func scope(for actor: UserContext) throws -> String { "tenant-a" }
  func authorize(actor: UserContext, target: BlobBindingTarget, previous: BlobRef?,
                 next: BlobRef?, action: String) async throws -> Bool {
    target.entity == "Asset" && target.field == "file" && action == "Create"
  }
}

// The test verifier only checks a fixture PDF; it is not production format parsing.
private struct FixturePDFVerifier: BlobContentVerifier {
  let early: Bool
  init(early: Bool = false) { self.early = early }
  func verify(reader: any ObjectByteReader, extension ext: String,
              maximumBytes: Int64) async throws -> BlobVerifiedContent {
    if early { return BlobVerifiedContent(sizeBytes: 1, sha256: String(repeating: "0", count: 64),
      contentType: "application/pdf") }
    var data = Data()
    while true {
      let bytes = try await reader.read(upToCount: 4096)
      if bytes.isEmpty { break }
      data.append(bytes)
      guard Int64(data.count) <= maximumBytes else { throw TeaQLError.execution("invalid fixture") }
    }
    guard ext == "pdf", data.starts(with: Data("%PDF-".utf8)),
      String(data: data, encoding: .utf8)?.contains("%%EOF") == true else {
      throw TeaQLError.execution("invalid fixture")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return BlobVerifiedContent(sizeBytes: Int64(data.count), sha256: digest,
      contentType: "application/pdf")
  }
}

private func uploadCatalogValue(_ context: UserContext, sql: String,
                                key: String) async throws -> String? {
  try await context.executeGraphSave(comment: "inspect Blob upload") { graph, session in
    try await graph.withPhysicalSQL(session) { lease in
      let rows = try await lease.query(sql, parameters: [.string(key)])
      return rows.first?.values.first?.stringValue
    }
  }
}

@Test
func swiftSQLiteFileUploadNeedsFullVerificationBeforeNativeBind() async throws {
  let parent = FileManager.default.temporaryDirectory
    .appendingPathComponent("teaql-swift-upload-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: parent) }
  let store = try FileObjectStorage(root: parent.appendingPathComponent("private").path,
    signingKey: Data(repeating: 0x42, count: 32))
  defer { try? store.close() }
  let asset = EntityDescriptor(name: "Asset", table: "upload_asset", properties: [
    PropertyDescriptor(name: "id", type: .int, isID: true),
    PropertyDescriptor(name: "version", type: .int, isVersion: true),
    PropertyDescriptor(name: "name", type: .string),
  ])
  let database = try SQLiteDataService(path: ":memory:")
  let context = UserContext(queryExecutor: database, mutationExecutor: database,
    requestPolicy: RequestPolicy { $0 }).withObjectStorage(store)
    .withObjectStorageObserver { _ in }
  try await context.ensureSchema(RuntimeModule(name: "upload-test", entities: [asset]))
  let catalog = SQLiteBlobCatalog()
  try await context.executeGraphSave(comment: "install Blob upload schema") { graph, session in
    try await catalog.installSchema(graph, session: session)
    try await catalog.validateSchema(graph, session: session)
  }
  let service = try SQLiteBlobUploadService(authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  let target = BlobUploadTarget(entity: "Asset", entityID: "1", field: "file")
  let data = Data("%PDF-1.7\nreal file bytes\n%%EOF".utf8)
  let input = BlobUploadInput(fileName: "path/report.pdf", declaredSize: Int64(data.count),
    declaredContentType: "application/pdf")
  let session = try await service.begin(context, target: target, input: input, replayKey: "request-1")
  let replay = try await service.begin(context, target: target, input: input, replayKey: "request-1")
  #expect(replay.uploadID == session.uploadID)
  do {
    _ = try await service.begin(context, target: target,
      input: BlobUploadInput(fileName: "other.pdf", declaredSize: Int64(data.count)),
      replayKey: "request-1")
    Issue.record("changed replay accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_IDEMPOTENCY_CONFLICT")) }
  do { _ = try await service.complete(context, uploadID: session.uploadID); Issue.record("empty upload completed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }
  let wrongScope = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-b", allowed: true),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  do {
    _ = try await wrongScope.write(context, uploadID: session.uploadID, source: ObjectDataReader(data))
    Issue.record("foreign scope wrote upload")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  #expect(try await service.write(context, uploadID: session.uploadID,
    source: ObjectDataReader(data)) == Int64(data.count))
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: session.reference.key) == "initiated")
  let revoked = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: false),
    verifier: FixturePDFVerifier(), maximumBytes: 10_000)
  do { _ = try await revoked.complete(context, uploadID: session.uploadID); Issue.record("revoked confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_DENIED")) }
  let reference = try await service.complete(context, uploadID: session.uploadID)
  #expect(reference == session.reference)
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key) == "uploaded_unbound")
  try await context.executeGraphSave(comment: "bind verified upload") { actor, session in
    _ = try await actor.execute(Mutation(kind: .create, entity: asset,
      values: ["id": .int(1), "name": .string("document")], auditReason: session.intent.comment))
    _ = try await catalog.bind(actor, session: session,
      change: BlobBindingChange(target: BlobBindingTarget(entity: "Asset", entityID: "1", field: "file"),
        next: reference, expectedVersion: 0, nextVersion: 1, action: "Create"),
      authorization: UploadBindingPermission())
  }
  #expect(try await uploadCatalogValue(context,
    sql: "SELECT status FROM teaql_blob_catalog WHERE key = ?", key: reference.key) == "available")

  let second = try await service.begin(context, target: target, input: input, replayKey: "request-2")
  _ = try await service.write(context, uploadID: second.uploadID, source: ObjectDataReader(data))
  let raw = try #require(await uploadCatalogValue(context,
    sql: "SELECT object_key FROM teaql_blob_catalog WHERE key = ?", key: second.reference.key))
  _ = try await context.objectStorage("replace same bytes").putBytes(try ObjectKey(raw), data: data,
    options: ObjectPutOptions(size: Int64(data.count), mode: .replace, contentType: "application/pdf"))
  do { _ = try await service.complete(context, uploadID: second.uploadID); Issue.record("replacement confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }

  let third = try await service.begin(context, target: target, input: input, replayKey: "request-3")
  _ = try await service.write(context, uploadID: third.uploadID, source: ObjectDataReader(data))
  let early = try SQLiteBlobUploadService(
    authorization: UploadPermission(tenant: "tenant-a", allowed: true),
    verifier: FixturePDFVerifier(early: true), maximumBytes: 10_000)
  do { _ = try await early.complete(context, uploadID: third.uploadID); Issue.record("early verifier confirmed") }
  catch { #expect(error as? TeaQLError == .execution("BLOB_UPLOAD_INCOMPLETE")) }

  let fourth = try await service.begin(context, target: target, input: input, replayKey: "request-4")
  do {
    _ = try await service.write(context, uploadID: fourth.uploadID,
      source: ObjectDataReader(data + Data("x".utf8)))
    Issue.record("oversized upload accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }
  let fifth = try await service.begin(context, target: target, input: input, replayKey: "request-5")
  do {
    _ = try await service.write(context, uploadID: fifth.uploadID,
      source: ObjectDataReader(Data(data.dropLast())))
    Issue.record("short upload accepted")
  } catch { #expect(error as? TeaQLError == .execution("BLOB_STORE_FAILED")) }
}
